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
    unique (id, seller_id)                              -- target for composite FKs: a location belongs to one seller
);
create index seller_locations_geom_idx on seller_locations using gist (geom);

create table offers (
    id           uuid primary key default gen_random_uuid(),
    seller_id    uuid not null references sellers(id),
    location_id  uuid not null,
    variant_id   uuid not null references variants(id),
    price_ugx    bigint not null check (price_ugx > 0),
    in_stock     boolean not null default true,
    active       boolean not null default true,
    updated_at   timestamptz not null default now(),
    unique (location_id, variant_id),
    foreign key (location_id, seller_id) references seller_locations (id, seller_id)
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
    area_id           uuid references areas(id),        -- set from drop_geom on insert; scopes area config
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
    location_id     uuid not null,
    status          shipment_status not null default 'pending',
    delivery_fee_ugx bigint not null check (delivery_fee_ugx >= 0),
    foreign key (location_id, seller_id) references seller_locations (id, seller_id)
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
    reward_ugx          bigint not null check (reward_ugx >= 0),  -- what the agent is paid (for deliveries, the computed fee)
    area_id             uuid references areas(id),                -- set from anchor_geom on insert; scopes area config
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

-- Area resolution: the smallest area covering a point. Triggers fill orders.area_id / tasks.area_id
-- so claims and pool widening honour area-scoped configuration.
create function area_for(p_geom geography) returns uuid language sql stable as $$
    select id from areas where st_covers(geom, p_geom) order by st_area(geom) limit 1
$$;
create function orders_set_area() returns trigger language plpgsql as $$
begin
    if new.area_id is null then new.area_id := area_for(new.drop_geom); end if;
    return new;
end $$;
create trigger orders_set_area before insert on orders
    for each row execute function orders_set_area();
create function tasks_set_area() returns trigger language plpgsql as $$
begin
    if new.area_id is null then new.area_id := area_for(new.anchor_geom); end if;
    return new;
end $$;
create trigger tasks_set_area before insert on tasks
    for each row execute function tasks_set_area();

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

-- Delivery pricing audit trail. One route quote per delivery task: the optimised route
-- (from the routing provider) plus the per-shipment factors and fees derived from it.
create table route_quotes (
    id               uuid primary key default gen_random_uuid(),
    task_id          uuid references tasks(id),         -- null for checkout estimates
    is_estimate      boolean not null default false,    -- straight-line x circuity, no provider call
    provider         text not null,                     -- e.g. 'google', 'estimate'
    travel_mode      text,
    stop_order       jsonb not null,                    -- ordered stops as returned by the optimiser
    distance_m       integer not null check (distance_m >= 0),
    duration_s       integer not null check (duration_s >= 0),
    rate_per_km_ugx  bigint not null,                   -- rates in force when quoted
    rate_per_min_ugx bigint not null,
    factor_mode      text not null,
    route_cost_ugx   bigint not null,
    created_at       timestamptz not null default now()
);

create table route_quote_shipments (
    route_quote_id        uuid not null references route_quotes(id),
    shipment_id           uuid not null references shipments(id),
    standalone_distance_m integer not null,
    standalone_duration_s integer not null,
    factor                numeric(10,9) not null check (factor between 0 and 1),
    standalone_fee_ugx    bigint not null,
    fee_ugx               bigint not null,
    capped                boolean not null,
    primary key (route_quote_id, shipment_id)
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
-- TRUNCATE bypasses row triggers, so it needs its own statement-level guard. Application roles
-- should also never own these tables or hold TRUNCATE / trigger-management privileges.
create trigger ledger_entries_no_truncate before truncate on ledger_entries
    for each statement execute function ledger_immutable();
create trigger journals_no_truncate before truncate on journals
    for each statement execute function ledger_immutable();

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
-- The parent order row is locked first (order, then lines, always in that sequence), so two sellers
-- claiming sibling lines of one order are serialised instead of deadlocking on each other's affinity
-- update. Order cancellation must lock the order row the same way, so a cancel and a claim cannot interleave.
create function claim_order_line(p_line uuid, p_seller uuid, p_offer uuid)
returns boolean language plpgsql as $$
declare
    v_order  uuid;
    v_area   uuid;
    v_lease  integer;
    v_window integer;
    v_rows   integer;
begin
    select ol.order_id into v_order from order_lines ol where ol.id = p_line;
    if v_order is null then return false; end if;
    select o.area_id into v_area from orders o where o.id = v_order for update;

    v_lease  := coalesce((config_get('claim.order_line.lease_s', v_area))::integer, 600);
    v_window := coalesce((config_get('claim.affinity.exclusive_window_s', v_area))::integer, 90);

    with eligible as (
        select ol.id, o.id as offer_id, o.price_ugx
        from order_lines ol
        join orders od          on od.id = ol.order_id and od.status in ('placed', 'in_progress')
        join offers o           on o.id = p_offer and o.seller_id = p_seller
                               and o.variant_id = ol.variant_id and o.active and o.in_stock
        join seller_locations sl on sl.id = o.location_id and sl.seller_id = p_seller
        join sellers s          on s.id = o.seller_id and s.status = 'active'
        join users us           on us.id = s.user_id and us.status = 'active'
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
               exclusive_until = now() + make_interval(secs => v_window)
         where sib.order_id = v_order
           and sib.status = 'open' and sib.id <> p_line;
    end if;
    return v_rows = 1;
end $$;

-- Agent claims a task. Eligibility: active agent and user, capable, within radius of the pool
-- centre, respects the preferred-agent window, and (if configured) the cash float limit.
-- Float check: cash already held (ledger) + cash exposure of tasks this agent has claimed but not yet
-- completed + this task's exposure must stay within the limit. The agent row is locked so concurrent
-- claims by one agent cannot both pass the check. When a CoD task completes, the application must post
-- the cash-collection journal in the same transaction, so the cash moves from "reserved" to "held".
create function claim_task(p_task uuid, p_agent uuid)
returns boolean language plpgsql as $$
declare
    v_area     uuid;
    v_lease    integer;
    v_float    bigint;
    v_verify   boolean;
    v_held     bigint;
    v_reserved bigint;
    v_rows     integer;
begin
    select t.area_id into v_area from tasks t where t.id = p_task;
    perform 1 from agents a where a.id = p_agent for update;

    v_lease  := coalesce((config_get('claim.task.lease_s', v_area))::integer, 600);
    v_float  := (config_get('cod.agent.float_limit_ugx', v_area, p_agent))::bigint;          -- null = waived
    v_verify := coalesce((config_get('cod.agent.verification_required', v_area, p_agent))::boolean, false);

    select coalesce(sum(b.balance), 0) into v_held
    from account_balances b where b.kind = 'agent_cash_in_hand' and b.owner_id = p_agent;
    select coalesce(sum(t.cash_exposure_ugx), 0) into v_reserved
    from tasks t where t.agent_id = p_agent and t.status in ('claimed', 'in_progress');

    with eligible as (
        select t.id
        from tasks t
        join agents a on a.id = p_agent and a.status = 'active'
        join users u on u.id = a.user_id and u.status = 'active'
        join agent_capabilities c on c.agent_id = a.id and c.capability = t.type
        where t.id = p_task
          and t.status = 'open'
          and a.last_geom is not null
          and st_dwithin(a.last_geom, t.anchor_geom, t.pool_radius_m)
          and (t.preferred_agent_id is null or t.preferred_until <= now() or t.preferred_agent_id = p_agent)
          and (t.cash_exposure_ugx = 0
               or ((v_float is null or v_held + v_reserved + t.cash_exposure_ugx <= v_float)
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
-- Steps are looked up per row, so an area-scoped schedule applies to items in that area. Age is measured
-- from order creation (lines) or task creation (tasks). A waived (null) schedule never widens.
create function expand_pool_radius(p_steps_key text, p_table text) returns void language plpgsql as $$
begin
    if p_table = 'order_lines' then
        update order_lines ol set pool_radius_m = x.target
        from (select l.id,
                     (select max((e->>'radius_m')::int)
                      from jsonb_array_elements(coalesce(config_get(p_steps_key, o.area_id), '[]'::jsonb)) e
                      where (e->>'after_s')::int <= extract(epoch from now() - o.created_at)) as target
              from order_lines l join orders o on o.id = l.order_id
              where l.status = 'open') x
        where ol.id = x.id and x.target > ol.pool_radius_m;
    elsif p_table = 'tasks' then
        update tasks t set pool_radius_m = x.target
        from (select t2.id,
                     (select max((e->>'radius_m')::int)
                      from jsonb_array_elements(coalesce(config_get(p_steps_key, t2.area_id), '[]'::jsonb)) e
                      where (e->>'after_s')::int <= extract(epoch from now() - t2.created_at)) as target
              from tasks t2 where t2.status = 'open') x
        where t.id = x.id and x.target > t.pool_radius_m;
    else
        raise exception 'unknown pool table %', p_table;
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- Delivery pricing. The routing provider (Google, in the application layer) supplies the
-- optimised route distance/duration and each shipment's standalone distance/duration.
-- Nyange alone sets the rates; there is no seller override.
--
--   route_cost = km * rate_per_km + minutes * rate_per_min        (minutes include dwell per stop)
--   fee_i      = ceil_to_step( factor_i * route_cost )
--   factor_i   = share of the route; sum of factors = 1
--                mode 'distance' (default): standalone_km_i / sum(standalone_km)
--                mode 'equal'             : 1 / n
--                mode 'cost'              : standalone_cost_i / sum(standalone_cost)
--   then: fee_i = least(fee_i, standalone_fee_i) if route.cap_at_standalone, and >= route.min_fee_ugx.
-- The agent's approach to the first pickup is not priced.
-- ---------------------------------------------------------------------------
create function compute_route_fees(
    p_route_distance_m integer,
    p_route_duration_s integer,
    p_shipment_ids     uuid[],
    p_standalone_m     integer[],      -- each shipment's own pickup->drop distance, same order as ids
    p_standalone_s     integer[],      -- ... and duration
    p_area             uuid default null,
    p_stop_count       integer default null   -- stops on the route (dwell applies per stop); default = shipments + 1
)
returns table (shipment_id uuid, factor numeric, fee_ugx bigint, standalone_fee_ugx bigint, capped boolean)
language plpgsql stable as $$
declare
    n         integer := coalesce(array_length(p_shipment_ids, 1), 0);
    v_km      numeric := coalesce((config_get('route.rate_per_km_ugx',  p_area))::numeric, 0);
    v_min     numeric := coalesce((config_get('route.rate_per_min_ugx', p_area))::numeric, 0);
    v_dwell   numeric := coalesce((config_get('route.dwell_s_per_stop', p_area))::numeric, 0);
    v_mode    text    := coalesce(config_get('route.factor_mode', p_area) #>> '{}', 'distance');
    v_floor   numeric := coalesce((config_get('route.min_fee_ugx',      p_area))::numeric, 0);
    v_step    numeric := greatest(coalesce((config_get('route.round_to_ugx', p_area))::numeric, 1), 1);
    v_cap     boolean := coalesce((config_get('route.cap_at_standalone', p_area))::boolean, true);
    v_stops   integer := coalesce(p_stop_count, n + 1);
    v_route_k numeric;      -- route cost x 60000: exact (numeric multiply/add never rounds), divided only once at the end
begin
    if n = 0 then raise exception 'no shipments'; end if;
    if array_length(p_standalone_m, 1) is distinct from n or array_length(p_standalone_s, 1) is distinct from n then
        raise exception 'shipment, distance and duration arrays must have equal length';
    end if;
    if v_mode not in ('distance', 'equal', 'cost') then
        raise exception 'unknown route.factor_mode %', v_mode;
    end if;

    -- cost = km * rate_km + minutes * rate_min; scaled by 60000 so that no division happens until the final
    -- ceiling, which keeps exact-multiple costs exact (no repeating-decimal noise, no pre-rounding).
    v_route_k := p_route_distance_m * v_km * 60
               + (p_route_duration_s + v_dwell * v_stops) * v_min * 1000;

    return query
    with base as (
        select ids.id, ids.ord,
               p_standalone_m[ids.ord] as d_m,
               -- standalone trip = pickup + drop, so two stops of dwell
               (p_standalone_m[ids.ord] * v_km * 60
                + (p_standalone_s[ids.ord] + v_dwell * 2) * v_min * 1000) as solo_k
        from unnest(p_shipment_ids) with ordinality as ids(id, ord)
    ), shares as (
        -- factor kept as numerator/denominator so fees multiply before dividing: a share that
        -- should land exactly on a rounding step must not pick up a repeating-decimal error.
        select b.*,
               case
                 when v_mode = 'equal' then 1::numeric
                 when v_mode = 'cost' and sum(b.solo_k) over () > 0 then b.solo_k
                 when v_mode = 'distance' and sum(b.d_m) over () > 0 then b.d_m::numeric
                 else 1::numeric         -- degenerate input (all zero): fall back to equal shares
               end as f_num,
               case
                 when v_mode = 'equal' then n::numeric
                 when v_mode = 'cost' and sum(b.solo_k) over () > 0 then sum(b.solo_k) over ()
                 when v_mode = 'distance' and sum(b.d_m) over () > 0 then sum(b.d_m) over ()::numeric
                 else n::numeric
               end as f_den
        from base b
    ), priced as (
        select sh.*,
               sh.f_num / sh.f_den as f,
               greatest(v_floor, ceil(sh.solo_k / (60000 * v_step)) * v_step) as solo_fee,
               greatest(v_floor, ceil(v_route_k * sh.f_num / (sh.f_den * 60000 * v_step)) * v_step) as share_fee
        from shares sh
    )
    select pr.id,
           pr.f,
           (case when v_cap then least(pr.share_fee, pr.solo_fee) else pr.share_fee end)::bigint,
           pr.solo_fee::bigint,
           (v_cap and pr.share_fee > pr.solo_fee)
    from priced pr
    order by pr.ord;
end $$;

-- Batching is only worthwhile if the combined route is not longer than the trips it replaces
-- (times route.max_detour_ratio; a null/waived ratio always allows batching).
create function route_batch_ok(p_route_distance_m integer, p_standalone_m integer[], p_area uuid default null)
returns boolean language sql stable as $$
    select coalesce(p_route_distance_m <= (config_get('route.max_detour_ratio', p_area))::numeric
                                          * (select sum(x) from unnest(p_standalone_m) x), true)
$$;

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
    -- delivery pricing (rate values are PLACEHOLDERS to be set by Nyange before launch)
    ('route.provider',                        '"google"'),
    ('route.rate_per_km_ugx',                 '1500'),
    ('route.rate_per_min_ugx',                '0'),      -- duration term off until a rate is chosen
    ('route.dwell_s_per_stop',                '0'),
    ('route.factor_mode',                     '"distance"'),
    ('route.min_fee_ugx',                     '0'),
    ('route.round_to_ugx',                    '500'),
    ('route.cap_at_standalone',               'true'),
    ('route.max_detour_ratio',                '1.0'),
    ('route.circuity_factor',                 '1.4'),    -- straight-line -> road estimate at checkout
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
