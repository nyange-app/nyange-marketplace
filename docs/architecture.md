# Nyange architecture

Nyange is a general-purpose marketplace for Uganda. Nyange owns the catalog; sellers own their
prices and stock; Nyange's own pool of field agents performs deliveries and other on-the-ground work.

Status: design plus a tested data layer (`db/schema.sql`). No application code yet. The
application stack is deliberately undecided (see "Decisions and open items").

## 1. Launch scope

- **Goods:** LPG, water (Jibu type), beans, peas, sugar, peanuts, maize, maize flour, soya, soya flour, stationery.
- **Services:** price lists, print house, boda rides, plumber, welder, electrician, building painter, auto mechanic.
  Goods launch first. Services reuse the same claim engine but need their own flows (quotes, real-time dispatch,
  file proofs), so they follow as separate work.
- **Market:** all of Uganda, with pools capped by radius (section 3) and areas activated by supply (section 3).
- **Payments:** cash on delivery, mobile money, in-house wallet.
- **Clients:** React Native is out of scope for now. The API-first backend plus an admin console come first.

## 2. Actors and the two pools

| Actor | Role |
|---|---|
| Buyer | Orders from the Nyange catalog. Never picks a seller. |
| Seller | Keeps standing offers (price, stock, service radius) on catalog variants. Does not set delivery fees. Claims order lines. |
| Field agent | Claims tasks from a pool. Capabilities (delivery, price capture, cash deposit/withdrawal, payment collection, more later) are data, not code. |
| Admin | Curates the catalog, onboards and verifies sellers and agents, resolves disputes, tunes configuration. |

Both pools use the same mechanism: something is posted, eligible actors within a radius see it, one actor claims it
atomically, and it moves through a state machine.

```
Buyer -> order lines -> [ORDER POOL] --claim--> Seller -> ready -> shipment -> delivery task
                                                                                  |
Field agent <------------------ claim ------------------ [TASK POOL: delivery | price_capture | cash_* | ...]
```

## 3. Pools, geography and coverage

- Every pool entry has an anchor point and a radius. Eligibility is a geography query (`ST_DWithin`, metres):
  - order line: within `least(seller location max radius, line pool radius)` of the buyer's drop point;
  - task: agent's last known location within the task's pool radius of its anchor.
- **Radius widening:** unclaimed items widen along configured steps (default 3 km -> 7 km after 2 min -> 15 km
  after 5 min). A scheduler calls `expand_pool_radius`.
- **Coverage gating:** a buyer only sees "order now" in an area with at least the configured minimum of eligible
  sellers and agents. Otherwise they see "not yet available" and can join a waitlist. Controlled by
  `coverage.*` config, off by default.
- **Leases:** a claim must be confirmed within a lease, otherwise `release_expired_claims` returns the item to the pool.

## 4. Orders, per-line claims and affinity

- The claimable unit is the **order line**. Each line has its own state, price lock and escrow slice.
  Order status is derived from its lines.
- **Price at checkout:** sellers hold standing offers. The buyer sees the min-max range across eligible offers in
  their radius and pre-approves up to the max (`order_lines.max_unit_price_ugx`). A claim locks the claiming seller's
  actual offer price. A claim is only allowed if the offer price is at or below the buyer's approved max.
  (Buyer re-confirmation for above-max prices is a possible later addition.)
- **Seller affinity:** when a seller claims one line, they get an exclusive window (default 90 s) on the other open
  lines of the same order, so they can fulfil the whole basket.
- **Shipments:** claimed lines from the same seller location group into one shipment, which becomes one delivery task.
- **Agent affinity:** a delivery task may name a `preferred_agent_id` (an agent already handling a sibling shipment of
  the same order) with a preference window. Multi-pickup tasks use ordered `task_stops`.
- **Partial fulfilment:** lines can expire or be cancelled independently. The buyer is told and chooses.
- **Delivery fee:** computed by Nyange from the optimised route (section 4a). It is paid by the buyer on top of the item price and becomes the task reward the agent sees.

## 4a. Delivery pricing

Nyange alone sets the rates; sellers have no say in delivery fees. A routing provider (Google, behind an interface so
it can be swapped) supplies the geography; the money rules live in `compute_route_fees` in `db/schema.sql`.

1. Once lines are claimed and grouped into shipments, the provider returns one optimised route over all stops:
   total distance `D` and duration `T`, plus each shipment's own standalone pickup-to-drop distance and duration.
