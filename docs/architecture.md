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
- **Payment methods:** cash on delivery (CoD) and digital payments (mobile money and the Nyange wallet). Every digital payment goes through the actor's Nyange wallet (section 6).
- **Assumption:** Nyange holds every licence and registration it needs to operate (wallet, payments, escrow,
  payouts, others). Legal and regulatory questions are out of scope here.

## 1a. Operating principle: operations are mostly off the platform at launch

At launch, Nyange's operations team handles much of the day-to-day coordination **off the platform**, by phone and
messaging. The platform is not asked to model every recovery or exception. Its job is narrower:

1. Enforce the rules and invariants in this document.
2. Keep money safe: hold it, move it only as the rules allow, and record every movement.
3. Record decisions and outcomes, so there is always a clear account of what happened and why.
4. Tell the parties about status changes as the workflows specify.

**Admin actions the platform must provide**, so operations can record what they decide:
- raise a dispute, including on their own initiative (section 4.6);
- record a dispute outcome: refund (a full refund cancels the order), partial refund, release to the seller and agent, or a split;
- assign a specific agent to a task, even outside the radius (section 4.6).
- widen the search radius of an unclaimed task (section 4.6).

**Deliberately left to operations, and not designed in this document:** how agents report problems; noticing stalled or
overdue deliveries; contacting buyers, sellers and agents; a takeover by another agent and the handover; returning goods
to sellers; paying a first agent for part of a trip; agent liability and suspension.

Whatever operations do, money only moves through the platform's actions, so the invariants keep holding. Items can move
onto the platform later, if volume makes off-platform handling impractical.

## 2. Actors

| Actor | Role |
|---|---|
| **Buyer** | Orders from the Nyange catalog. Never chooses a seller. |
| **Seller** | Keeps standing offers (price, stock, service radius) on catalog items, from one or more locations they own. Claims order lines. Does not set delivery fees. |
| **Field agent** | Claims tasks from a pool. Each agent has capabilities (delivery, market price capture, cash deposit, cash withdrawal, payment collection, more to be added). Belongs to Nyange's pool. |
| **Admin** | Curates the catalog, onboards and verifies sellers and agents, resolves disputes, sets rules and parameters. |

**Operations** means Nyange's admins working day to day; "operations" and "admins" refer to the same people.

**Every user is a buyer (customer) by default.** Becoming a seller, field agent or admin adds a role to the same account; one person can hold several roles. Every user has a **Nyange wallet** (section 6). A person has **one wallet**, shared across all their roles.

## 3. Core concepts

- **Catalog:** the list of goods and services Nyange sells. Nyange owns it; sellers cannot add products, only offer on them.
- **Offer:** a seller's standing price and in-stock status for a catalog item, tied to one of the seller's own locations. For a returnable container, the offer states a price for each mode the seller supports.
- **Returnable container:** a catalog item sold in a container the buyer normally returns (LPG cylinders, 20L water bottles). Its order lines have a **container mode**: *swap* (the buyer hands over an empty and receives a full one) or *new* (the buyer buys the container with its contents).
- **Order:** a buyer's request, made of **order lines** (one per catalog item and quantity).
- **Order line:** the unit sellers claim. Each line has its own status, locked price and payment share.
- **Shipment:** the lines from one seller location that travel together. Shipments that share a route are one delivery task with several stops; shipments that are not batched are each their own delivery task, so an order can have several delivery tasks.
- **Task:** a unit of work for a field agent (a delivery, a price capture, a cash deposit, and so on).
- **Pool:** the set of open order lines (for sellers) or open tasks (for agents). Each pool entry has a location and a
  search radius; only actors within range can see and claim it.
- **Claim:** one actor taking an open pool entry. At most one actor can hold a claim on an entry at a time.
- **Wallet:** every user has one. All digital money lands in it first.
- **Hold:** a restriction on part of a wallet's money, recorded as its own object. There are two kinds: a **transaction hold**, which protects money from a payment while it can still be reversed, and a short-lived **transfer hold**, which reserves money while a transfer is being effected so a wallet cannot be overdrawn (section 6.3).
- **Dispute:** a recorded objection by a party to an order about specific lines and/or the delivery fee, which keeps the disputed money on hold until an admin decides (section 4.6).
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
5. On approval: a prepaid buyer **pays within 60 minutes**, by mobile money or from their wallet. The sellers' shares land **directly in the sellers' wallets**, on hold; the delivery fee lands with Nyange and passes to the delivery agent's wallet, on hold, when an agent claims the task. A CoD buyer has nothing to pay yet.
6. Sellers **ready the goods for pickup** (prepaid: only after payment is confirmed; CoD: straight after approval).
7. Once the goods are ready, the delivery task is offered to agents. A field agent claims it, collects and delivers. For CoD, the cash is collected at the drop-off and then **handed over to Nyange**; only then are the sellers and the agent credited.
8. After delivery, the holds on the payment end once the reversal window has passed (default 4 hours), and sellers and the agent can withdraw.

### 4.1 Buyer places an order

1. Buyer chooses catalog items and quantities, pins a drop location, and picks a payment method. For a returnable-container item, the buyer also chooses **swap** or **new container**.
2. For each line, the buyer sees the **price range** across eligible standing offers in range (lowest to highest) and **approves up to the highest**. That approval is the line's price ceiling. For a returnable container, the range is for the chosen container mode.
3. The buyer also sees an **indicative delivery estimate** (section 5). It is not a commitment: the real fee is only known once every line is claimed (section 4.3), and the buyer decides then.
4. Each line enters the order pool.

### 4.2 Seller claims a line

