# Nyange: business specification

Nyange is a general-purpose marketplace for Uganda. Nyange owns the catalog; sellers own their prices and stock;
Nyange's own pool of field agents performs deliveries and other on-the-ground work.

This document states **what the business does**: actors, workflows, lifecycles, rules and invariants. It deliberately
says nothing about how any of it is built, stored or enforced. Technology choices are made separately, and any
implementation must satisfy the invariants in section 7.

## 1. Scope at launch

- **Goods:** LPG, water (Jibu type), beans, peas, sugar, peanuts, maize, maize flour, soya, soya flour, stationery.
- **Services:** price lists, print house, boda rides, plumber, welder, electrician, building painter, auto mechanic.
  Goods launch first. Services follow as separate work, because they need their own flows (quotes, real-time
  dispatch, file proofs).
- **Market:** all of Uganda. Availability is local: an area opens when enough supply exists in it (section 3.2).
- **Payment methods:** cash on delivery (CoD), mobile money, Nyange wallet.
- **Assumption:** Nyange holds every licence and registration it needs to operate (wallet, payments, escrow,
  payouts, others). Legal and regulatory questions are out of scope here.

## 2. Actors

| Actor | Role |
|---|---|
| **Buyer** | Orders from the Nyange catalog. Never chooses a seller. |
| **Seller** | Keeps standing offers (price, stock, service radius) on catalog items, from one or more locations they own. Claims order lines. Does not set delivery fees. |
| **Field agent** | Claims tasks from a pool. Each agent has capabilities (delivery, market price capture, cash deposit, cash withdrawal, payment collection, more to be added). Belongs to Nyange's pool. |
| **Admin** | Curates the catalog, onboards and verifies sellers and agents, resolves disputes, sets rules and parameters. |

## 3. Core concepts

- **Catalog:** the list of goods and services Nyange sells. Nyange owns it; sellers cannot add products, only offer on them.
- **Offer:** a seller's standing price and stock for a catalog item, tied to one of the seller's own locations.
- **Order:** a buyer's request, made of **order lines** (one per catalog item and quantity).
- **Order line:** the unit sellers claim. Each line has its own status, locked price and payment share.
- **Shipment:** the lines from one seller location that travel together.
- **Task:** a unit of work for a field agent (a delivery, a price capture, a cash deposit, and so on).
- **Pool:** the set of open order lines (for sellers) or open tasks (for agents). Each pool entry has a location and a
  search radius; only actors within range can see and claim it.
- **Claim:** one actor taking an open pool entry. At most one actor can hold a claim on an entry at a time.
- **Confirmation window:** how long a claimant has to confirm before the claim lapses and the entry returns to the pool.
- **Area:** a named region of the country. Rules can be set per area and override the national defaults for anything
  located inside that area.

### 3.1 Radius and widening

- A pool entry is visible to an actor only within range:
  - **Order line:** the seller location must be within the smaller of the seller's own service radius and the line's current search radius, measured from the buyer's drop point.
  - **Task:** the agent's last known location must be within the task's search radius of the task's anchor point.
- An unclaimed entry widens its search radius in steps over time (default: 3 km, then 7 km after 2 minutes, then 15 km after 5 minutes).
- Radius schedules can differ by area, and can be turned off for an area.

### 3.2 Coverage

- When coverage gating is on, a buyer can order only in an area that has at least the minimum number of eligible sellers and agents. Otherwise they see "not yet available" and may join a waitlist.
- Default: off.

## 4. Workflows

### The order journey at a glance

1. The buyer places an order; each line enters the order pool.
2. Sellers claim every line.
3. Once all lines are claimed, the **final delivery fee** is fixed and the buyer is notified (push and in-app).
4. The buyer has **15 minutes** to **approve or cancel**.
5. On approval: a prepaid buyer **pays within 60 minutes**; a CoD buyer has nothing to pay yet.
6. Sellers **ready the goods for pickup** (prepaid: only after payment is confirmed; CoD: straight after approval).
7. A field agent collects and delivers. CoD cash is collected at the drop-off.
8. Money is settled to sellers and the agent.

