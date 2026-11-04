# Catalog Domain Model

## Contents

1. Purpose
2. Core principles
3. Concept map
4. Type system
5. Product
6. Offering & Price
7. Composition
8. Invariants
9. Derived behaviors
10. JSON reference shapes
11. Worked examples
12. Scenarios
13. Extension guide
14. Out of scope
15. Glossary

---

## 1. Purpose

Define a catalog model that accommodates structurally different product types — returnable containers, graded cereals, bundles, simple goods — and extends to new types **by authoring declarations, not by changing schema or writing type-specific code paths**.

The model separates four concerns:

- **Identity** — what the product *is* (Product)
- **Variation** — the declared space it varies in (Dimension / DimensionValue)
- **Sellability** — the points that can be bought (Offering + Price)
- **Composition** — the structure inside (Composition + Component)

---

## 2. Core principles

1. **Type = declared schema.** A ProductType declares capabilities, dimensions, product fields, composition rules, and profiles. Products conform to it.
2. **Variation = a declared space.** Dimensions carry domains; values carry labels, media, and sort order. Facets, sort, and search derive from these declarations.
3. **Sellability = a point in that space.** An Offering selects a DimensionValue per axis. Price lives on the Offering and is structured, not scalar.
4. **Composition = roles + pricing modes.** Components declare *what they are* (role) and *how they are charged* (pricingMode). Container+contents, bundles, and kits all use the same structure.

Consequence: display, search, facet, sort, and cart-line behavior are **type-agnostic** — they read declarations.

---

## 3. Concept map

```
ProductType ──conforms──▶ Product ──offered via──▶ Offering
   │ capabilities            │ dimensionDomains       │ selection (Dimension→Value)
   │ dimensions              │ attributes             │ price (components)
   │ compositionRules        │ composition            │ availability
   │ profiles                │ media · categories     │ compositionOverride?
   └──────────────────────────────────────────────────┘
                                  │
                                  ▼
                            Composition ──▶ Component*
                                            role · target · quantity
                                            pricingMode · returnable?
```

---

## 4. Type system

### 4.1 ProductType

| Field | Type | Notes |
|---|---|---|
| `code` | string | Stable identifier, e.g. `CEREAL` |
| `name`, `description` | string | Human-facing |
| `capabilities` | Capability[] | Orthogonal traits; composable |
| `dimensions` | Dimension[] | Axes products of this type may vary along |
| `productFields` | Field[] | Non-varying attributes (`origin`, `organic`, …) |
| `compositionRules` | object \| null | Allowed roles, required roles, max components, permitted target types |
| `presentationProfile` | string | Named render config |
| `searchProfile` | string | Named ranking config |
| `taxonomyHints` | string[] | Permitted category branches |

### 4.2 Capability

Capabilities are **additive**. A type may hold several.

| Capability | Structural effect |
|---|---|
| `HasVariants` | Product may declare dimensions; offerings carry selections |
| `HasComposition` | Composition permitted/required; `compositionRules` apply |
| `SellByWeight` / `SellByVolume` | Offering requires unit of measure; price basis `PER_UNIT` |
| `ReturnableAsset` | Every Offering must carry a `DEPOSIT` price component |
| `Perishable` | Offering may carry freshness/expiry metadata |
| `Substitutable` | Product may declare substitute references |
| `Subscription` | Offering may carry billing cadence |

**Rule:** new product *types* are new combinations of existing capabilities. New *capabilities* are the only place behavior changes in code — and that change is deliberate.

### 4.3 Dimension

| Field | Type | Notes |
|---|---|---|
| `code` | string | e.g. `species`, `grade`, `state` |
| `valueType` | `ENUM` \| `NUMBER` \| `RANGE` | |
| `unit` | string? | For NUMBER axes (`L`, `kg`) |
| `required` | boolean | Must every offering select a value? |
| `roles` | object | `facetable`, `searchable`, `sortable`, `pricingAxis`, `displayable` |
| `domain` | DimensionValue[] | The axis's value space |
| `default` | string? | Authoring fallback |

### 4.4 DimensionValue

