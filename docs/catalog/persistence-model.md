# Nyange catalog persistence model

Status: **draft for review.** Designed from the business specification ([`../architecture.md`](../architecture.md)),
not from any earlier catalog model. Target store: PostgreSQL, using `jsonb` for document-shaped data and typed
columns for anything the database filters, compares or arbitrates on.

## 1. What the business specification forces

| # | Fact in the spec | Consequence for persistence |
|---|---|---|
| 1 | Nyange curates the catalog; sellers only offer on it. | Catalog writes are rare and admin-only. Offer writes are frequent and seller-owned. |
| 2 | An offer is a standing price and in-stock flag, tied to one seller location. | Offers are rows keyed by location and catalog entry. |
| 3 | The buyer sees the lowest and highest price across eligible offers in range. | Price and stock must be typed columns so the range is a plain aggregate. |
| 4 | A claim succeeds only if the offer price is at or below the ceiling; it locks that price; at most one claim wins. | The order line is the arbiter of a claim. |
| 5 | Order lines carry a locked price and must stay meaningful through disputes and refunds. | A line carries a snapshot of what was ordered. |
| 6 | Matching is exact: a "matching standing offer" for the line's item. | Offers reference exactly one variant. No substitution. |
| 7 | Returnable containers: the variant defines the container (brand and size); modes are swap and new; stock and eligibility are per mode. | Container identity comes from variant attributes; mode availability is derived from component stock. |
| 8 | Stock is a boolean. No counts, no reservation. | There is no inventory ledger. |
| 9 | Eligibility: seller location within the smaller of the seller's service radius and the line's search radius, measured from the buyer's drop point. Area rules override national defaults. | Locations carry a geography point, a radius and an area. |

## 2. Decisions

| # | Decision |
|---|---|
| 1 | The catalog has two levels, **product** and **variant**. Offers and order lines reference a variant. Product and variant documents merge as a pure union, with no overrides. |
| 2 | **Returnable** is a product-level flag. The container's identity is derived from the variant's attribute values. |
| 3 | The **sale unit, step and minimum** are on the product. Quantity and price are integers in that unit. |
| 4 | An order line carries a **snapshot** of the resolved item, taken at placement. The catalog is not versioned. |
| 5 | An **offer row** is `(location, variant, component)` with typed price and stock columns. |
| 6 | The price of a mode is **derived** from its components. Every returnable offer must state a container price. |
| 7 | The **service radius** is on the location, bounded by a platform maximum per area. |
| 8 | The database enforces **keys only**. The contents of jsonb documents are validated by the application. |
| 9 | Search is **PostgreSQL full text plus trigram** on the variant. Variants with no nearby offers are **hidden**. |
| 10 | Locations are **PostGIS points** with a two-step radius filter. Distance is **straight-line**. |
| 11 | Areas are **polygons loaded offline** with stable ids, resolved once and stored. They **do not overlap**. |
| 12 | The **order line arbitrates** a claim. The claim locks the seller's **current** price. |
| 13 | Retirement is a **soft status**. Lines already placed continue. |
| 14 | Names and labels are **language maps**; the variant's display name is composed at write time. **English only at launch.** |
| 15 | All ids are **surrogate and immutable**. A generated attribute key keeps variants unique. |
| 16 | Offers carry **no seller-stated attributes**. |
| 17 | A **location status** (open or paused) and a **seller or account status** gate eligibility. |

## 3. Entities

Types are indicative. `jsonb` is used where the data is read as a whole document and changes rarely. Typed columns
are used for everything the database filters, joins or arbitrates on.

### 3.1 area

```sql
area (
  id        uuid primary key,
  slug      text not null unique,
  name      jsonb not null,                       -- language map
  boundary  geography(MultiPolygon) not null      -- GiST index
)
```

Loaded offline. Areas must not overlap; a point belongs to at most one area, and a point in none uses the national
rules. Area-scoped parameters (including the maximum service radius) are held with the other scoped parameters
of the specification, keyed by `area.id`.

### 3.2 product

```sql
product (
  id              uuid primary key,
  slug            text not null unique,
  name            jsonb not null,                 -- language map
  status          text not null,                  -- active | retired
  schema_version  int  not null,
  shared          jsonb not null
)
```

`shared` holds what every variant of the product agrees on:

```json
{
  "aliases": { "en": ["corn"] },
  "specAttrs": ["grade", "state"],
  "attrLabels": {
    "grade": { "en": "Grade", "values": { "A": { "en": "Grade A" }, "B": { "en": "Grade B" } } },
    "state": { "en": "State", "values": { "dried": { "en": "dried" }, "fresh": { "en": "fresh" } } }
  },
  "sale": { "unit": "kg", "step": 10, "minimum": 10 }
}
```