### 4.1 Buyer places an order

1. Buyer chooses catalog items and quantities, pins a drop location, and picks a payment method.
2. For each line, the buyer sees the **price range** across eligible standing offers in range (lowest to highest) and **approves up to the highest**. That approval is the line's price ceiling.
3. The buyer also sees an **indicative delivery estimate** (section 5). It is not a commitment: the real fee is only known once every line is claimed (section 4.3), and the buyer decides then.
4. Each line enters the order pool.

### 4.2 Seller claims a line

1. Eligible sellers (in range, with a matching standing offer in stock, active) see the open line.
2. A seller claims by choosing their offer. The claim succeeds only if the offer price is at or below the buyer's ceiling.
3. On success the seller's actual offer price is **locked** for that line, and the seller must confirm within the confirmation window or the line returns to the pool.
4. **Seller affinity:** after a seller claims one line, they have an exclusive window (default 90 seconds) to claim the other open lines of the same order, so they can fulfil the whole basket. After the window, those lines open to everyone.
5. Whoever loses a contested claim gets a clear "already taken" answer. Nobody is left waiting or errored.
6. *(Proposed.)* Once confirmed, a seller stays committed to the line until the buyer decides. If the buyer cancels, or the decision window passes without approval, or (prepaid) the payment window passes without payment, every seller is released at no cost to them, because no seller prepares anything before the buyer approves.

### 4.3 Final fee, buyer decision, payment and preparation

1. When **all of the order's lines are claimed**, Nyange works out the best route and fixes the **final delivery fee** (section 5). Lines from the same seller location form one shipment; shipments from different sellers may share one route.
2. The buyer is **notified of the final delivery fee** and the order total through **both a push notification and a durable in-app notification**, and has **15 minutes** to **approve or cancel** the whole order. They may cancel if the fee is higher than they are willing to pay.
3. If the buyer **approves**:
   - *Mobile money / wallet:* the buyer pays the total within **60 minutes of approving**. Sellers **ready their goods for pickup only after payment is confirmed**. If payment is not confirmed within the 60 minutes, the order is cancelled and every seller is released. The buyer is shown the payment deadline. To avoid late confirmations, *(proposed)* new payment attempts close a short time before the deadline, and an attempt already in progress at the deadline gets a short grace for the provider's answer instead of being cut off: if it succeeds the order proceeds, if it fails the order is cancelled.
   - *CoD:* there is nothing to pay up front, so sellers ready their goods straight away.
4. If the buyer **cancels**, or the 15 minutes pass with no decision (**silence cancels**), the order is cancelled and every seller is released. Nothing has been prepared yet, so nobody is out of pocket.
5. The delivery task is then offered to agents. *(Proposed timing: once the buyer has approved and, for prepaid orders, payment is confirmed. Whether agents may see it before the goods are ready is open, section 9.)*

### 4.4 Agent claims a task

1. Eligible agents (active, capable of the task type, in range) see open tasks. A delivery task for an order appears only after the buyer has approved the final fee (and, for prepaid orders, paid).
2. **Agent affinity:** a delivery task can be offered first, for a short window, to an agent already handling another shipment of the same order. After the window it opens to all eligible agents.
3. A claim is subject to the cash controls in section 6 when the task involves collecting cash.
4. An agent must confirm within the confirmation window or the task returns to the pool.
5. A task may have several ordered stops (for example two pickups then a drop-off).

### 4.5 Delivery and settlement

1. The agent collects the goods, delivers them, and records the outcome.
2. **Payment:**
   - *Mobile money / wallet:* the buyer pays the full total (items plus final delivery fee) after approving; the money is held by Nyange until delivery.
   - *CoD:* the agent collects cash at the drop-off. The agent now owes that cash to Nyange until they deposit it.
3. When a line is completed, Nyange releases the money: the seller receives the item price less commission, the agent receives the delivery fee less Nyange's cut, and Nyange keeps commissions and cuts.
4. Sellers and agents can withdraw their balance to mobile money.