| Field | Type | Notes |
|---|---|---|
| `code` | string | Stable, e.g. `durum`, `A`, `fresh` |
| `label` | string | Display label; localizable |
| `description` | string? | |
| `sortOrder` | int | Ordering in facets and selectors |
| `media` | object? | `{swatch, icon, badge}` — e.g. `badge: "premium"` |
| `metadata` | object? | Type-specific hints |

**This is where display/order/search differences actually live.** "Grade A is premium", "Fresh carries a perishability badge", "Blue has swatch #1e64c8" — declared once per value, never repeated per variant, never hard-coded in UI.

### 4.5 Profiles

- **PresentationProfile** — how dimensions render: which axis is segmented / dropdown / radio, which attributes are tabbed, which dimensions sort the listing.
- **SearchProfile** — ranking weights, boosts, synonyms. Facets themselves are *derived* (see §9), not declared here.

---

## 5. Product

A conforming instance and browsable entry.

| Field | Type | Notes |
|---|---|---|
| `id`, `slug`, `title`, `description` | | |
| `type` | string | ProductType code |
| `status` | `DRAFT` \| `PUBLISHED` \| `ARCHIVED` | |
| `categories` | string[] | Taxonomy paths |
| `media` | Media[] | Ordered; `role: HERO` etc. |
| `attributes` | object | Conforms to `type.productFields` |
| `dimensionDomains` | map<Dimension, ValueCode[]> | **Per-product narrowing** of the type domain |
| `composition` | Composition? | Default composition, inherited by offerings |
| `offerings` | Offering[] | |

**`dimensionDomains` is the key control.** A wheat product declares `species ∈ {durum, emmer}` — not the whole type domain — which prevents implying combinations that do not exist.

---

## 6. Offering & Price

### 6.1 Offering

| Field | Type | Notes |
|---|---|---|
| `id`, `sku` | | |
| `selection` | map<Dimension, ValueCode> | Empty for simple products |
| `price` | Price | |
| `availability` | `{available, reserved}` | |
| `compositionOverride` | Composition? | Only if product has composition |
| `presentationOverrides` | object? | Offering-specific media/copy |
| `status` | | |

### 6.2 Price

| Field | Type | Notes |
|---|---|---|
| `amount`, `currency` | | Net of components |
| `basis` | `PER_UNIT` \| `FLAT` | Weight/volume-aware vs per-item |
| `components` | Component[] | See below |
| `validity` | `{from, to}`? | Optional window |

**PriceComponent**

| `kind` | Meaning |
|---|---|
| `BASE` | Normal sale price |
| `DEPOSIT` | Refundable; required by `ReturnableAsset` |
| `SURCHARGE` | Uplift (e.g. fresh handling) |
| `DISCOUNT` | Negative (e.g. bundle saving) |

**Rule:** `amount` must equal the sum of component amounts. Deposits are structural, never modelled as a second SKU or a note.

---

## 7. Composition

A `Composition` is an ordered list of `Component`s.

| Component field | Type | Notes |
|---|---|---|
| `role` | `CONTAINER` \| `CONTENTS` \| `BUNDLE_ITEM` \| `ACCESSORY` \| `REPLACEMENT` \| `INCLUDED_SERVICE` | Semantic — downstream systems read this |
| `target` | `{productId, offeringSelector?}` or `{offeringId}` | Selector resolved at cart time |
| `quantity`, `unit` | number, string | |
| `pricingMode` | `SEPARATE` \| `INCLUDED` \| `DERIVED` | Drives cart line rendering |
| `returnable` | boolean? | This component bears a returnable lifecycle |
| `optional`, `defaultSelected` | boolean | |
| `displayOrder` | int | |

**pricingMode semantics**

- `SEPARATE` — component is charged and rendered as its own line (container + contents).
- `INCLUDED` — component price folded into parent (bundle items → one line).
- `DERIVED` — parent price computed from components (e.g. bundle discount basis).

**compositionRules** (on ProductType): `allowedRoles`, `requiredRoles`, `maxComponents`, `permittedTargetTypes`.

