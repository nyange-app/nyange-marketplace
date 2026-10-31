-- Nyange marketplace schema (PostgreSQL 14+ with PostGIS).
-- Stack-agnostic: any backend can sit on top. Money is integer UGX (no decimals).
-- Conventions: ids are uuid; all geo columns are geography(Point,4326), so
-- ST_DWithin distances are in metres; "version" columns support optimistic locking.

create extension if not exists postgis;
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
create type user_role         as enum ('buyer', 'seller', 'agent', 'admin');
create type catalog_kind      as enum ('goods', 'service');
create type fulfilment_mode   as enum ('delivery', 'on_site', 'ride', 'print_job');
create type payment_method    as enum ('cod', 'mobile_money', 'wallet');
create type order_status      as enum ('placed', 'in_progress', 'completed', 'cancelled');
create type line_status       as enum ('open', 'claimed', 'confirmed', 'ready', 'in_delivery',
                                       'delivered', 'completed', 'cancelled', 'expired', 'disputed');
create type shipment_status   as enum ('pending', 'ready', 'in_delivery', 'delivered', 'failed');
create type task_status       as enum ('open', 'claimed', 'in_progress', 'completed', 'cancelled', 'expired');
create type task_type         as enum ('delivery', 'price_capture', 'cash_deposit', 'cash_withdrawal',
                                       'payment_collection');  -- extensible: add values as functions are scoped
create type stop_kind         as enum ('pickup', 'dropoff', 'visit');
create type account_kind      as enum ('buyer_wallet', 'seller_wallet', 'agent_wallet', 'agent_cash_in_hand',
                                       'escrow', 'platform_revenue', 'provider_clearing');
create type config_scope      as enum ('global', 'area', 'agent', 'seller');

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------
create table users (
    id          uuid primary key default gen_random_uuid(),
    phone       text not null unique,                 -- E.164, OTP login
    full_name   text,
    status      text not null default 'active' check (status in ('active', 'suspended')),
    created_at  timestamptz not null default now()
);

create table user_roles (
    user_id  uuid not null references users(id),
    role     user_role not null,
    primary key (user_id, role)
);

create table addresses (
    id        uuid primary key default gen_random_uuid(),
    user_id   uuid not null references users(id),
    label     text,
    geom      geography(Point, 4326) not null,        -- map pin; formal addresses are unreliable
    landmark  text,
    notes     text
);

-- Coverage areas: activated when enough supply exists (see config coverage.*).
create table areas (
    id      uuid primary key default gen_random_uuid(),
    name    text not null,
    geom    geography(MultiPolygon, 4326) not null,
    active  boolean not null default false
);
create index areas_geom_idx on areas using gist (geom);

-- ---------------------------------------------------------------------------
-- Configuration levers. Every operational rule lives here so it can be tuned
-- per scope or waived. precedence: agent/seller > area > global.
-- A JSON null value means "waived" (rule disabled); a missing row falls through.
-- ---------------------------------------------------------------------------
create table config (
    key         text not null,
    scope       config_scope not null default 'global',
    scope_id    uuid,                                  -- null iff scope = 'global'
    value       jsonb not null,                        -- 'null'::jsonb = waived
    updated_at  timestamptz not null default now(),
    check ((scope = 'global') = (scope_id is null))
);
create unique index config_uq on config (key, scope, coalesce(scope_id, '00000000-0000-0000-0000-000000000000'));

-- Returns the effective value; SQL NULL means the key is unset OR waived.
create function config_get(p_key text, p_area uuid default null, p_agent uuid default null,
                           p_seller uuid default null)
returns jsonb language sql stable as $$
    select case when c.value = 'null'::jsonb then null else c.value end
    from config c
    where c.key = p_key
      and (   c.scope = 'global'
           or (c.scope = 'area'   and c.scope_id = p_area)
           or (c.scope = 'agent'  and c.scope_id = p_agent)
           or (c.scope = 'seller' and c.scope_id = p_seller))
    order by case c.scope when 'agent' then 1 when 'seller' then 1 when 'area' then 2 else 3 end
    limit 1
$$;

-- ---------------------------------------------------------------------------
-- Catalog (owned by Nyange)
-- ---------------------------------------------------------------------------
create table categories (
    id         uuid primary key default gen_random_uuid(),
    parent_id  uuid references categories(id),
    name       text not null,
    slug       text not null unique
);