For a returnable product the same document also holds:

```json
{
  "returnable": {
    "containerKey": ["brand", "size"],
    "components": ["refill", "container"],
    "modes": {
      "swap": { "charges": ["refill"], "handBack": "container" },
      "new":  { "charges": ["refill", "container"] }
    }
  }
}
```

A non-returnable product has the single component `goods`.

### 3.3 variant

```sql
variant (
  id          uuid primary key,
  product_id  uuid not null references product(id),
  slug        text not null unique,
  status      text not null,                      -- active | retired
  attrs       jsonb not null,                     -- values for the product's specAttrs
  attrs_key   text not null,                      -- generated, canonical form of attrs
  delta       jsonb not null default '{}',        -- variant-only keys, e.g. aliases
  name        jsonb not null,                     -- composed at write time, language map
  search_text tsvector not null,                  -- full text, with a trigram index
  unique (product_id, attrs_key)
)
```

`attrs_key` is generated from `attrs` and makes two variants with the same attribute combination impossible,
whichever service writes them.

The effective definition of a variant is `product.shared || variant.delta`. The key sets are disjoint by
construction, so there is no precedence rule.

### 3.4 location

```sql
location (
  id               uuid primary key,
  seller_id        uuid not null,                  -- the account that owns it
  area_id          uuid references area(id),       -- resolved when created or moved; null = national rules
  geog             geography(Point) not null,      -- GiST index
  service_radius_m int  not null,                  -- as requested by the seller
  status           text not null                   -- open | paused
)
```

The stored radius is what the seller asked for. The radius that applies is

`least(service_radius_m, area maximum, the line's current search radius)`

and the area maximum is applied when eligibility is evaluated, never written back.

### 3.5 offer

```sql
offer (
  id           uuid primary key,
  location_id  uuid not null references location(id),
  variant_id   uuid not null references variant(id),
  component    text not null,                      -- goods | refill | container
  price        bigint not null,                    -- whole UGX per unit of the product's sale unit
  in_stock     boolean not null,
  unique (location_id, variant_id, component)
)
```

For a returnable variant, an offer has a `refill` row and a `container` row. The price of a mode is the sum of the
prices of its charged components:

| Mode | Charges | Price in the example below |
|---|---|---|
| swap | refill | 115 000 |
| new | refill + container | 265 000 |

A mode is available at a location when every component it charges is in stock. A `new` price cannot be set
independently of its components.

### 3.6 order_line (catalog-relevant columns)

```sql
order_line (
  id               uuid primary key,
  order_id         uuid not null,
  variant_id       uuid not null references variant(id),
  area_id          uuid references area(id),       -- resolved once from the drop point
  quantity         bigint not null,                -- integer, in the product's sale unit
  mode             text,                           -- swap | new for returnables, null otherwise
  ceiling          bigint not null,                -- approved price per unit for the chosen mode
  snapshot         jsonb not null,                 -- resolved item at placement
  locked           jsonb,                          -- set at claim
  exclusive_to     uuid,                           -- seller affinity window
  exclusive_until  timestamptz,
  status           text not null
)
```

The other columns of the order domain (payment, shares, shipments, and so on) are outside this document.

## 4. Documents

### 4.1 Line snapshot, taken at placement

```json
{
  "variantId": "7c1f…",
  "slug": "lpg-total-13kg",
  "name": { "en": "LPG, Total, 13 kg cylinder" },
  "attrs": { "brand": "Total", "size": "13 kg" },
  "sale": { "unit": "piece", "step": 1, "minimum": 1 },
  "mode": "swap",
  "container": { "brand": "Total", "size": "13 kg" }
}
```

### 4.2 Locked price, written at claim

```json
{
  "offerLocationId": "a41b…",
  "mode": "swap",
  "components": { "refill": 115000, "container": 150000 },
  "charged": ["refill"]
}
```

The buyer pays the charged components. The uncharged container price is kept as the **reference value** of the
container the seller expects back, so that a dispute about an empty has a number to refer to.

## 5. Worked examples (illustrative prices)

### 5.1 Maize, Grade A, dried

Product `maize`, variant with `attrs = {"grade":"A","state":"dried"}`.

| location | component | price (UGX/kg) | in_stock |
|---|---|---|---|
| Seller A, Nakasero | goods | 1 350 | true |
| Seller B, Owino | goods | 1 280 | true |

A 200 kg line shows the buyer a range of 256 000 to 270 000 (200 × 1 280 and 200 × 1 350).

### 5.2 LPG, Total, 13 kg