---

## 8. Invariants

1. An Offering belongs to exactly one Product.
2. An Offering's `selection` fills every `required` dimension of its type and uses only values within the Product's `dimensionDomains`.
3. No two Offerings of a Product share an identical `selection`.
4. A Product may declare dimensions (or have offerings with non-empty selections) **only if** its type has `HasVariants`.
5. A Product or Offering may declare a Composition **only if** its type has `HasComposition`; the Composition must satisfy `compositionRules`.
6. Every `SEPARATE` component must resolve to an Offering with a price (directly or via selector) at cart time.
7. `DERIVED` pricing requires ≥1 `INCLUDED` or `SEPARATE` component as basis.
8. `ReturnableAsset` requires every Offering of the type to carry a `DEPOSIT` price component.
9. Price `amount` equals the sum of its component amounts.
10. Offering price validity windows must not overlap unless prioritized.

---

## 9. Derived behaviors

Nothing below is type-specific. All derive from declarations.

| Behavior | Source |
|---|---|
| Which fields are facets | `Dimension.roles.facetable` + `facetable` product fields |
| Facet value order, labels, badges | `DimensionValue.sortOrder`, `.label`, `.media` |
| Listing sort order | `Dimension.roles.sortable` + value `sortOrder` |
| Searchable terms | `Dimension.roles.searchable` + `searchable` fields + title/description |
| Detail-page selector controls | `PresentationProfile` + `dimensionDomains` + offering selections |
| Price shown | Sum of `price.components` |
| Number of cart lines | `Component.pricingMode` (`SEPARATE` ⇒ own line) |
| Refundable total | Sum of `DEPOSIT` components across lines |

---

## 10. JSON reference shapes

Condensed skeletons. Full examples in §11.

```json
// ProductType
{ "code": "...", "name": "...", "capabilities": ["..."],
  "dimensions": [ { "code": "...", "valueType": "ENUM", "required": true,
                    "roles": { "facetable": true, "searchable": true, "sortable": true,
                               "pricingAxis": true, "displayable": true },
                    "domain": [ { "code": "...", "label": "...", "sortOrder": 1,
                                  "media": { "badge": "..." } } ] } ],
  "productFields": [ { "key": "...", "valueType": "STRING", "required": true } ],
  "compositionRules": { "allowedRoles": [], "requiredRoles": [],
                        "maxComponents": 1, "permittedTargetTypes": [] },
  "presentationProfile": "...", "searchProfile": "...", "taxonomyHints": [] }

// Product
{ "id": "...", "type": "...", "slug": "...", "title": "...", "status": "PUBLISHED",
  "categories": [], "media": [], "attributes": {},
  "dimensionDomains": { "axis": ["valueCode"] },
  "composition": null,
  "offerings": [] }

// Offering
{ "id": "...", "sku": "...", "selection": { "axis": "valueCode" },
  "price": { "amount": 0, "currency": "USD", "basis": "PER_UNIT|FLAT",
             "components": [ { "kind": "BASE|DEPOSIT|SURCHARGE|DISCOUNT", "amount": 0 } ] },
  "availability": { "available": 0, "reserved": 0 } }

// Composition
{ "components": [ { "role": "...",
                    "target": { "productId": "...", "offeringSelector": {} },
                    "quantity": 1, "unit": "each",
                    "pricingMode": "SEPARATE|INCLUDED|DERIVED",
                    "returnable": false, "optional": false,
                    "defaultSelected": false, "displayOrder": 1 } ] }
```

---

## 11. Worked examples

### 11.1 Type — `CEREAL`