2. Route cost = `D (km) x rate_per_km + (T + dwell x stops) (min) x rate_per_min`.
   The duration term lets slow, congested routes cost more than short fast ones. It ships at rate 0 (off) until
   Nyange chooses a rate.
3. Each shipment gets a factor, and the factors sum to 1. Default **distance-weighted**:
   `standalone_km_i / sum(standalone_km)`. Alternatives: `equal`, and `cost` (weighted by standalone distance + time cost).
4. Fee = `factor x route cost`, rounded up to a step (default UGX 500), at least `route.min_fee_ugx`, and **never more
   than that shipment would pay travelling alone** (`route.cap_at_standalone`).
5. `route_batch_ok` refuses to batch when the combined route is longer than the trips it replaces
   (`route.max_detour_ratio`, default 1.0; null waives it).
6. The agent's approach to the first pickup is **not** priced.

Worked example (rate UGX 1,500/km, no duration term): shipments A (8 km alone) and B (9 km alone), combined route 12 km.
Route cost 18,000. Factors 8/17 and 9/17, so A pays 8,500 and B pays 10,000, against 12,000 and 13,500 alone.

Estimates and audit:
- At checkout, before any seller claims, the fee is estimated as straight-line distance x `route.circuity_factor`
  (default 1.4, to be calibrated against real routes). This needs no provider call.
- The real route is requested only after claims, and stored in `route_quotes` / `route_quote_shipments` with the rates,
  factors and resulting fees in force, so any fee can be explained in a dispute.
- The buyer's approved ceiling covers the difference between estimate and final fee.

Provider notes (to verify before relying on them): Google's Routes API can optimise the order of intermediate stops,
but that does not enforce "pickup before drop"; multi-buyer rounds need the Route Optimization API or our own solver.
Check whether a two-wheeler travel mode is supported for Uganda (otherwise car routing approximates boda routes), the
current pricing and a spend alert, and Google's terms on storing results. Road data is weaker outside Kampala.

## 5. Claim engine

A claim is a single conditional `UPDATE ... WHERE status = 'open'` that also checks eligibility and takes a row
lock with `FOR UPDATE ... SKIP LOCKED`. Exactly one claimant wins; everyone else gets `false`.

- `claim_order_line(line, seller, offer)` - checks offer ownership, stock, price vs ceiling, radius, exclusive window.
- `claim_task(task, agent)` - checks status, capability, radius, preferred-agent window, and the cash-float and
  verification levers.
- `release_expired_claims()` and `expand_pool_radius(...)` - scheduler hooks.

Verified (see "Test coverage"): single-winner claims, radius limits, affinity window, price lock, lease release,
radius widening and waiver. Not yet verified: behaviour under truly concurrent sessions. The design relies on the
status guard and `SKIP LOCKED`, but a concurrency test should be added before this is trusted in production.

## 6. Money

All money is integer UGX. The wallet is built in-house as a **double-entry, append-only ledger**:

- every journal sums to zero (enforced by a deferred constraint trigger at commit);
- ledger rows cannot be updated or deleted;
- balances are derived (`account_balances`), never stored;
- every journal has a unique `idempotency_key`, so retried or replayed payment calls and webhooks are safe.

Sign convention: `+amount` is a debit, `-amount` a credit, so credit-normal accounts (wallets, escrow, revenue)
show negative balances. Account owner by kind: buyer wallet -> `users.id`; seller wallet -> `sellers.id`;
agent wallet and agent cash-in-hand -> `agents.id`; system accounts have no owner.

Typical flows:

| Event | Entries |
|---|---|
| Mobile money in | debit `provider_clearing`, credit `escrow` |
| CoD collected by agent | debit `agent_cash_in_hand`, credit `escrow` |
| Agent deposits cash | debit `provider_clearing`, credit `agent_cash_in_hand` |
| Line completed | debit `escrow`; credit `seller_wallet` (price less commission), credit `platform_revenue` (commission) |
| Delivery completed | debit `escrow`; credit `agent_wallet` (fee less cut), credit `platform_revenue` (cut) |
| Withdrawal | debit `seller_wallet` or `agent_wallet`, credit `provider_clearing` |

Mobile money providers are the rails only (collection and payout). A reconciliation job against provider statements
is required.