create table catalog_items (
    id               uuid primary key default gen_random_uuid(),
    category_id      uuid not null references categories(id),
    kind             catalog_kind not null,
    name             text not null,
    slug             text not null unique,
    fulfilment       fulfilment_mode not null default 'delivery',
    active           boolean not null default true
);

create table variants (
    id        uuid primary key default gen_random_uuid(),
    item_id   uuid not null references catalog_items(id),
    name      text not null,                          -- e.g. '12kg', '20L Jibu', '50kg bag'
    unit      text not null,
    active    boolean not null default true,
    unique (item_id, name)
);

-- ---------------------------------------------------------------------------
-- Sellers and standing offers (sellers own price, never the catalog)
-- ---------------------------------------------------------------------------
create table sellers (
    id             uuid primary key default gen_random_uuid(),
    user_id        uuid not null unique references users(id),
    business_name  text not null,
    status         text not null default 'pending' check (status in ('pending', 'active', 'suspended')),
    verified_at    timestamptz
);

create table seller_locations (
    id              uuid primary key default gen_random_uuid(),
    seller_id       uuid not null references sellers(id),
    name            text not null,
    geom            geography(Point, 4326) not null,
    max_radius_m    integer not null check (max_radius_m > 0),
    -- seller-set delivery fee: base + per-km. Market forces apply: agents decide whether to claim.
    delivery_base_fee_ugx  bigint not null default 0 check (delivery_base_fee_ugx >= 0),
    delivery_per_km_ugx    bigint not null default 0 check (delivery_per_km_ugx >= 0)
);
create index seller_locations_geom_idx on seller_locations using gist (geom);

create table offers (
    id           uuid primary key default gen_random_uuid(),
    seller_id    uuid not null references sellers(id),
    location_id  uuid not null references seller_locations(id),
    variant_id   uuid not null references variants(id),
    price_ugx    bigint not null check (price_ugx > 0),
    in_stock     boolean not null default true,
    active       boolean not null default true,
    updated_at   timestamptz not null default now(),
    unique (location_id, variant_id)
);
create index offers_variant_idx on offers (variant_id) where active and in_stock;

-- ---------------------------------------------------------------------------
-- Agents
-- ---------------------------------------------------------------------------
create table agents (
    id            uuid primary key default gen_random_uuid(),
    user_id       uuid not null unique references users(id),
    status        text not null default 'pending' check (status in ('pending', 'active', 'suspended')),
    verified_at   timestamptz,
    home_geom     geography(Point, 4326),
    last_geom     geography(Point, 4326),
    last_seen_at  timestamptz
);
create index agents_last_geom_idx on agents using gist (last_geom);

create table agent_capabilities (
    agent_id    uuid not null references agents(id),
    capability  task_type not null,
    primary key (agent_id, capability)
);

-- ---------------------------------------------------------------------------
-- Orders: the claimable unit is the line (order pool)
-- ---------------------------------------------------------------------------
create table orders (
    id                uuid primary key default gen_random_uuid(),
    buyer_id          uuid not null references users(id),
    drop_geom         geography(Point, 4326) not null,
    drop_landmark     text,
    payment_method    payment_method not null,
    status            order_status not null default 'placed',
    created_at        timestamptz not null default now()
);

create table order_lines (
    id                  uuid primary key default gen_random_uuid(),
    order_id            uuid not null references orders(id),
    variant_id          uuid not null references variants(id),
    qty                 integer not null check (qty > 0),
    -- buyer's pre-approved ceiling, taken from the max of eligible standing offers at checkout
    max_unit_price_ugx  bigint not null check (max_unit_price_ugx > 0),
    status              line_status not null default 'open',
    -- pool geometry: eligibility = within least(seller max radius, pool_radius_m) of the drop point
    pool_radius_m       integer not null,
    -- seller affinity: a seller who claimed a sibling line gets first refusal for a short window
    exclusive_seller_id uuid references sellers(id),
    exclusive_until     timestamptz,
    -- claim result (price locked at claim time)
    seller_id           uuid references sellers(id),
    offer_id            uuid references offers(id),
    unit_price_ugx      bigint,
    claimed_at          timestamptz,
    claim_expires_at    timestamptz,                    -- lease: seller must confirm before this
    shipment_id         uuid,
    version             integer not null default 0
);
create index order_lines_open_idx on order_lines (variant_id) where status = 'open';
create index order_lines_order_idx on order_lines (order_id);