```json
{ "code": "CEREAL", "name": "Cereal / Grain",
  "capabilities": ["HasVariants", "SellByWeight", "Perishable"],
  "dimensions": [
    { "code": "species", "valueType": "ENUM", "required": true,
      "roles": { "facetable": true, "searchable": true, "sortable": true, "pricingAxis": true, "displayable": true },
      "domain": [
        { "code": "durum",   "label": "Durum",   "sortOrder": 1 },
        { "code": "emmer",   "label": "Emmer",   "sortOrder": 2 },
        { "code": "spelt",   "label": "Spelt",   "sortOrder": 3 } ] },
    { "code": "grade", "valueType": "ENUM", "required": true,
      "roles": { "facetable": true, "searchable": true, "sortable": true, "pricingAxis": true, "displayable": true },
      "domain": [
        { "code": "A", "label": "Grade A", "sortOrder": 1, "media": { "badge": "premium" } },
        { "code": "B", "label": "Grade B", "sortOrder": 2 },
        { "code": "C", "label": "Grade C", "sortOrder": 3 } ] },
    { "code": "state", "valueType": "ENUM", "required": true,
      "roles": { "facetable": true, "searchable": true, "sortable": true, "pricingAxis": true, "displayable": true },
      "domain": [
        { "code": "dried", "label": "Dried", "sortOrder": 1 },
        { "code": "fresh", "label": "Fresh", "sortOrder": 2, "media": { "badge": "perishable" } } ] } ],
  "productFields": [
    { "key": "origin", "valueType": "STRING", "required": true },
    { "key": "organic", "valueType": "BOOLEAN", "required": false } ],
  "compositionRules": null,
  "presentationProfile": "cereal_detail_v2",
  "searchProfile": "grain_faceted_v2",
  "taxonomyHints": ["Pantry > Grains & Cereals"] }
```

### 11.2 Type — `RETURNABLE_CONTAINER`

```json
{ "code": "RETURNABLE_CONTAINER", "name": "Returnable Container",
  "capabilities": ["HasVariants", "HasComposition", "ReturnableAsset"],
  "dimensions": [
    { "code": "capacity", "valueType": "NUMBER", "unit": "L", "required": true,
      "roles": { "facetable": true, "sortable": true, "displayable": true },
      "domain": [ { "code": "10L", "label": "10 L", "sortOrder": 1 },
                  { "code": "20L", "label": "20 L", "sortOrder": 2 } ] },
    { "code": "color", "valueType": "ENUM", "required": true,
      "roles": { "facetable": true, "displayable": true },
      "domain": [ { "code": "blue", "label": "Blue", "sortOrder": 1, "media": { "swatch": "#1e64c8" } },
                  { "code": "white", "label": "White", "sortOrder": 2, "media": { "swatch": "#f2f2f2" } } ] } ],
  "productFields": [ { "key": "material", "valueType": "STRING", "required": true } ],
  "compositionRules": { "allowedRoles": ["CONTENTS"], "requiredRoles": [],
                        "maxComponents": 1,
                        "permittedTargetTypes": ["CEREAL", "BULK_LIQUID"] },
  "presentationProfile": "container_detail_v2",
  "searchProfile": "container_faceted_v2",
  "taxonomyHints": ["Packaging > Returnable Containers"] }
```

### 11.3 Product — `Wheat Grain` (only real combinations exist)

```json
{ "id": "prd_wheat_grain", "type": "CEREAL", "slug": "wheat-grain",
  "title": "Wheat Grain", "status": "PUBLISHED",
  "categories": ["Pantry > Grains & Cereals > Wheat"],
  "attributes": { "origin": "Punjab, India", "organic": true },
  "dimensionDomains": { "species": ["durum", "emmer"],
                        "grade": ["A", "B"], "state": ["dried", "fresh"] },
  "composition": null,
  "offerings": [
    { "id": "off_wheat_durum_a_dried", "sku": "WHEAT-DURUM-A-DRIED",
      "selection": { "species": "durum", "grade": "A", "state": "dried" },
      "price": { "amount": 42.50, "currency": "USD", "basis": "PER_UNIT",
                 "components": [ { "kind": "BASE", "amount": 42.50 } ] },
      "availability": { "available": 1200, "reserved": 50 } },
    { "id": "off_wheat_durum_a_fresh", "sku": "WHEAT-DURUM-A-FRESH",
      "selection": { "species": "durum", "grade": "A", "state": "fresh" },
      "price": { "amount": 48.00, "currency": "USD", "basis": "PER_UNIT",
                 "components": [ { "kind": "BASE", "amount": 42.50 },
                                 { "kind": "SURCHARGE", "amount": 5.50, "note": "Fresh handling" } ] },
      "availability": { "available": 300, "reserved": 10 } },
    { "id": "off_wheat_emmer_b_dried", "sku": "WHEAT-EMMER-B-DRIED",
      "selection": { "species": "emmer", "grade": "B", "state": "dried" },
      "price": { "amount": 55.00, "currency": "USD", "basis": "PER_UNIT",
                 "components": [ { "kind": "BASE", "amount": 55.00 } ] },
      "availability": { "available": 0, "reserved": 0 } } ] }
```