### 4.6 Cancellation, expiry and partial fulfilment

*Draft: only partial fulfilment was decided so far; the cancellation, expiry and dispute rules below are proposals that need confirmation (section 9).*

- A buyer may cancel lines that no seller has claimed yet; cancelling an order cancels all of its unclaimed lines.
- A line nobody claims within its allowed time expires. The buyer is told and chooses what to do with the rest of the order.
- If the buyer cancels on seeing the final delivery fee, or does not decide within 15 minutes, the whole order is cancelled and nothing is delivered. If a prepaid buyer approves but payment is not confirmed within 60 minutes, the order is cancelled the same way. In these cases no payment has been confirmed, so nothing is refunded. If a payment is nonetheless confirmed after the order was cancelled, it is **refunded in full** and the order is **never revived**. *(Decided that the buyer can cancel at this point.)* Cancelling after payment is a different case and is open (section 9).
- Lines are fulfilled independently: an order can complete with some lines delivered and others cancelled or expired. *(Decided.)*
- If goods are not delivered or disputed, an admin resolves the dispute and the money follows the resolution.

## 5. Delivery pricing

**Nyange alone sets delivery rates. Sellers have no say.** The buyer pays the delivery fee on top of item prices; it
becomes the agent's reward for the delivery.

1. Once **all of the order's lines are claimed**, a **single best route** is worked out over all stops. This gives the route's total distance and travel time, plus each shipment's own standalone distance and time (as if it travelled alone).
2. **Route cost** = route kilometres × rate per km, plus (route minutes + a dwell allowance per stop) × rate per minute. The time term makes slow, congested routes cost more than short, fast ones. It is off until Nyange chooses a rate.
3. Each shipment gets a **share** of the route cost; shares add up to 100%. Default rule: **weighted by standalone distance** (a farther seller carries more). Alternatives: equal shares, or weighted by standalone cost.
4. A shipment's fee is its share, **rounded up** to the rounding step (default UGX 500), at least the minimum fee, and **never more than that shipment would pay travelling alone**.
5. **Batching is only worthwhile if the combined route is not longer than the separate trips it replaces** (times an allowed ratio, default 1.0). Otherwise the shipments are delivered separately at their standalone fees.
6. The agent's trip to the first pickup is **not** charged to the buyer.

**Worked example** (rate UGX 1,500/km, no time term): shipment A would be 8 km alone, B 9 km alone, and the combined route is 12 km. Route cost 18,000. Shares 8/17 and 9/17, so A pays 8,500 and B pays 10,000, against 12,000 and 13,500 if delivered separately.

**Fee timing:** the delivery fee is **final only after all lines are claimed**. The buyer is then notified (push and in-app) and has 15 minutes to approve or cancel (section 4.3). Nothing is charged for delivery before the buyer has seen and approved the final amount, and the amount does not change after it has been shown.

**Indicative estimate:** at ordering, before any seller has claimed, the buyer sees only an estimate from straight-line distance multiplied by a road factor (default 1.4, to be calibrated against real routes). It is a guide, not a promise.

**Audit:** for every delivery, Nyange keeps the route, the rates and shares used, and the resulting fees, so any fee can be explained in a dispute.

**Routing source:** the route and times come from an external mapping source (initially Google Maps Platform). Its fit for Uganda is an open question (section 9).

## 6. Money and cash on delivery

### 6.1 Money rules

- All amounts are whole Ugandan shillings.
- Every movement of money is recorded as a balanced entry (what leaves one place arrives in another).
- History is never changed or removed; corrections are new entries.
- Balances are always the result of the history, never a number edited by hand.
- A repeated payment instruction (a retried request, a duplicate notification from a provider) takes effect once.
- Mobile money providers are only the way money moves in and out. Nyange reconciles against their statements.