| location | component | price (UGX) | in_stock |
|---|---|---|---|
| Seller A, Kampala depot | refill | 115 000 | true |
| Seller A, Kampala depot | container | 150 000 | true |
| Seller C, Kawempe | refill | 118 000 | true |
| Seller C, Kawempe | container | 150 000 | false |

- **swap:** Seller A at 115 000 and Seller C at 118 000, a range of 115 000 to 118 000.
- **new:** only Seller A is available (Seller C's container is out of stock), at 265 000.

## 6. Queries and arbitration

### 6.1 Visibility of a variant to a buyer

A variant is shown when an eligible offer exists:

- the variant and its product are active
- the seller account is active, the location is open and the offer is in stock (for a returnable, at least one mode
  is fully in stock)
- the location is within its effective service radius of the buyer's drop point, using the area maximum as the
  index-friendly first bound, then the exact radius

Variants with no such offer are hidden.

### 6.2 Price range for a line

Over the same eligible offers, for the chosen mode: the minimum and maximum of the mode price per location. For
`goods` that is a single component; for a returnable mode it is the sum of its charged components.

### 6.3 Claim

In one transaction:

1. Read the claiming seller's offer rows for the line's variant under a share lock, so a price edit waits briefly
   rather than racing the claim.
2. Compute the mode price from the charged components and check it is at or below the line's `ceiling`.
3. Conditionally update the line from `open` to `claimed`. If no row changes, the claimant is told "already taken".
4. Write `locked` onto the line, and write `exclusive_to` and `exclusive_until` on the order's other open lines
   if this is the first claim.

The price locked is the seller's current price at that moment.

## 7. Invariants

### Enforced by the database

1. Every id is unique and immutable.
2. Offers reference an existing location and variant; variants reference an existing product; lines reference an
   existing variant.
3. A variant's attribute combination is unique within its product.
4. A location has at most one offer row per variant and component.
5. Money and quantities are integers.

### Enforced by the application

6. A variant's attribute keys are exactly its product's `specAttrs`, with values from the product's labels.
7. Offers are created only on active variants and only for components the product declares.
8. A returnable offer always has a `container` row, even for a seller that never sells containers.
9. A line's quantity respects the product's `minimum` and `step`.
10. A line for a returnable variant always has a mode, and its `ceiling` is compared with that mode's price.
11. `name` and `search_text` are regenerated whenever a product name, an alias, a label or an attribute changes.
12. Area polygons do not overlap.
13. The effective service radius is applied when eligibility is evaluated and never written back.

## 8. Lifecycle

- **Retirement** sets `status = retired` on a variant or product. Search and new orders exclude it; its offers fail
  the eligibility filter. Lines already placed continue to completion on their snapshot. Retiring a product retires
  its variants. Reactivation is a status change.
- **Pausing** a location, or suspending a seller account, removes it from eligibility for new lines. Lines it has
  already claimed continue under the withdrawal and dispute rules.
- **Areas** are reference data. Redrawing a boundary does not change the area stored on existing lines; a backfill
  recomputes the stored area of seller locations when that is wanted.

## 9. Proposed changes to the business specification

None of these is applied yet. Each would be reviewed separately.

1. Offers price **components**, and the price of a mode is derived from them, instead of the offer stating a price
   per mode. *(Applied to the specification.)*
2. Every returnable offer **must state a container price**, which is locked on the line as a reference value.
   *(Applied to the specification.)*
3. A **platform maximum service radius per area** bounds each seller location's radius. *(Applied to the
   specification; the default value is still open.)*
4. A **location status** and a **seller-level suspension** are part of the eligibility rule.
5. Quantity is an **integer in the product's sale unit**, with a product-level step and minimum.

## 10. Deferred and open

Deferred:

- Persistence for market price capture (the spec only lists it as a task type).
- Seller-stated attributes on offers (no rule in the spec uses them).
- Cross-item bundles, which could later be ordinary variants listing their parts.
- Nested areas, which would need a parent link and a "most specific wins" rule.
- Catalog edit history, which could be an append-only change log off the hot path.
- Languages beyond English.
- Fulfilment attributes such as weight, heavy, hazardous and perishable. The specification defers vehicle class and
  load limits, and no rule reads these today.
- Services (quotes, real-time dispatch, file proofs need their own flows).

Open:

- The real `step` and `minimum` values per product, to be confirmed with traders.
- The per-area maximum service radius values.
- The outcome rules for "empty not returned" and "swap not possible" disputes. The container reference value is
  stored, but the compensation rule is not defined.
- Whether browsing should ever show variants with no nearby offers as "not available in your area" instead of
  hiding them (currently hidden).