### 11.4 Product — `HDPE Jerrycan 20L` (container + declared fill)

```json
{ "id": "prd_hdpe_jerrycan", "type": "RETURNABLE_CONTAINER", "slug": "hdpe-jerrycan-20l",
  "title": "HDPE Jerrycan — 20 L", "status": "PUBLISHED",
  "categories": ["Packaging > Returnable Containers > Jerrycans"],
  "attributes": { "material": "HDPE" },
  "dimensionDomains": { "capacity": ["20L"], "color": ["blue", "white"] },
  "composition": {
    "components": [
      { "role": "CONTENTS",
        "target": { "productId": "prd_wheat_grain",
                    "offeringSelector": { "species": "durum", "grade": "A", "state": "dried" } },
        "quantity": 20, "unit": "L",
        "pricingMode": "SEPARATE",
        "optional": true, "defaultSelected": false,
        "displayOrder": 1 } ] },
  "offerings": [
    { "id": "off_jerrycan_20l_blue", "sku": "CTN-HDPE-20L-BLUE",
      "selection": { "capacity": "20L", "color": "blue" },
      "price": { "amount": 7.00, "currency": "USD", "basis": "FLAT",
                 "components": [ { "kind": "BASE", "amount": 5.00, "note": "Container cost" },
                                 { "kind": "DEPOSIT", "amount": 2.00, "note": "Refundable on return" } ] },
      "availability": { "available": 5000, "reserved": 0 } } ] }
```

### 11.5 Product — `Breakfast Starter Kit` (bundle, one chargeable line)

```json
{ "id": "prd_breakfast_kit", "type": "BUNDLE", "slug": "breakfast-starter-kit",
  "title": "Breakfast Starter Kit", "status": "PUBLISHED",
  "categories": ["Gifts & Bundles > Breakfast"],
  "attributes": {},
  "dimensionDomains": {},
  "composition": {
    "components": [
      { "role": "BUNDLE_ITEM",
        "target": { "productId": "prd_wheat_grain",
                    "offeringSelector": { "species": "durum", "grade": "A", "state": "dried" } },
        "quantity": 1, "unit": "kg", "pricingMode": "INCLUDED", "displayOrder": 1 },
      { "role": "CONTAINER",
        "target": { "productId": "prd_hdpe_jerrycan",
                    "offeringSelector": { "capacity": "10L", "color": "white" } },
        "quantity": 1, "unit": "each", "pricingMode": "INCLUDED",
        "returnable": true, "displayOrder": 2 },
      { "role": "ACCESSORY",
        "target": { "productId": "prd_canvas_tote" },
        "quantity": 1, "unit": "each", "pricingMode": "INCLUDED", "displayOrder": 3 } ] },
  "offerings": [
    { "id": "off_breakfast_kit_default", "sku": "BUNDLE-BREAKFAST-01",
      "selection": {},
      "price": { "amount": 59.00, "currency": "USD", "basis": "FLAT",
                 "components": [ { "kind": "BASE", "amount": 65.00, "note": "Sum of components" },
                                 { "kind": "DISCOUNT", "amount": -6.00, "note": "Bundle saving" } ] },
      "availability": { "available": 100, "reserved": 0 } } ] }
```

### 11.6 Product — `Canvas Tote` (degenerate case)