create table shipments (
    id              uuid primary key default gen_random_uuid(),
    order_id        uuid not null references orders(id),
    seller_id       uuid not null references sellers(id),
    location_id     uuid not null references seller_locations(id),
    status          shipment_status not null default 'pending',
    delivery_fee_ugx bigint not null check (delivery_fee_ugx >= 0)
);
alter table order_lines
    add constraint order_lines_shipment_fk foreign key (shipment_id) references shipments(id);

-- ---------------------------------------------------------------------------
-- Tasks: the field-agent pool. Types are data, not code.
-- ---------------------------------------------------------------------------
create table tasks (
    id                  uuid primary key default gen_random_uuid(),
    type                task_type not null,
    status              task_status not null default 'open',
    anchor_geom         geography(Point, 4326) not null,   -- pool centre (first pickup, market, etc.)
    pool_radius_m       integer not null,
    reward_ugx          bigint not null check (reward_ugx >= 0),  -- what the agent is paid; seller may raise it
    cash_exposure_ugx   bigint not null default 0 check (cash_exposure_ugx >= 0),
    payload             jsonb not null default '{}'::jsonb,
    -- affinity: prefer the agent already handling a sibling shipment of the same order
    preferred_agent_id  uuid references agents(id),
    preferred_until     timestamptz,
    agent_id            uuid references agents(id),
    claimed_at          timestamptz,
    claim_expires_at    timestamptz,
    created_at          timestamptz not null default now(),
    version             integer not null default 0
);
create index tasks_open_geom_idx on tasks using gist (anchor_geom) where status = 'open';

create table task_stops (
    id            uuid primary key default gen_random_uuid(),
    task_id       uuid not null references tasks(id),
    seq           integer not null,
    kind          stop_kind not null,
    geom          geography(Point, 4326) not null,
    shipment_id   uuid references shipments(id),
    completed_at  timestamptz,
    unique (task_id, seq)
);