| Event | Money moves |
|---|---|
| Buyer pays by mobile money | Provider → Nyange-held funds |
| Agent collects CoD cash | Agent's cash-in-hand ↑ (agent owes Nyange); Nyange-held funds ↑ |
| Agent deposits cash | Agent's cash-in-hand ↓; provider/bank ↑ |
| Line completed | Nyange-held funds → seller (price less commission) + Nyange revenue (commission) |
| Delivery completed | Nyange-held funds → agent (fee less cut) + Nyange revenue (cut) |
| Withdrawal | Seller or agent balance → provider |
| Payment confirmed after the order was cancelled | Nyange-held funds → buyer (full refund) |

### 6.2 Cash on delivery controls

An agent holding collected cash is exposed to loss or theft. Every control below is a tunable rule, can be set nationally,
per area, or per agent, and **can be waived entirely**. At launch they are all waived to make agent onboarding easy.

| Control | Meaning |
|---|---|
| CoD enabled | CoD can be turned on or off |
| Float limit | The most cash an agent may hold or have promised to collect at once |
| Settlement deadline | How long collected cash may be held before it must be deposited |
| Security deposit | A deposit an agent must put up before taking CoD tasks |
| Verification required | Only verified agents may take CoD tasks |

**Float limit rule:** cash already held + cash promised on tasks the agent has claimed but not completed + the cash on the
task being claimed must not exceed the limit. A claim that lapses releases its promised cash. When a CoD task is completed,
its cash moves from "promised" to "held" exactly once.

## 7. Invariants

Rules that must always hold, whatever technology implements them.

**Claims**
1. An order line has at most one seller holding a claim at any time. A task has at most one agent.
2. Two actors claiming at the same moment each get a definite answer (won, or already taken). Neither fails, hangs or sees an error. This includes two sellers claiming different lines of the same order.
3. Only an actor in range can claim; the price locked on a line is never above the buyer's approved ceiling.
4. A claim that is not confirmed in time lapses, and the entry returns to the pool.
5. Lines of a cancelled order cannot be claimed. If a cancellation and a claim happen at the same moment, one clearly happens first and the outcome is consistent.
6. Only active sellers and agents can claim, and only if their account is also active. Suspending an account stops its claims.
7. A seller can only fulfil from a location they own; an offer is always tied to a location of the offering seller.
8. While a seller holds the exclusive window on an order's lines, others cannot claim them. When it ends, they open to everyone.

**Rules by area**
9. For anything located inside an area, rules set for that area override national ones. Anything outside every area uses the national rules. This applies to confirmation windows, affinity windows, cash controls and radius schedules alike.

**Money**
10. Every money movement balances; nothing is created or lost.
11. Money history is permanent: it cannot be edited, removed or wiped by anyone, including administrators.
12. A balance can always be re-derived from the history.
13. The same payment instruction applied twice has the same effect as once.
14. An agent's cash held plus promised never exceeds their float limit, where a limit is set.
15. CoD cash is counted exactly once at every moment: as promised, then as held.

**Delivery fees**
16. Only Nyange sets delivery rates; sellers cannot.
17. Shares of a route add up to 100% of the route cost.
18. A shipment never pays more than it would travelling alone (when that cap is on), never less than the minimum fee, and is always rounded **up** to the step, never down.
19. A delivery fee is fixed only after all of the order's lines are claimed. The buyer is never charged it without having been shown the final amount and given 15 minutes to approve or cancel, and the amount shown is the amount charged.
20. The buyer is notified of the final fee through both a push and a durable in-app notification.

**Order sequence**
21. No delivery task is offered to agents before the buyer has approved the final fee and, for prepaid orders, payment is confirmed.
22. For prepaid orders, sellers ready goods for pickup only after payment is confirmed. For CoD orders, only after the buyer has approved. No seller prepares goods before the buyer has approved.
23. An order that is not approved within 15 minutes, or (prepaid) not paid within 60 minutes of approval, is cancelled and every seller is released.
24. A cancelled order is never revived. Any payment confirmed for an order that is already cancelled is refunded in full.

## 8. Tunable rules and parameters

Each can be set nationally, overridden per area (and per agent for cash controls), and waived (turned off) where it makes sense.