```json
{ "id": "prd_canvas_tote", "type": "SIMPLE_GOOD", "slug": "canvas-tote",
  "title": "Canvas Tote", "status": "PUBLISHED",
  "categories": ["Accessories > Bags"],
  "attributes": { "material": "cotton" },
  "dimensionDomains": {}, "composition": null,
  "offerings": [
    { "id": "off_tote_default", "sku": "TOTE-CANVAS-STD", "selection": {},
      "price": { "amount": 15.00, "currency": "USD", "basis": "FLAT",
                 "components": [ { "kind": "BASE", "amount": 15.00 } ] },
      "availability": { "available": 400, "reserved": 5 } } ] }
```

`SIMPLE_GOOD` has **no capabilities**. "Simple" is not a mechanism — it is the empty case.

---

## 12. Scenarios

### S1 — Faceted browse for "wheat"

`searchProfile: grain_faceted_v2` selects ranking. Facets are assembled from dimensions where `roles.facetable = true`, and values come from `DimensionValue`.

```json
{ "query": "wheat",
  "results": [ { "id": "prd_wheat_grain", "title": "Wheat Grain",
                 "priceRange": { "min": 42.50, "max": 55.00, "currency": "USD" },
                 "inStock": true } ],
  "facets": [
    { "dimension": "species", "label": "Species",
      "values": [ { "code": "durum", "label": "Durum", "sortOrder": 1, "count": 2 },
                  { "code": "emmer", "label": "Emmer", "sortOrder": 2, "count": 1 } ] },
    { "dimension": "grade", "label": "Grade",
      "values": [ { "code": "A", "label": "Grade A", "sortOrder": 1, "badge": "premium", "count": 2 },
                  { "code": "B", "label": "Grade B", "sortOrder": 2, "count": 1 } ] },
    { "dimension": "state", "label": "State",
      "values": [ { "code": "dried", "label": "Dried", "sortOrder": 1, "count": 2 },
                  { "code": "fresh", "label": "Fresh", "sortOrder": 2, "badge": "perishable", "count": 1 } ] } ] }
```

No cereal-specific code produced the labels, order, or badges.

### S2 — Detail-page selector derivation

Controls come from `PresentationProfile`; options from `dimensionDomains` + `DimensionValue`; availability from offerings.

```json
{ "product": "prd_wheat_grain",
  "selectors": [
    { "dimension": "species", "control": "SEGMENTED",
      "options": [ { "code": "durum", "label": "Durum" }, { "code": "emmer", "label": "Emmer" } ] },
    { "dimension": "grade", "control": "DROPDOWN",
      "options": [ { "code": "A", "label": "Grade A", "badge": "premium" },
                   { "code": "B", "label": "Grade B" } ] },
    { "dimension": "state", "control": "RADIO",
      "options": [ { "code": "dried", "label": "Dried" },
                   { "code": "fresh", "label": "Fresh", "badge": "perishable" } ] } ],
  "offeringMatrix": {
    "durum|A|dried": { "offeringId": "off_wheat_durum_a_dried", "price": 42.50, "available": true },
    "durum|A|fresh": { "offeringId": "off_wheat_durum_a_fresh", "price": 48.00, "available": true },
    "emmer|B|dried": { "offeringId": "off_wheat_emmer_b_dried", "price": 55.00, "available": false } } }
```

### S3 — Buy a filled container → cart renders two lines

Cart reads the CONTENTS component's `pricingMode: SEPARATE` and both offerings' `price.components`.

```json
{ "lines": [
    { "lineId": "ln_c1", "role": "CONTAINER",
      "sourceOfferingId": "off_jerrycan_20l_blue",
      "title": "HDPE Jerrycan — 20 L (Blue)",
      "priceComponents": [ { "kind": "BASE", "amount": 5.00 },
                           { "kind": "DEPOSIT", "amount": 2.00, "refundable": true } ],
      "quantity": 1, "lineTotal": 7.00 },
    { "lineId": "ln_c2", "role": "CONTENTS", "parentLineId": "ln_c1",
      "sourceOfferingId": "off_wheat_durum_a_dried",
      "title": "Wheat Grain — Durum, Grade A, Dried",
      "priceComponents": [ { "kind": "BASE", "amount": 42.50 } ],
      "quantity": 20, "unit": "kg", "lineTotal": 850.00 } ],
  "summary": { "subtotal": 857.00, "refundableDeposit": 2.00, "currency": "USD" } }
```