**Licence:** Nyange already holds the digital wallet licence. To confirm: the licence scope should cover holding buyer
funds in escrow and paying out to sellers and agents, not only buyer wallets. The ledger is provider-agnostic, and
mobile money providers remain the collection and payout rails.

## 7. Cash on delivery and agent risk

CoD makes the agent liable for the cash they hold (the `agent_cash_in_hand` balance). Every control is a
configuration lever and can be scoped globally, per area, or per agent, and **any lever can be waived** by setting
it to JSON `null`. All agent controls ship waived, to make early agent onboarding easy:

| Lever | Meaning |
|---|---|
| `cod.enabled` | CoD on or off |
| `cod.agent.float_limit_ugx` | Max cash an agent may hold; enforced in `claim_task` |
| `cod.agent.settlement_deadline_h` | Hours allowed before collected cash must be deposited |
| `cod.agent.deposit_required_ugx` | Security deposit before an agent can take CoD tasks |
| `cod.agent.verification_required` | Require a verified agent for CoD tasks; enforced in `claim_task` |

`float_limit_ugx` and `verification_required` are enforced in the claim function. Settlement deadline and deposit are
configuration only so far and need application-level enforcement and reporting.

## 8. Configuration

All operational rules live in the `config` table (`key`, `scope`, `scope_id`, `value`). Precedence is
agent/seller scope, then area, then global. A `null` value means waived. See the seed block at the bottom of
`db/schema.sql` for every key and its default (pool radii and steps, lease durations, affinity window, delivery
delivery pricing `route.*`, commissions, CoD levers, coverage gating). Rate values are placeholders for Nyange to set.

## 9. System shape

A modular monolith, split later only if needed:

```
Clients (buyer / seller / agent / admin) -> API + auth (phone OTP, roles)
   modules: Catalog, Offers, Orders+Pool, Tasks+Pool, Ledger+Wallet, Pricing, Notifications
   data:    Postgres + PostGIS (source of truth), job runner (scheduler hooks), object storage, notifications (push/SMS/WhatsApp)
```

- Postgres + PostGIS is the one technology commitment, because radius pools and the ledger need it.
- Mobile-first and low-bandwidth: compressed images, offline-tolerant agent flows, SMS/WhatsApp fallback.
- Audit log on state changes and money movements; alerts on stuck pools.
- Price intelligence: agents capture market prices (`price_observations`), used as a sanity check on offers.

## 10. Decisions and open items

Decided:
1. Per-line claiming, preferring the same seller and same agent where possible.
2. Buyer pays delivery on top of item price. Nyange (not sellers) sets the per-km rate; the fee comes from the optimised route (section 4a).
3. Wallet built in-house; Nyange holds the digital wallet licence.
4. Stack deferred.
5. Nationwide with radius-capped pools.
6. Range pricing with a buyer-approved max (section 4).
7. CoD risk levers all configurable and waivable, shipped waived.
8. Batching: single optimised route, distance-weighted factors, cost per km (plus optional duration term), agent approach unpriced.

Open:
- Application stack and client technology.
- Confirm the wallet licence scope (section 6).
- Placeholder rates: `route.rate_per_km_ugx` (1,500) and `route.rate_per_min_ugx` (0) need real values.
- Routing provider limits for Uganda (two-wheeler mode, coverage, pricing, storage terms) and the Route Optimization path for multi-buyer rounds.
- Enforcement of settlement deadline and agent deposit.
- Service flows (quotes, boda dispatch, print job files).
- Concurrency test for the claim functions.
- Vehicle class and load limits per task (what a boda can carry decides whether batching is possible).

## 11. Verification status

There is no committed test suite yet; the design is still being settled.

- The pricing function (`compute_route_fees`) was exercised by hand against a scratch PostgreSQL 16 database during
  design: distance-weighted and equal factors, the duration and dwell terms, the standalone cap, the minimum fee and the
  batch refusal rule. That run found and fixed a rounding bug (a repeating-decimal factor pushing an exact share up one
  rounding step). The scripts were not kept.
- The claim engine and ledger were checked by hand when the schema was first written (single-winner claims, radius,
  affinity window, price lock, lease release, journal balance, idempotency, immutability, cash-float gate, radius
  widening). They were not re-run after the pricing changes; only the schema load and the pricing function were.
- Not yet verified at all: behaviour under truly concurrent claims.

A committed automated suite, including a concurrency test, should be written once the design is agreed.