1. Eligible sellers (in range, with a matching standing offer in stock, active) see the open line.
2. A seller claims by choosing their offer. The claim succeeds only if the offer price (for the line's container mode, where there is one) is at or below the buyer's ceiling.
3. On success the seller's actual offer price is **locked** for that line, and the claim is firm: there is no separate confirmation step.
4. **Seller affinity:** after a seller claims one line, they have an exclusive window (default 90 seconds) to claim the other open lines of the same order, so they can fulfil the whole basket. After the window, those lines open to everyone.
5. Whoever loses a contested claim gets a clear "already taken" answer. Nobody is left waiting or errored.
6. Once they have claimed, a seller is expected to stay with the line, but may withdraw before payment under the rules in section 4.6. If the buyer cancels, or the decision window passes without approval, or (prepaid) the payment window passes without payment, every seller is released at no cost to them, because no seller prepares anything before the buyer approves.
7. Stock is a simple **in-stock** status on the offer; the platform does not count or reserve quantities. A line is claimed whole by one seller (lines are not split between sellers). A seller who cannot supply a line they claimed withdraws or drops out under the rules in section 4.6.

### 4.3 Final fee, buyer decision, payment and preparation

1. When **all of the order's lines are claimed**, Nyange works out the best route and fixes the **final delivery fee** (section 5). Lines from the same seller location form one shipment; shipments from different sellers may share one route.
2. The buyer is **notified of the final delivery fee** and the order total through **both a push notification and a durable in-app notification**, and has **15 minutes** to **approve or cancel** the whole order. They may cancel if the fee is higher than they are willing to pay.
3. If the buyer **approves**:
   - *Mobile money / wallet:* the buyer pays the total within **60 minutes of approving**, by mobile money or from their wallet. The money is split on arrival: each seller's share lands **directly in that seller's wallet**, **on hold** (section 6); the delivery fee and Nyange's commission land with Nyange, and the delivery fee passes to the delivery agent's wallet, on hold, when an agent claims the delivery task (section 4.4). Sellers **ready their goods for pickup only after payment is confirmed**. If the order is not paid within the 60 minutes, it is cancelled and every seller is released. A payment that arrives after that is not applied (it lands in the payer's wallet, section 6.2) and the order is **never revived**.
   - *CoD:* there is nothing to pay up front, so sellers ready their goods straight away.
4. If the buyer **cancels**, or the 15 minutes pass with no decision (**silence cancels**), the order is cancelled and every seller is released. Nothing has been prepared yet, so nobody is out of pocket.
5. A delivery task (or tasks, if the shipments are not batched) is offered to agents **only once its goods are ready**: for a task with several pickups, once all the lines on it are ready; for a separate shipment, once that shipment's lines are ready. Goods are readied only after the buyer has approved and, for prepaid orders, paid, so the earlier conditions are already met. This way no agent waits at a seller's. Pickup timing is otherwise coordinated off the platform. *(Decided.)*

### 4.4 Agent claims a task

1. Eligible agents (active, capable of the task type, in range) see open tasks. A delivery task for an order appears only once its goods are ready (which happens only after the buyer has approved the final fee and, for prepaid orders, paid).
2. A claim is subject to the cash controls in section 6 when the task involves collecting cash.
   - *Delivery fee (prepaid orders):* when an agent claims a delivery task, Nyange passes the delivery fee (less its cut) from the amount it holds to the agent's wallet, **on hold** until the delivery is done and the reversal window has passed. If the agent later drops the task, that credit is taken back and the fee passes to the next agent who claims it. For CoD orders the agent's fee is credited after the handover instead (section 4.5).
3. A task may have several ordered stops (for example two pickups then a drop-off).

### 4.5 Delivery and settlement

1. The agent collects the goods, delivers them, and records **proof of delivery** and the outcome. Proof is the code the buyer gives at the door; a photo is then optional. If the buyer cannot give the code, the agent records the delivery with a **photo (required)** and the reason "code unavailable"; the buyer is told at once and the delivery is flagged. If the buyer refuses or cannot be reached, no delivery is recorded and it is handled as a dispute. For a **swap** line, the agent also collects the buyer's empty container and records it (a photo). If the buyer has no empty to hand over, the swap cannot be completed and it is handled as a dispute (reason: swap not possible).
2. **Payment:**
   - *Mobile money / wallet:* the buyer's payment has already landed in the wallets of the sellers and the delivery agent, on hold (section 4.3).
   - *CoD:* the agent collects cash at the drop-off. The agent owes that cash to Nyange until they **hand it over**. **Nyange credits the sellers and the agent only once the full CoD amount has been handed over**; until then nobody is credited.

   **Handover of CoD cash** is done in the app, in either of two ways:
   - *From float:* if the agent keeps money in their own wallet in advance (their *float*), they hand the cash over immediately from it.
   - *Through mobile money:* the agent deposits the cash onto their own mobile money, then pays Nyange's company wallet through the mobile money rail and records it in the app.

   Once Nyange's company wallet has received the full CoD amount, the sellers' shares (price less commission) and the agent's fee (less Nyange's cut) are credited to their wallets, **on hold** like any other payment. Because delivery is already complete, the reversal window runs from the moment the money lands. *(Proposed: if a dispute is open when the handover completes, the disputed amounts are credited on hold and stay held until it is decided.)*
3. After delivery, the holds on the money paid for the order end once the reversal window has passed (default 4 hours after delivery), and the money becomes available to each seller and the agent. Nyange keeps its commission and cut.
4. Sellers and agents withdraw their available money from their wallet to their own mobile money number.

### 4.6 Cancellation, drop-outs, expiry and partial fulfilment

#### Before payment

- Until the buyer approves the final delivery fee, they can cancel the **whole order at any time, free**. Any sellers who have claimed lines are released at no cost to them. *(Decided.)*
- If the buyer cancels on seeing the final delivery fee, or does not decide within 15 minutes, the whole order is cancelled and nothing is delivered. If a prepaid buyer approves but payment is not confirmed within 60 minutes, the order is cancelled the same way. In these cases nothing has been paid for the order, so nothing is refunded. A payment that arrives after the order was cancelled is not applied: it lands in the payer's wallet (section 6.2), and the order is **never revived**. *(Decided.)*
- **Overall time cap:** an order that is not **fully committed** within **3 hours** of being placed is cancelled and every seller is released. Fully committed means paid (prepaid orders) or approved with every line claimed (CoD orders). The cap runs through every restart: a seller's withdrawal can restart the buyer's 15 minutes or give a fresh 60 minutes to pay, but never extends the 3 hours. From the moment an order is fully committed, the later deadlines apply. *(Decided.)*

#### Buyer cancels after payment *(decided)*

After payment the buyer can cancel only the **whole order**, not single lines. An order's stage is that of its **most advanced shipment**: once any shipment is picked up, the buyer can no longer cancel.

| Stage | What the buyer can do |
|---|---|
| Paid, no line ready yet | Cancel **free**, with a full refund |
| Goods ready, nothing picked up yet | Cancel. A **cancellation fee** compensates the sellers whose goods were ready. **The fee is 0% at launch**, so at launch this is also free. No fee ever applies while any delivery task of the order is unclaimed |
| Any shipment picked up, out for delivery | Cannot cancel. Refusing delivery becomes a dispute handled by an admin |
| Delivered | Not cancellable. Any problem is a dispute |

- **Cancellation fee:** a percentage, tunable and waivable, **0% at launch**. *(Proposed base: a percentage of the item price of the lines that were ready, paid to the sellers of those lines.)*
- **Refund:** everything paid is returned to the buyer's wallet, less any cancellation fee. The sellers' holds are consumed and the money taken back; each delivery fee is returned from the agent's hold, or from Nyange if no agent has claimed that task. Any cancellation fee stays with the sellers concerned.
- **CoD orders:** nothing has been paid, so there is nothing to refund; the same stages apply.

#### A seller withdraws a claim before payment *(decided)*

| When the seller withdraws | What happens |
|---|---|
| Claimed, fee not yet final (still waiting for other lines) | Allowed freely, because the buyer is not yet involved. The line returns to the pool at once. |
| Fee final, buyer deciding (inside the 15 minutes) | The fee the buyer was shown is void. The buyer is told, and the order goes back to waiting for all lines. When it is whole again, a new final fee is fixed and the buyer gets a **fresh notification and a fresh 15 minutes**. |
| Buyer approved, not yet paid | Handled as a drop-out after approval (below): up to 30 minutes for a replacement, and re-approval if the total rises. **Payment is paused** while any line is unclaimed, and the buyer gets **a fresh 60 minutes to pay** once the order is whole again. |
| After payment | Handled by the drop-out rules below. |

- A seller who withdraws a line cannot claim that same line of that order again.
- The drop-out penalty rule (waived at launch) also covers withdrawals after claiming.
- A line that nobody claims within **30 minutes** of entering the pool (whether new or returned) expires; see below.

#### A seller drops out after the buyer has approved

- *(Decided.)* The line goes back to the pool for up to **30 minutes** and the buyer is told. The dropped seller's credit for that line is taken back and held by Nyange until a replacement seller claims the line or the buyer is refunded.
- *(Decided.)* If a replacement claims and the order total is unchanged or lower, the order carries on. If the total would be higher (a pricier seller, or a changed delivery fee), the buyer must re-approve within **15 minutes**, otherwise the order is cancelled with a full refund. The same applies to any change that would raise what the buyer pays.
- *(Decided.)* If nobody claims the line within the 30 minutes, the buyer chooses within 15 minutes: cancel the whole order with a full refund, or carry on without that line and be refunded for it. No choice within the 15 minutes cancels the order (silence cancels, as elsewhere).
- **Penalties** for a seller or agent who drops out after the buyer has approved are a tunable rule (amount, and whether they apply at all). **They are waived at launch.**

#### No agent claims a delivery task *(decided)*

A delivery task is offered within a radius that widens (3 km, then 7 km after 2 minutes, then 15 km after 5 minutes). There is no price lever, because the delivery fee comes from the route. An order can have several delivery tasks (section 3), and these rules apply **to each task**.

1. **Ten minutes after the widest radius is reached** with no claim, the task is flagged to operations (admins), and the buyer is told at the same moment. Operations can assign a specific agent directly (even outside the radius), widen the radius further, or contact the parties.
2. The buyer chooses: keep waiting, or cancel with a full refund. If nothing has been picked up yet, they cancel the whole order; if another shipment is already in progress, they cancel only the unclaimed shipment. Self-collection by the buyer is not offered.
3. **While any delivery task of the order is unclaimed and nothing has been picked up, the buyer can cancel the whole order with a full refund and no cancellation fee**, even if goods are ready, because the failure to find an agent is not the buyer's.
4. **Hard deadline: 60 minutes after the task was first offered.** If no agent has claimed it by then, that task is cancelled automatically: the holds on its shipment's lines are consumed, the buyer is refunded in full for those lines and their delivery fee, and its sellers are released with no penalty. The other shipments of the order carry on (partial fulfilment). If it was the order's only task, the whole order is cancelled.
5. Sellers who had readied goods are not compensated at launch (the cancellation fee is 0% anyway). If a cancellation fee is ever introduced, it never applies when the cause is that no agent was found.

#### An agent drops out

- Before pickup: the task goes back to the pool, the agent's credit is taken back, and the buyer sees at most a delay.
- After pickup: the delivery is stalled. Operations raise a dispute (reason: delivery stalled) and handle the recovery off the platform. The dispute rules then apply: the money stays on hold, an admin records the outcome (delivered, or cancelled with a full refund to the buyer), and if the goods are lost, the agent is at fault and who bears the loss is decided case by case. *(Decided.)*

#### Expiry and partial fulfilment

- A line nobody claims within **30 minutes** of entering the pool (or re-entering it) expires. *(Decided.)* The buyer is told and chooses within 15 minutes between cancelling the whole order and carrying on without that line; no choice cancels the order.
- Lines are fulfilled independently: an order can complete with some lines delivered and others cancelled or expired. *(Decided.)*

#### Disputes *(decided)*

- **Who can raise one:** any party to the order. The buyer (against a seller or the agent), a seller (against the buyer or the agent), or the agent (against the buyer or a seller). **Operations can also raise a dispute on any order on their own initiative.**
- **Reasons:** goods not received; wrong, missing or damaged goods; buyer refused or could not be reached; goods not ready, or not as described, at pickup; delivery stalled after pickup (raised by operations); swap not possible (no empty handed over, or the wrong kind); other. The party gives a reason and evidence (photos, notes).
- **Scope:** specific lines and/or the delivery fee, never the whole order by default. Undisputed lines release normally when their holds end.
- **When:** from pickup until the reversal window ends (4 hours after delivery by default, or after the CoD credit lands for CoD orders *(proposed)*; at delivery if the window is waived). Raising a dispute **extends the holds on the disputed amounts** until it is resolved. A dispute raised before the window ends always holds the money, whichever happens first: the release of the money checks for disputes at that instant.
- **Process:** the other parties are told and have **24 hours** to respond. An admin decides on the evidence; if someone does not respond, the admin decides with what exists.
- **Outcomes:** a full refund, a partial refund, or release to the seller and agent, or a split. Money moves only through the holds and wallets; refunds go to the buyer's wallet.
- **Agent at fault** (goods lost or damaged in transit): who bears the loss is decided **case by case** by the admin.
- **Proof of delivery:** the agent must record it: the code the buyer gives at the door (photo optional), or, if the code is unavailable, a photo with the reason "code unavailable". This lets a "not received" claim be decided. A delivery recorded without the code is flagged and the buyer is told at once.
- Problems discovered after the window has closed (for example a faulty LPG cylinder found the next day) are not covered at launch.

## 5. Delivery pricing

**Nyange alone sets delivery rates. Sellers have no say.** The buyer pays the delivery fee on top of item prices; it
becomes the agent's reward for the delivery.

1. Once **all of the order's lines are claimed**, a **single best route** is worked out over all stops. This gives the route's total distance and travel time, plus each shipment's own standalone distance and time (as if it travelled alone).
2. **Route cost** = route kilometres × rate per km, plus (route minutes + a dwell allowance per stop) × rate per minute. The time term makes slow, congested routes cost more than short, fast ones. It is off until Nyange chooses a rate.
3. Each shipment gets a **share** of the route cost; shares add up to 100% (before rounding and capping). Default rule: **weighted by standalone distance** (a farther seller carries more). Alternatives: equal shares, or weighted by standalone cost.
4. A shipment's fee is its share, **rounded up** to the rounding step (default UGX 500), at least the minimum fee, and **never more than that shipment would pay travelling alone**. The fees charged can therefore add up to slightly more or less than the route cost; the agent's reward is the sum of the fees charged, and Nyange does not top up any difference.
5. **Batching is only worthwhile if the combined route is not longer than the separate trips it replaces** (times an allowed ratio, default 1.0). Otherwise the shipments are delivered separately, each as its own delivery task, at their standalone fees.
6. The agent's trip to the first pickup is **not** charged to the buyer.

**Worked example** (rate UGX 1,500/km, no time term): shipment A would be 8 km alone, B 9 km alone, and the combined route is 12 km. Route cost 18,000. Shares 8/17 and 9/17, so A pays 8,500 and B pays 10,000, against 12,000 and 13,500 if delivered separately.

**Fee timing:** the delivery fee is **final only after all lines are claimed**. The buyer is then notified (push and in-app) and has 15 minutes to approve or cancel (section 4.3). Nothing is charged for delivery before the buyer has seen and approved the final amount, and the buyer is never charged more than the amount they approved (if the total goes down, they pay the lower amount).

**Indicative estimate:** at ordering, before any seller has claimed, the buyer sees only an estimate from straight-line distance multiplied by a road factor (default 1.4, to be calibrated against real routes). It is a guide, not a promise.

**Audit:** for every delivery, Nyange keeps the route, the rates and shares used, and the resulting fees, so any fee can be explained in a dispute.

**Routing source:** the route and times come from an external mapping source (initially Google Maps Platform). Its fit for Uganda is an open question (section 9).

## 6. Wallets, payments, holds and cash on delivery

### 6.1 Wallets *(decided)*

- Every user has a Nyange wallet (every user is a buyer by default; seller and agent are added roles). Nyange also has its own company wallet, which receives its commission and cuts and the CoD cash handed over by agents.
- **All digital money lands in a wallet first.** It leaves only by withdrawal from the wallet through the mobile money rail.
- **When a buyer pays an order by mobile money, each seller's share lands directly in that seller's wallet.** The buyer does not load their own wallet first. The delivery fee lands with Nyange and passes to the delivery agent's wallet when they claim the task.
- **Everyone can top up their wallet from mobile money**, whatever their role (buyer, seller or agent). **Top-ups carry no hold**: topped-up money is available immediately, including for paying orders.
- **One wallet per user**, whatever roles they hold.
- **Actors never pay each other directly through mobile money.** Every payment between actors moves through wallets. Mobile money is used only to bring a payment in (landing in a wallet) or take money out (withdrawal).
- Mobile money providers are only the rail. Nyange reconciles against their statements.

### 6.2 How payments flow

A prepaid buyer pays the order total (item prices plus the final delivery fee) by mobile money or from their own wallet. The payment is **split on arrival**: each seller receives their items' price less commission directly in their wallet, and Nyange receives the delivery fee and its commission. When an agent claims the delivery task, Nyange passes the delivery fee less its cut on to the agent's wallet. Every credit to a seller or agent lands **on hold** (section 6.3), so none of it can be withdrawn before the order is delivered and the reversal window has passed. This is what protects the buyer: there is no separate escrow account, the holds do that job (and, until an agent claims, Nyange itself is holding the delivery fee).

| Event | Money moves |
|---|---|
| Anyone tops up their wallet by mobile money | Provider → that user's wallet |
| Buyer pays by mobile money | Provider → sellers' wallets (price less commission, **on hold**) + Nyange (delivery fee and commission) |
| Buyer pays from their wallet | Buyer's wallet → the same split |
| Agent claims the delivery task (prepaid orders) | Nyange → agent's wallet (fee less cut, **on hold**) |
| Agent drops the task before delivery | The agent's credit is taken back (hold consumed) and returns to Nyange; it passes to the next agent who claims |
| Delivery completed | The holds end after the reversal window (default 4 hours after delivery); the money becomes available |
| Dispute raised | The holds on the disputed amounts are extended until the admin decides |
| Dispute decided | Refund: held money consumed and returned to the buyer's wallet; otherwise released to the seller and agent; or a split |
| Buyer cancels after payment | Sellers' holds are consumed and the money is taken back; the delivery fee is returned from the agent's hold, or from Nyange if no agent has claimed; everything returns to the buyer's wallet, less any cancellation fee (0% at launch), which stays with the sellers of the ready lines |
| Seller drops a line before delivery | The seller's credit for that line is taken back (hold consumed) and held by Nyange until a replacement seller claims it (credited on hold) or the buyer is refunded |
| Payment that cannot be applied (order cancelled or not payable, or amount below the approved total) | The whole amount lands in the payer's wallet; none of it reaches sellers or the agent |
| Payment above the approved total | The approved total is applied as normal; the excess lands in the payer's wallet |
| Agent collects CoD cash | Agent's cash-in-hand ↑ (the agent owes Nyange the cash). Nothing is credited to sellers or the agent yet |
| Agent hands over CoD cash | Agent's wallet float → Nyange's company wallet, or the agent's mobile money payment → Nyange's company wallet; the agent's cash-in-hand ↓. Then the sellers' wallets (price less commission, **on hold**) and the agent's wallet (fee less cut, **on hold**) are credited |
| Withdrawal | Available wallet money → the actor's own mobile money number |

**Payments that cannot be applied.** Mobile money confirmations arrive later and land directly in sellers' wallets, so the rule is strict *(decided)*:
- A payment is applied to an order only if the order is **payable** (all lines claimed, the fee approved by the buyer, and inside the payment window) and the amount is **at least the approved total**.
- If the amount is **more** than the approved total, the approved total is applied and the **excess lands in the payer's wallet**.
- If the order is **not payable** (cancelled; paused because a line is unclaimed; the fee voided or the total awaiting re-approval; the payment window passed), or the amount is **below** the approved total, **none of it is applied**: the whole amount lands in the payer's wallet, the payer is told, and the order is unchanged. The payer can then pay the order from their wallet, topping up the difference if needed.
- If the paying mobile money number belongs to no user, operations return the money (deferred).

### 6.3 Holds *(decided)*

There are two kinds of hold. Both are real, recorded objects, never flags on a wallet or a transaction.

**Transaction hold (the reversal hold).** It protects money that has just been paid, while the payment can still be reversed. The recipient cannot withdraw or use it meanwhile.

- **It applies to every payment transaction, with the same rules for all of them:** the sellers' shares, the delivery agent's fee, and any payment type added later. The one exemption is a mobile money top-up, which carries no hold (decision 18).
- **How long:** from the moment the money lands until the order's delivery is complete (the *order hold*, which always applies and cannot be waived), and then for a further **reversal window of 4 hours by default**. The reversal window is tunable per transaction type and can be waived; waiving it releases the money at delivery.
- **What it records:** the wallet, the amount, the reason, the transaction it protects, when it starts, when it ends, its status, and how it ended.
- **Lifecycle:** *active*, then ends in one of three ways: *released* when its time is up (the money becomes available), *extended* (for example while a dispute is open, until it is resolved), or *consumed* (the held money is used to cover a reversal such as a refund).
- If the order is cancelled before delivery, the holds are consumed to return the money to the buyer.

**Transfer hold (the accounting hold).** It is short-lived. While a transfer between accounts or wallets is being effected, the amount is reserved on the paying account so it cannot be spent twice or overdrawn in the meantime. The system creates it and releases it as soon as the transfer completes or fails. Transfer holds do not replace transaction holds, and transaction holds do not replace transfer holds.

**Effect on a balance:** available balance = balance minus all active holds (of both kinds), and it never goes below zero. A wallet can have many holds at once, each independent, with its history kept.

### 6.4 Ledger rules

- All amounts are whole Ugandan shillings.
- Every movement of money is recorded as a balanced entry (what leaves one place arrives in another).
- History is never changed or removed; corrections are new entries.
- Balances are always the result of the history, never a number edited by hand.
- A repeated payment instruction (a retried request, a duplicate notification from a provider) takes effect once.

### 6.5 Cash on delivery controls

An agent holding collected cash is exposed to loss or theft. Every control below is a tunable rule, can be set nationally,
per area, or per agent, and **can be waived entirely**. At launch they are all waived to make agent onboarding easy, **except the handover deadline**, which is active.

| Control | Meaning |
|---|---|
| CoD enabled | CoD can be turned on or off |
| Cash-in-hand limit | The most cash an agent may hold or have promised to collect at once |
| Handover deadline | How long collected cash may be held before it must be handed over (sellers and the agent are not credited until then). **Active at launch: 4 hours after delivery.** *(Proposed consequence: when it passes, operations are alerted and the agent is offered no new CoD tasks until the cash is handed over.)* |
| Security deposit | A deposit an agent must put up before taking CoD tasks |
| Verification required | Only verified agents may take CoD tasks |

*Float* means money an agent keeps in their own wallet in advance, so they can hand over CoD cash immediately.

**Cash-in-hand limit rule:** cash already held + cash promised on tasks the agent has claimed but not completed + the cash on the
task being claimed must not exceed the limit. A claim that lapses releases its promised cash. When a CoD task is completed,
its cash moves from "promised" to "held" exactly once, and then to "handed over".

## 7. Invariants

Rules that must always hold, whatever technology implements them.

**Claims**
1. An order line has at most one seller holding a claim at any time. A task has at most one agent.
2. Two actors claiming at the same moment each get a definite answer (won, or already taken). Neither fails, hangs or sees an error. This includes two sellers claiming different lines of the same order.
3. Only an actor in range can claim; the price locked on a line is never above the buyer's approved ceiling.
4. A claim is firm once made. It ends only when the claimant withdraws or drops out under the rules in section 4.6, or the order is cancelled.
5. Lines of a cancelled order cannot be claimed. If a cancellation and a claim happen at the same moment, one clearly happens first and the outcome is consistent.
6. Only active sellers and agents can claim, and only if their account is also active. Suspending an account stops its claims.
7. A seller can only fulfil from a location they own; an offer is always tied to a location of the offering seller.
8. While a seller holds the exclusive window on an order's lines, others cannot claim them. When it ends, they open to everyone.

**Rules by area**
9. For anything located inside an area, rules set for that area override national ones. Anything outside every area uses the national rules. This applies to the seller exclusive window, cash controls and radius schedules alike.

**Money**
10. Every money movement balances; nothing is created or lost.
11. Money history is permanent: it cannot be edited, removed or wiped by anyone, including administrators.
12. A balance can always be re-derived from the history.
13. The same payment instruction applied twice has the same effect as once.
14. An agent's cash held plus promised never exceeds their cash-in-hand limit, where a limit is set.
15. CoD cash is counted exactly once at every moment: as promised, then as held, then as handed over. Sellers and the delivery agent are credited for a CoD order only after the full CoD amount has been handed over to Nyange's company wallet. *(Proposed: cash not handed over within 4 hours of delivery alerts operations and the agent is offered no new CoD tasks until it is.)*

**Delivery fees**
16. Only Nyange sets delivery rates; sellers cannot.
17. Before rounding and capping, the shares of a route add up to 100% of the route cost. The fees actually charged can differ slightly (rounding adds up to one step per shipment; the cap can lower the total). The agent's reward is the sum of the fees charged, and Nyange does not top up any difference.
18. A shipment never pays more than it would travelling alone (when that cap is on), never less than the minimum fee, and is always rounded **up** to the step, never down.
19. A delivery fee is fixed only after all of the order's lines are claimed. The buyer is never charged it without having been shown the final amount and given 15 minutes to approve or cancel, and is never charged more than the amount they approved. If the total goes down, they pay the lower amount.
20. The buyer is notified of the final fee through both a push and a durable in-app notification.

**Order sequence**
21. No delivery task is offered to agents before its goods are ready. Goods are readied only after the buyer has approved the final fee and, for prepaid orders, payment is confirmed.
22. For prepaid orders, sellers ready goods for pickup only after payment is confirmed. For CoD orders, only after the buyer has approved. No seller prepares goods before the buyer has approved.
23. An order that is not approved within 15 minutes, or (prepaid) not paid within 60 minutes of approval, is cancelled and every seller is released. So is an order that is not fully committed (paid, or for CoD approved with every line claimed) within 3 hours of being placed, however many times its clocks have restarted.
24. A cancelled order is never revived. Money already paid for it is returned to the buyer's wallet, and a payment that arrives after the order was cancelled lands in the payer's wallet without ever reaching sellers or the agent.

**Wallets and holds**
25. Every user has exactly one wallet, shared across all their roles. Every user is a buyer by default.
26. Digital money always lands in a wallet first. A payment for an order lands directly in the wallets of the sellers it is owed to; for a prepaid order the delivery fee lands with Nyange and passes to the delivery agent's wallet when the agent claims the task (for a CoD order, sellers and the agent are credited after the handover). Money leaves only by withdrawal from a wallet through mobile money. Anyone may top up their wallet from mobile money, and a top-up is available immediately (no hold).
27. Actors never pay each other directly through mobile money. Money between actors moves only through wallets.
28. Every hold, of either kind, is a recorded object (wallet, amount, reason, the transaction it concerns, start, end, status, how it ended), never a flag.
29. Held money cannot be withdrawn or paid out. Available balance equals balance minus all active holds and never goes below zero. A transfer in progress reserves its amount on the paying account (a transfer hold), so a wallet can never be overdrawn or double-spent.
30. A transaction hold ends automatically at its end time unless it is extended or consumed; a transfer hold ends when its transfer completes or fails. Every change to a hold is recorded.
31. Withdrawals go only to the actor's own verified mobile money number.
32. Every payment transaction for an order, including the delivery agent's fee, carries a transaction hold from the moment the money lands until the order is delivered and the reversal window has passed (for CoD orders, where the money lands after delivery, the reversal window runs from the moment it lands). The part before delivery cannot be waived. Until the hold ends, the money can be taken back for a cancellation and cannot be withdrawn.
33. For prepaid orders, the delivery fee is held by Nyange from payment until an agent claims the task. If the order is cancelled before then, it is returned to the buyer.
34. A user can never fulfil their own order: they cannot claim any line of an order they placed, and cannot deliver it.

**Cancellation**
35. After payment the buyer can cancel only the whole order, and only before any shipment is picked up. Before any line is ready it is free; once goods are ready a configurable fee (0% at launch) compensates the sellers concerned.
36. When an order is cancelled after payment, the money comes back to the buyer's wallet from the holds and from Nyange's holding, less only any cancellation fee. Nobody can withdraw it first.
37. A line dropped by a seller returns to the pool. The dropped seller keeps nothing for it, and the money for that line stays with Nyange until a replacement claims it or the buyer is refunded.
38. A payment is applied to an order only if the order is payable and the amount is at least the approved total. Any amount above the total goes to the payer's wallet, and a payment that cannot be applied lands entirely in the payer's wallet. While any line is unclaimed the order is not payable; when it is whole again the buyer gets a fresh 60 minutes to pay.
39. A seller who withdraws a line cannot claim that same line of that order again.
40. If a seller withdraws while the buyer is deciding on the final fee, that fee is void: the buyer is told, and gets a fresh notification and a fresh 15 minutes once a new final fee is fixed.
41. An unclaimed line expires 30 minutes after it enters (or re-enters) the pool.

**Delivery proof and disputes**
42. A delivery is recorded only with proof: the code the buyer gives at the door (photo optional), or, if the code is unavailable, a photo with the reason "code unavailable". A delivery recorded without the code is flagged and the buyer is told at once.
43. Only a party to an order, or operations, can raise a dispute, about specific lines and/or the delivery fee, from pickup until the reversal window ends.
44. A dispute keeps the disputed money on hold until an admin decides; undisputed money is released normally. A dispute raised before the window ends always takes effect, even if the release is due at that same moment.
45. A dispute outcome moves money only through the holds and wallets, and refunds go to the buyer's wallet.

**Unclaimed delivery**
46. While any delivery task of an order is unclaimed and nothing has been picked up, the buyer can cancel the whole order with a full refund and no cancellation fee.
47. A delivery task still unclaimed 60 minutes after it was first offered is cancelled automatically: its shipment's lines and delivery fee are refunded in full to the buyer and its sellers are released without penalty. The order's other shipments carry on.
48. Ten minutes after a delivery task has reached its widest radius unclaimed, operations are alerted and the buyer is told.

**Returnable containers**
49. An order line for a returnable-container item always has a container mode (swap or new), chosen by the buyer at ordering. The price locked at claim is the seller's price for that mode.
50. A swap line is delivered only with the buyer's empty collected and recorded (a photo) alongside the proof of delivery.

## 8. Tunable rules and parameters

Each can be set nationally, overridden per area (and per agent for cash controls), and waived (turned off) where it makes sense.

| Parameter | Launch default |
|---|---|
| Initial search radius (orders, tasks) | 3 km |
| Radius widening schedule | 7 km after 2 min; 15 km after 5 min |
| Seller exclusive window (affinity) | 90 seconds |
| Buyer decision window on the final fee | 15 minutes (no decision cancels) |
| Prepaid payment window after approval | 60 minutes (no confirmed payment cancels; restarts when an order becomes whole again after a withdrawal, but never beyond the overall cap below) |
| Overall time for an order to become fully committed | 3 hours from placing (tunable per area) |
| Time an unclaimed line waits before it expires | 30 minutes |
| Dispute window | until the reversal window ends (4 hours after delivery) |
| Response period for the other parties in a dispute | 24 hours |
| Proof of delivery | the buyer's code (photo optional); if the code is unavailable, a photo and the reason "code unavailable" |
| Escalate an unclaimed delivery task to operations, after the widest radius is reached | 10 minutes |
| Hard deadline for an agent to claim a delivery task | 60 minutes after it was first offered |
| Reversal window after delivery, on every payment transaction | 4 hours (per transaction type, tunable and waivable). The hold before delivery is not waivable |
| Cancellation fee after goods are ready | 0% (tunable, waivable) |
| How long a dropped line waits for a replacement seller | 30 minutes |
| Penalty for a seller or agent who drops out after approval | waived at launch (tunable) |
| Buyer re-approval window when a change raises the total | 15 minutes |
| Buyer's choice window when no replacement is found | 15 minutes (no choice cancels) |
| Final-fee notification channels | push and durable in-app |
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
| Agent cash-in-hand limit, security deposit | waived |
| Handover deadline for CoD cash | 4 hours after delivery (active at launch) |
| Verification required for CoD | no |
| Coverage gating (minimum sellers / agents) | off (1 / 1) |

## 9. Decisions and open questions

**Decided**
1. Per-line claiming, preferring the same seller where possible (seller affinity). Agent affinity is not used at launch, because one route is planned for the whole order.
2. The buyer pays delivery on top of item price. Nyange, not sellers, sets the rates; the fee comes from the optimised route (section 5).
3. The wallet is built by Nyange. All required licences are assumed in place.
4. Technology stack: deferred. This document does not depend on it.
5. Nationwide, with radius-capped pools and areas opening on supply.
6. Range pricing at checkout with a buyer-approved ceiling; the claim locks the seller's real price.
7. All CoD controls are tunable and waivable, and ship waived, except the handover deadline, which is active at launch at 4 hours after delivery.
8. Batching: one best route, shares weighted by distance, cost by distance (plus an optional time term), agent's approach to the first pickup not charged.
9. The delivery fee is final only after all of the order's lines are claimed. The buyer is notified (push and in-app) and has 15 minutes to approve or cancel the order.
10. After approval a prepaid buyer pays the full total. Sellers ready the goods for pickup only after payment is confirmed (prepaid) or straight after approval (CoD).
11. Silence cancels: no decision within 15 minutes cancels the order, and a prepaid order with no confirmed payment within 60 minutes of approval is cancelled.
12. A payment that cannot be applied (order cancelled or not payable, or amount below the approved total) lands in the payer's wallet, and any excess over the approved total goes to the payer's wallet; the order is never revived. No payment cut-off or grace is used at launch.
13. Every buyer, seller and agent has a wallet. Actors never pay each other directly through mobile money; they withdraw to their own mobile money number.
14. Holds are real recorded objects. Transaction holds apply to every payment transaction (sellers' shares, the delivery agent's fee, any other): held from payment until delivery, then a 4-hour reversal window (tunable and waivable; the part before delivery is not waivable). Short-lived transfer holds against overdraws are separate and unchanged.
15. When a buyer pays an order (mobile money or wallet), each seller's share lands directly in the seller's wallet, on hold until delivery plus the reversal window. The delivery fee lands with Nyange and passes to the delivery agent's wallet, on hold, when the agent claims the task.
16. Everyone can top up their wallet from mobile money, whatever their role.
17. Every user is a buyer by default; seller and agent are roles added to the account.
18. Mobile money top-ups carry no hold.
19. One wallet per user, shared across all their roles.
20. A user cannot fulfil their own order (claim its lines or deliver it).
21. After payment the buyer can cancel only the whole order: free before any line is ready, with a cancellation fee once goods are ready (fee 0% at launch), and not at all once any shipment is picked up (then it is a dispute). An order's stage is that of its most advanced shipment.
22. A seller who drops out after approval: the line goes back to the pool and waits up to 30 minutes for a replacement.
23. Penalties for sellers and agents who drop out are waived at launch, and tunable.
24. Anything that would raise what the buyer pays after they approved needs their re-approval within 15 minutes, otherwise the order is cancelled with a full refund.
25. If no replacement seller claims a dropped line within 30 minutes, the buyer chooses within 15 minutes between cancelling the whole order (full refund) and carrying on without that line (refund for it); no choice cancels the order.
26. A seller may withdraw a claim before payment: free until the fee is final; a withdrawal during the buyer's decision voids the fee and restarts their 15 minutes; after approval it is handled as a drop-out, with payment paused and a fresh 60 minutes once the order is whole again. A seller cannot re-claim a line they withdrew.
27. An unclaimed line expires after 30 minutes in the pool.
28. Disputes: any party to an order can raise one, about specific lines and/or the delivery fee, from pickup to the end of the reversal window; the holds on the disputed amounts are extended; the other parties have 24 hours to respond; an admin decides.
29. Delivery requires proof: the buyer's code (photo optional), or, if the code is unavailable, a photo with a reason; a delivery without the code is flagged and the buyer is told at once.
30. When an agent is at fault in a dispute, who bears the loss is decided case by case by the admin.
31. An unclaimed delivery task: operations and the buyer are alerted 10 minutes after the widest radius is reached; the buyer can wait or cancel free (no fee) while no agent has claimed; a hard deadline of 60 minutes cancels that task's shipment with a full refund (the whole order if it was the only task). These rules apply per delivery task.
32. Self-collection by the buyer is not offered.
33. Much of operations is handled off the platform at launch (section 1a). A delivery that stalls after pickup is a dispute raised by operations; recovery is handled off the platform and the dispute rules apply.
34. If some lines expire or are cancelled, the final fee is fixed over the lines that remain, and any increase needs the buyer's re-approval within 15 minutes (decision 25 and invariant 24).
35. Withdrawals go only to the actor's own verified mobile money number.
36. Until the buyer approves the final delivery fee, they can cancel the whole order at any time, free; any sellers who have claimed are released at no cost.
37. CoD: Nyange credits sellers and the agent only after the collected cash has been handed over to Nyange's company wallet, either from the agent's float or through mobile money (section 4.5).
38. Returnable containers (LPG cylinders, 20L water bottles) are modelled on the platform: each line is a swap or a new container, offers price each mode, and the agent collects and records the empty at delivery.
39. Stock is a simple in-stock status: no quantity counting or reservation at launch. A line is claimed whole by one seller, and a seller who cannot supply withdraws or drops out under the existing rules.
40. An order that is not fully committed within 3 hours of being placed is cancelled, however many times its clocks have restarted.
41. A delivery task is offered to agents only once its goods are ready, so agents do not wait at sellers' premises.

**Deferred** (handled by operations off the platform, or later; not designed here)
- Compensating an agent already travelling when the buyer cancels.
- Appeals against an admin's dispute decision (the platform treats the decision as final), and recourse for problems found after the dispute window closes.
- Who bears provider charges on payments, refunds and withdrawals.
- Returning money paid from a mobile money number that belongs to no user.
- Unclaimed tasks of other types (market price capture, cash deposit and withdrawal, payment collection).
- Consequences beyond the alert for a late CoD handover, reporting of overdue cash, and the security deposit (waived at launch).
- How cash-deposit and cash-withdrawal agents move wallets. The platform's rule is that CoD cash is handed over from the agent's float or by mobile money to Nyange's company wallet (section 4.5).
- The base of the cancellation fee and how to collect it from a CoD buyer (the fee is 0% at launch).
- Service flows: quotes, boda dispatch, print jobs with file proofs.
- Vehicle class and load limits per task.
- Container deposits and ownership, the agent returning collected empties to the seller, and safety rules for carrying LPG.
- Multi-buyer delivery rounds, which need ordering rules such as "pickup before drop".
- Refusing orders that nobody can fulfil: a placement-time check that sellers and agents are within reach (or coverage gating on by default). Until then such orders expire under the existing rules.

**Open**
- Real values for the per-km and per-minute rates (placeholders for now). Nyange must supply them before launch.

**To validate before building**
- Whether the mapping source works well enough for Uganda: coverage outside Kampala, boda (two-wheeler) routing, cost, and rules on storing results.