### S4 — Same container, bought empty

`optional: true, defaultSelected: false` on CONTENTS ⇒ the component is skipped; only the container line remains. Subtotal `7.00`; `refundableDeposit: 2.00`. **No code branch** — the selection simply excludes the optional component.

### S5 — Buy the bundle

All components are `INCLUDED` ⇒ **one** cart line at `59.00`. The container component carries `returnable: true`, so the line exposes `includedReturnables: [{ productId: "prd_hdpe_jerrycan", deposit: 2.00 }]` — the returns system sees the refundable item even though the bundle type is not `ReturnableAsset`.

### S6 — Returns workflow

Returns service queries lines for `kind: DEPOSIT` or components with `returnable: true`. It finds them uniformly in S3 and S5 without knowing what a container or a bundle is. Deposit lifecycle (tracking individual units) is out of scope here — the catalog only declares *intent*.

### S7 — Onboarding a new type (`FRESH_PRODUCE`)

1. Author `ProductType FRESH_PRODUCE`: capabilities `[HasVariants, SellByWeight, Perishable]`; dimensions `variety`, `sizeClass`, `ripeness`; profile keys.
2. Publish products conforming to it, with `dimensionDomains` and offerings.

**No schema change. No deploy.** Search, facets, detail page, and cart already handle it because they read declarations. The only engineering involvement is if the new type needs a capability that does not yet exist — and that is a deliberate, reviewable event.

---

## 13. Extension guide

| You want to… | Do this | Code change? |
|---|---|---|
| Add a product type | Author a `ProductType` declaration | No |
| Add an attribute to a type | Add to `productFields` or `dimensions` | No |
| Add a value to an axis | Add a `DimensionValue` | No |
| Change facet/sort/search behavior | Toggle `Dimension.roles` | No |
| Change how axes render | Edit `PresentationProfile` | No (config) |
| Add a pricing uplift | Add a `SURCHARGE` component on the offering | No |
| Add a new composition shape (kit, assembly) | Add roles + `pricingMode` values | No (if roles exist) |
| Add a genuinely new capability | Implement capability + its invariant | **Yes** |
| Add a new `pricingMode` semantic | Extend resolver | **Yes** |

The dividing line is intentional: **product types are data; capabilities and pricing semantics are code.**

---

## 14. Out of scope

- **Asset tracking** of individual returnable units (serial numbers, deposit ledger, return workflow) — separate Asset/Returns domain. The catalog declares intent (`ReturnableAsset`, `DEPOSIT`, `returnable`) only.
- **Promotion/tiered pricing engine** — capabilities and price components signal it; rule evaluation is its own domain.
- **Localization workflow** — `DimensionValue.label` and profile strings are localizable values; the workflow is elsewhere.
- **Schema versioning/governance** — types are conceptually versionable; the governance process is not specified here.
- **Inventory allocation and reservation policy** — only `available`/`reserved` shape is defined.

---

## 15. Glossary

| Term | Definition |
|---|---|
| **ProductType** | Declarative schema a product conforms to |
| **Capability** | Orthogonal, composable behavioral trait of a type |
| **Dimension** | A declared axis of variation with a domain and roles |
| **DimensionValue** | A point on an axis carrying label, media, sort order |
| **Product** | Browsable catalog entry; conforming instance |
| **dimensionDomains** | Per-product narrowing of the type's axis domains |
| **Offering** | Sellable unit: a selection over dimensions plus a Price |
| **Price component** | Typed amount (`BASE`/`DEPOSIT`/`SURCHARGE`/`DISCOUNT`) |
| **Composition** | Ordered structure of Components |
| **Component** | Role + target + quantity + pricingMode |
| **pricingMode** | `SEPARATE` (own line) / `INCLUDED` (folded) / `DERIVED` (computed) |
| **Profile** | Named configuration for presentation or search |

---