-- Field-captured market prices: sanity check for offers and a data asset on its own.
create table price_observations (
    id           uuid primary key default gen_random_uuid(),
    variant_id   uuid not null references variants(id),
    agent_id     uuid not null references agents(id),
    task_id      uuid references tasks(id),
    market_name  text,
    geom         geography(Point, 4326) not null,
    price_ugx    bigint not null check (price_ugx > 0),
    photo_url    text,
    observed_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Ledger: double-entry, append-only. Sign convention: +amount = debit, -amount = credit.
-- Every journal sums to zero. Wallet balances are derived, never stored or edited.
-- Credit-normal accounts (wallets, escrow, revenue) therefore show negative balances.
-- ---------------------------------------------------------------------------
create table ledger_accounts (
    id          uuid primary key default gen_random_uuid(),
    kind        account_kind not null,
    -- owner by kind: buyer_wallet -> users.id; seller_wallet -> sellers.id;
    -- agent_wallet / agent_cash_in_hand -> agents.id; system accounts -> null
    owner_id    uuid,
    currency    char(3) not null default 'UGX',
    created_at  timestamptz not null default now(),
    unique (kind, owner_id)
);

create table journals (
    id               uuid primary key default gen_random_uuid(),
    kind             text not null,                    -- e.g. 'payment_in', 'cod_collect', 'line_release', 'withdrawal'
    ref_type         text,
    ref_id           uuid,
    idempotency_key  text not null unique,             -- every payment call and webhook carries one
    created_at       timestamptz not null default now()
);

create table ledger_entries (
    id          bigserial primary key,
    journal_id  uuid not null references journals(id),
    account_id  uuid not null references ledger_accounts(id),
    amount      bigint not null check (amount <> 0)
);
create index ledger_entries_account_idx on ledger_entries (account_id);

create function ledger_check_balanced() returns trigger language plpgsql as $$
begin
    if (select coalesce(sum(amount), 0) from ledger_entries where journal_id = new.journal_id) <> 0 then
        raise exception 'journal % is not balanced', new.journal_id;
    end if;
    return null;
end $$;
create constraint trigger ledger_entries_balanced
    after insert on ledger_entries
    deferrable initially deferred
    for each row execute function ledger_check_balanced();

create function ledger_immutable() returns trigger language plpgsql as $$
begin
    raise exception 'ledger rows are append-only';
end $$;
create trigger ledger_entries_no_change before update or delete on ledger_entries
    for each row execute function ledger_immutable();
create trigger journals_no_change before update or delete on journals
    for each row execute function ledger_immutable();

create view account_balances as
    select a.id as account_id, a.kind, a.owner_id, coalesce(sum(e.amount), 0) as balance
    from ledger_accounts a left join ledger_entries e on e.account_id = a.id
    group by a.id;

create table payments (
    id               uuid primary key default gen_random_uuid(),
    order_id         uuid not null references orders(id),
    method           payment_method not null,
    provider         text,
    provider_ref     text,
    amount_ugx       bigint not null check (amount_ugx > 0),
    status           text not null default 'pending' check (status in ('pending', 'succeeded', 'failed', 'refunded')),
    idempotency_key  text not null unique,
    created_at       timestamptz not null default now(),
    unique (provider, provider_ref)
);

create table audit_log (
    id           bigserial primary key,
    actor_id     uuid,
    entity       text not null,
    entity_id    uuid,
    action       text not null,
    data         jsonb,
    at           timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Claim engine. A claim is one atomic conditional UPDATE; losers get false.
-- ---------------------------------------------------------------------------

-- Seller claims an order line at their standing offer's price.
create function claim_order_line(p_line uuid, p_seller uuid, p_offer uuid)
returns boolean language plpgsql as $$
declare
    v_lease integer := coalesce((config_get('claim.order_line.lease_s'))::integer, 600);
    v_rows  integer;
begin
    with eligible as (
        select ol.id, o.id as offer_id, o.price_ugx
        from order_lines ol
        join orders od          on od.id = ol.order_id
        join offers o           on o.id = p_offer and o.seller_id = p_seller
                               and o.variant_id = ol.variant_id and o.active and o.in_stock
        join seller_locations sl on sl.id = o.location_id
        join sellers s          on s.id = o.seller_id and s.status = 'active'
        where ol.id = p_line
          and ol.status = 'open'
          and o.price_ugx <= ol.max_unit_price_ugx
          and (ol.exclusive_seller_id is null
               or ol.exclusive_until <= now()
               or ol.exclusive_seller_id = p_seller)
          and st_dwithin(sl.geom, od.drop_geom, least(sl.max_radius_m, ol.pool_radius_m))
        for update of ol skip locked
    )
    update order_lines ol
       set status = 'claimed', seller_id = p_seller, offer_id = e.offer_id,
           unit_price_ugx = e.price_ugx, claimed_at = now(),
           claim_expires_at = now() + make_interval(secs => v_lease),
           version = ol.version + 1
      from eligible e
     where ol.id = e.id;
    get diagnostics v_rows = row_count;

    if v_rows = 1 then
        -- seller affinity: first refusal on sibling lines for the exclusive window
        update order_lines sib
           set exclusive_seller_id = p_seller,
               exclusive_until = now() + make_interval(
                   secs => coalesce((config_get('claim.affinity.exclusive_window_s'))::integer, 90))
         where sib.order_id = (select order_id from order_lines where id = p_line)
           and sib.status = 'open' and sib.id <> p_line;
    end if;
    return v_rows = 1;
end $$;

-- Agent claims a task. Eligibility: active, capable, within radius of the pool
-- centre, respects preferred-agent window, and (if configured) the cash float limit.
create function claim_task(p_task uuid, p_agent uuid)
returns boolean language plpgsql as $$
declare
    v_lease  integer := coalesce((config_get('claim.task.lease_s'))::integer, 600);
    v_float  bigint  := (config_get('cod.agent.float_limit_ugx', null, p_agent))::bigint;  -- null = waived
    v_verify boolean := coalesce((config_get('cod.agent.verification_required', null, p_agent))::boolean, false);
    v_held   bigint;
    v_rows   integer;
begin
    select coalesce(b.balance, 0) into v_held
    from account_balances b where b.kind = 'agent_cash_in_hand' and b.owner_id = p_agent;
    v_held := coalesce(v_held, 0);

    with eligible as (
        select t.id
        from tasks t
        join agents a on a.id = p_agent and a.status = 'active'
        join agent_capabilities c on c.agent_id = a.id and c.capability = t.type
        where t.id = p_task
          and t.status = 'open'
          and a.last_geom is not null
          and st_dwithin(a.last_geom, t.anchor_geom, t.pool_radius_m)
          and (t.preferred_agent_id is null or t.preferred_until <= now() or t.preferred_agent_id = p_agent)
          and (t.cash_exposure_ugx = 0
               or ((v_float is null or v_held + t.cash_exposure_ugx <= v_float)
                   and (not v_verify or a.verified_at is not null)))
        for update of t skip locked
    )
    update tasks t
       set status = 'claimed', agent_id = p_agent, claimed_at = now(),
           claim_expires_at = now() + make_interval(secs => v_lease), version = t.version + 1
      from eligible e
     where t.id = e.id;
    get diagnostics v_rows = row_count;
    return v_rows = 1;
end $$;

-- Scheduler hooks (run every ~30s by any job runner).

-- Unconfirmed leases go back to the pool.
create function release_expired_claims() returns void language sql as $$
    update order_lines
       set status = 'open', seller_id = null, offer_id = null, unit_price_ugx = null,
           claimed_at = null, claim_expires_at = null, version = version + 1
     where status = 'claimed' and claim_expires_at < now();
    update tasks
       set status = 'open', agent_id = null, claimed_at = null, claim_expires_at = null, version = version + 1
     where status = 'claimed' and claim_expires_at < now();
$$;

-- Unclaimed pool items widen their radius to the largest step whose delay has elapsed,
-- e.g. config pool.order_line.radius_steps = [{"after_s":120,"radius_m":7000},{"after_s":300,"radius_m":15000}].
-- Age is measured from order creation (lines) or task creation (tasks). A waived (null) key never widens.
create function expand_pool_radius(p_steps_key text, p_table text) returns void language plpgsql as $$
declare
    v_steps jsonb := config_get(p_steps_key);
begin
    if v_steps is null then return; end if;
    if p_table = 'order_lines' then
        update order_lines ol set pool_radius_m = x.target
        from (select l.id,
                     (select max((e->>'radius_m')::int) from jsonb_array_elements(v_steps) e
                      where (e->>'after_s')::int <= extract(epoch from now() - o.created_at)) as target
              from order_lines l join orders o on o.id = l.order_id
              where l.status = 'open') x
        where ol.id = x.id and x.target > ol.pool_radius_m;
    elsif p_table = 'tasks' then
        update tasks t set pool_radius_m = x.target
        from (select t2.id,
                     (select max((e->>'radius_m')::int) from jsonb_array_elements(v_steps) e
                      where (e->>'after_s')::int <= extract(epoch from now() - t2.created_at)) as target
              from tasks t2 where t2.status = 'open') x
        where t.id = x.id and x.target > t.pool_radius_m;
    else
        raise exception 'unknown pool table %', p_table;
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- Default configuration. Agent gates start waived (null) to ease onboarding.
-- ---------------------------------------------------------------------------
insert into config (key, value) values
    ('pool.order_line.initial_radius_m',      '3000'),
    ('pool.order_line.radius_steps',          '[{"after_s":120,"radius_m":7000},{"after_s":300,"radius_m":15000}]'),
    ('pool.task.initial_radius_m',            '3000'),
    ('pool.task.radius_steps',                '[{"after_s":120,"radius_m":7000},{"after_s":300,"radius_m":15000}]'),
    ('claim.order_line.lease_s',              '600'),
    ('claim.task.lease_s',                    '600'),
    ('claim.affinity.exclusive_window_s',     '90'),
    ('delivery.fee.floor_ugx',                'null'),   -- waived: market decides
    ('delivery.fee.cap_ugx',                  'null'),   -- waived: market decides
    ('delivery.fee.bump_allowed',             'true'),   -- seller may raise an unclaimed task's reward
    ('platform.commission.goods_bps',         '0'),
    ('platform.commission.delivery_bps',      '0'),
    ('cod.enabled',                           'true'),
    ('cod.agent.float_limit_ugx',             'null'),   -- waived
    ('cod.agent.settlement_deadline_h',       'null'),   -- waived
    ('cod.agent.deposit_required_ugx',        'null'),   -- waived
    ('cod.agent.verification_required',       'false'),
    ('coverage.require_supply',               'false'),
    ('coverage.min_sellers',                  '1'),
    ('coverage.min_agents',                   '1');