| Parameter | Launch default |
|---|---|
| Initial search radius (orders, tasks) | 3 km |
| Radius widening schedule | 7 km after 2 min; 15 km after 5 min |
| Confirmation window (seller and agent) | 10 minutes |
| Seller exclusive window (affinity) | 90 seconds |
| Buyer decision window on the final fee | 15 minutes (no decision cancels) |
| Prepaid payment window after approval | 60 minutes (no confirmed payment cancels) |
| Payment cut-off before the deadline (new attempts stop) | to be decided |
| Grace for a payment in progress at the deadline | to be decided |
| Final-fee notification channels | push and durable in-app |
| Agent preference window (affinity) | to be decided |
| Delivery rate per km | UGX 1,500 (placeholder) |
| Delivery rate per minute | 0 (off, placeholder) |
| Dwell allowance per stop | 0 |
| Share rule | weighted by distance |
| Minimum delivery fee | 0 |
| Rounding step | UGX 500 |
| Cap fee at standalone cost | on |
| Allowed detour ratio for batching | 1.0 |
| Checkout estimate road factor | 1.4 |
| Commission on goods / on delivery | 0% / 0% |
| CoD enabled | yes |
| Agent float limit, settlement deadline, security deposit | waived |
| Verification required for CoD | no |
| Coverage gating (minimum sellers / agents) | off (1 / 1) |

## 9. Decisions and open questions

**Decided**
1. Per-line claiming, preferring the same seller and the same agent where possible.
2. The buyer pays delivery on top of item price. Nyange, not sellers, sets the rates; the fee comes from the optimised route (section 5).
3. The wallet is built by Nyange. All required licences are assumed in place.
4. Technology stack: deferred. This document does not depend on it.
5. Nationwide, with radius-capped pools and areas opening on supply.
6. Range pricing at checkout with a buyer-approved ceiling; the claim locks the seller's real price.
7. All CoD controls are tunable and waivable, and ship waived.
8. Batching: one best route, shares weighted by distance, cost by distance (plus an optional time term), agent's approach to the first pickup not charged.
9. The delivery fee is final only after all of the order's lines are claimed. The buyer is notified (push and in-app) and has 15 minutes to approve or cancel the order.
10. After approval a prepaid buyer pays the full total. Sellers ready the goods for pickup only after payment is confirmed (prepaid) or straight after approval (CoD).
11. Silence cancels: no decision within 15 minutes cancels the order, and a prepaid order with no confirmed payment within 60 minutes of approval is cancelled.
12. A payment confirmed after its order was cancelled is refunded in full; the order is never revived. Preventing such late payments is preferred (cut-off and grace, section 4.3).

**Open**
- Real values for the per-km and per-minute rates (placeholders for now).
- Cancellation: who may cancel what and when, especially lines already claimed by a seller or already out for delivery.
- Expiry: how long an unclaimed order line waits before it expires.
- Disputes: what counts as a dispute, who can raise one, and how an admin's resolution moves the money.
- The payment cut-off before the deadline and the grace for a payment in progress at the deadline: how long each should be.
- Refunds of late payments: how quickly they are returned, and who bears any provider charges.
- Cancelling after payment is confirmed or after goods are ready: who may cancel, refund rules, and who bears any cost.
- Whether agents see the delivery task before the goods are ready, or only once they are.
- If a seller drops out of a line after the buyer has approved, what happens to the order.
- When some lines expire or are cancelled, whether the final fee is fixed over the remaining lines, and when an order stops waiting for stragglers.
- Whether agent affinity is still needed now that one route is planned for the whole order, or only for shipments delivered separately.
- What happens to a delivery task that is still unclaimed at the widest radius (cancel, escalate to operations, or keep waiting).
- Whether the mapping source works well enough for Uganda: coverage outside Kampala, boda (two-wheeler) routing, cost, and rules on storing results. Multi-buyer rounds also need ordering rules such as "pickup before drop".
- How the settlement deadline and the security deposit are enforced and reported.
- Service flows: quotes, boda dispatch, print jobs with file proofs.
- Vehicle class and load limits per task (what a boda can carry decides whether batching is possible).
- The agent preference window length.
