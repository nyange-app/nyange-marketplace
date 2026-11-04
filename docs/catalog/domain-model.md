# Nyange Catalog Domain Model

Status: draft for review. Technology-neutral. Complements the business specification in `docs/architecture.md`.
Inspired by the reference model in `docs/nyange-catalog-domain-model.md`, which is kept unchanged.

## Contents

1. Purpose
2. Principles
3. Concept map
4. ProductType
5. Product and attributes
6. Variant
7. Offer
8. Order-line snapshot
9. Invariants
10. Derived behaviours
11. Worked examples
12. Extension guide
13. Relationship to the business specification
14. Relationship to the reference model
15. Out of scope
16. Glossary
17. Open points

---

## 1. Purpose

Define a catalog model for Nyange's marketplace that handles structurally different products (graded cereals, returnable containers priced as contents and container, simple packaged goods) and takes in new product types by **authoring declarations, not by adding product-specific logic**.

Nyange owns the catalog. Sellers own prices and stock. The catalog never holds a price.

---

## 2. Principles

1. **Catalog and market are separate.** Nyange declares what exists. Sellers price it. A buyer's price range is computed from many sellers' offers on the same variant.
2. **Four levels, each with one job.** A *type* declares the shape. A *product* declares its attributes and values. A *variant* is one combination of specification values. An *offer* is a seller's price on a variant.
3. **Two attribute roles.** *Specification* attributes split the market (grade, state, LPG brand). *Descriptive* attributes inform without splitting (origin, maize variety).
4. **Components are priced separately; modes say what is charged.** A cylinder has contents and a container. *Swap* charges the contents and requires the empty back. *New* charges both.
5. **Behaviour is derived.** Display, ordering, search, price range, seller eligibility and delivery handling read the declarations. There is no per-product code.
6. **Orders snapshot.** What was fixed at the moment of the price lock never changes afterwards.
7. **A small vocabulary.** Adding a product, a value or a type from existing vocabulary is data. Adding a new vocabulary item is a deliberate change.

---

## 3. Concept map

```
ProductType ──shapes──▶ Product ──yields──▶ Variant ◀──prices── Offer ◀── Seller location
  sale style              attributes + roles   specification values   component prices
  components              value lists          (catalog-owned,        stock per mode
  modes (hand-back)       fulfilment flags      no price)             stated attributes
                                                     │
                                                     ▼
                                           Order-line snapshot
```

---

## 4. ProductType

The shape shared by a family of products.

| Field | Type | Notes |
|---|---|---|
| `code` | string | Stable identifier, e.g. `bulk_goods` |
| `name` | localized text | |
| `sale` | `by_measure` \| `by_piece` | How quantity and price are expressed |
| `baseUnit` | string | `by_measure` only: `kg` or `L` |
| `step`, `minimum` | number | `by_measure` only: the default quantity step and minimum for products of this type. A product may override them |
| `components` | Component[] | The separately priced parts. At least one |
| `modes` | Mode[] | Optional. If omitted, one implicit mode `default` charges every component |
| `fulfilment` | object | Type-level flags: `heavy`, `hazardous` |

**Component:** `{ key, names, kind }`, where `kind` is one of `goods` (the thing sold), `contents` (what is inside a container, sold per refill) or `container` (the returnable vessel). `names` is localized display text, for example "Contents" and "Container".

**Mode:** `{ key, names, charges[], handBack? }`.
- `names` is localized display text for the buyer's choice, for example "Swap (hand back an empty)" and "New (buy the container)".
- `charges` lists component keys that are charged in this mode.
- `handBack` is `{ component, mustMatch }`: the buyer hands back one unit of that component per unit ordered, and its specification values must match the variant's (`mustMatch: "specification"`).
- The hand-back wording shown to the buyer is derived, not authored: "hand back one <component name> of the same <specification> per unit".
- A type **returns empties** exactly when one of its modes has `handBack`. This is derived, not declared.

**Rules:** every `charges` entry and every `handBack.component` names a declared component. `by_measure` types do not declare modes at launch.

---

## 5. Product and attributes

A catalog entry that conforms to one type, with its own attributes and value lists.

| Field | Type | Notes |
|---|---|---|
| `key`, `names` | | `names` is localized; English at launch |
| `type` | string | ProductType `code` |
| `categories` | string[] | Taxonomy paths |
| `status` | `draft` \| `published` \| `retired` | |
| `unitName` | localized text | `by_piece` only: "cylinder", "bag", "bottle" |
| `attributes` | Attribute[] | |
| `exclusions` | map[] | Specification combinations that do not exist |
| `step`, `minimum` | number | `by_measure` only, optional: override the type's defaults for this product |
| `weights` | rule[] | Shipping weight per unit by specification, e.g. `{ when: {size: "13kg"}, kg: 28 }`. For `by_measure`, weight is the quantity |

**Attribute:**

| Field | Notes |
|---|---|
| `key`, `names` | |
| `role` | `specification` or `descriptive` |
| `searchable` | Whether it is a filter and a search term |
| `displayOrder` | Position in display names and forms |
| `values` | The allowed values. Required for specification attributes |
| `statedBy` | Descriptive only: `nyange` (a fixed list) or `seller` (stated on each offer, free text or from the list) |

**Value:** `{ key, names, aliases[], sortOrder, flags[] }`.
- `aliases` are search terms in any language (for example "Nambale" for K132).
- `flags` carry fulfilment hints that hang on a value, such as `perishable` on `fresh`.

Roles are declared **per product**, not per type. The same attribute can be a specification for one product (bean variety) and descriptive for another (maize variety).

---

## 6. Variant

One combination of specification values for a product. Catalog-owned, with no price.

- **Key:** `<product>:<attribute>=<value>:...`, listing specification attributes in display order, e.g. `maize:grade=A:state=dried`.
- **Existence:** every combination of specification values exists unless excluded. Variants are implicit; nobody authors them one by one.
- **Display name:** the product name followed by the specification value names in display order: "Maize, Grade A, dried".
- **Derived properties:** the type, the fulfilment flags (the type's plus any value flags), the shipping weight per unit, and the unit.
- **Available** when at least one active offer is in stock for at least one mode.

---

## 7. Offer

A seller's price on a variant. Seller-owned, and the only place prices live.

| Field | Type | Notes |
|---|---|---|
| `id` | string | |
| `seller`, `location` | | The offer belongs to one seller location |
| `variant` | string | Variant key |
| `prices` | map<component, UGX> | Whole shillings per sale unit (per kg, or per piece). A component the seller does not price is not offered |
| `stock` | map<mode, boolean> | In-stock status per mode. A `by_measure` offer uses the single key `default` |
| `stated` | map<attribute, value> | Descriptive values the seller states (origin, variety) |
| `status` | `active` \| `paused` | |
| `updatedAt` | timestamp | |

**A mode is offered** by an offer when every component it charges is priced and the mode's stock is true. The **mode price** is the sum of the charged component prices. The **line price** is the mode price times the quantity.

---

## 8. Order-line snapshot

Taken when a seller's claim locks the price, and never changed.

| Field | Notes |
|---|---|
| `catalogVersion` | The catalog version in force |
| `variant`, `displayName` | |
| `specification` | The specification values as ordered |
| `stated` | The seller's stated values as offered |
| `mode`, `quantity`, `unit` | |
| `charged` | Each charged component with its price |
| `mustHandBack` | `{ component, specification, quantity }`, or none |
| `fulfilment` | Flags and shipping weight |
| `offer` | The offer id it came from |

---

## 9. Invariants

1. Every product conforms to exactly one type. Every offer references exactly one variant.
2. Types, products, attributes, values and exclusions are created and changed only by Nyange. Sellers choose among declared values and cannot create any.
3. A variant takes exactly one value, from the product's own value list, for every specification attribute, and is not an excluded combination.
4. Descriptive attributes never split variants. Seller-stated descriptive values belong to the offer.
5. A seller location has at most one offer per variant.
6. An offer prices only components its type declares. Amounts are positive whole UGX.
7. A mode is offered only if every charged component is priced and the mode is in stock. The mode price is the sum of the charged component prices.
8. `by_measure` quantities are multiples of the product's step and at least its minimum (the product's own values, else the type's defaults). `by_piece` quantities are whole units of at least 1.
9. A mode with `handBack` requires one unit of the named component per unit ordered, matching the variant's specification values.
10. An order-line snapshot is fixed at the price lock and never changes, whatever later happens to the catalog or the offer.
11. Retiring a value, variant or product pauses its offers for new orders. Snapshots and in-flight orders are untouched.
12. Every value, mode and component carries a name in each supported language, and values may carry aliases. Search matches names and aliases.

---

## 10. Derived behaviours

Nothing below is product-specific. Each is read from the declarations.

| Behaviour | Source |
|---|---|
| Display name | Product name + specification values in `displayOrder` |
| Ordering form | Specification attributes, the mode choice by mode name (if the type has modes), the quantity control from the sale style |
| Quantity rules | `by_measure`: the product's `step` and `minimum`, else the type's. `by_piece`: whole units |
| Price range shown to a buyer | Lowest and highest mode price across eligible offers (in reach, mode offered and in stock) |
| Buyer's price ceiling | The highest mode price in that range |
| Which sellers can claim | Offers whose mode is offered, in stock and in reach |
| Filters and search | Searchable attributes, value names and aliases |
| Delivery handling | Fulfilment flags (heavy, hazardous, perishable, returns empties) and shipping weight |
| What the agent collects at the door | `handBack` of the chosen mode |
| Receipt lines | The charged components in the snapshot, by component name |

---

## 11. Worked examples

Products and brands are real; **prices and weights are illustrative**.

### 11.1 Types

```json
{
  "types": {
    "bulk_goods": {
      "name": { "en": "Bulk goods" },
      "sale": "by_measure", "baseUnit": "kg", "step": 10, "minimum": 10,
      "components": [ { "key": "goods", "names": { "en": "Goods" }, "kind": "goods" } ],
      "fulfilment": { "heavy": true }
    },
    "packaged": {
      "name": { "en": "Packaged good" },
      "sale": "by_piece",
      "components": [ { "key": "goods", "names": { "en": "Goods" }, "kind": "goods" } ]
    },
    "returnable": {
      "name": { "en": "Returnable container" },
      "sale": "by_piece",
      "components": [ { "key": "contents", "names": { "en": "Contents" }, "kind": "contents" },
                      { "key": "container", "names": { "en": "Container" }, "kind": "container" } ],
      "modes": [
        { "key": "swap", "names": { "en": "Swap (hand back an empty)" }, "charges": ["contents"],
          "handBack": { "component": "container", "mustMatch": "specification" } },
        { "key": "new",  "names": { "en": "New (buy the container)" }, "charges": ["contents", "container"] }
      ],
      "fulfilment": { "heavy": true }
    }
  }
}
```

### 11.2 Products

```json
{
  "products": {
    "maize": {
      "type": "bulk_goods", "names": { "en": "Maize" }, "status": "published",
      "attributes": [
        { "key": "grade", "role": "specification", "searchable": true, "displayOrder": 1,
          "values": [ { "key": "A", "names": { "en": "Grade A" }, "sortOrder": 1 },
                      { "key": "B", "names": { "en": "Grade B" }, "sortOrder": 2 },
                      { "key": "C", "names": { "en": "Grade C" }, "sortOrder": 3 } ] },
        { "key": "state", "role": "specification", "searchable": true, "displayOrder": 2,
          "values": [ { "key": "dried", "names": { "en": "dried" }, "sortOrder": 1 },
                      { "key": "fresh", "names": { "en": "fresh" }, "sortOrder": 2,
                        "flags": ["perishable"] } ] },
        { "key": "variety", "role": "descriptive", "statedBy": "seller", "searchable": true,
          "values": [ { "key": "longe5", "names": { "en": "Longe 5" } },
                      { "key": "longe10h", "names": { "en": "Longe 10H" } } ] },
        { "key": "origin", "role": "descriptive", "statedBy": "seller", "searchable": false }
      ]
    },
    "beans": {
      "type": "bulk_goods", "names": { "en": "Beans" }, "status": "published",
      "attributes": [
        { "key": "variety", "role": "specification", "searchable": true, "displayOrder": 1,
          "values": [ { "key": "k132", "names": { "en": "K132" }, "aliases": ["Nambale"], "sortOrder": 1 },
                      { "key": "kanyebwa", "names": { "en": "Kanyebwa" }, "sortOrder": 2 } ] },
        { "key": "grade", "role": "specification", "searchable": true, "displayOrder": 2,
          "values": [ { "key": "A", "names": { "en": "Grade A" } },
                      { "key": "B", "names": { "en": "Grade B" } },
                      { "key": "C", "names": { "en": "Grade C" } } ] },
        { "key": "state", "role": "specification", "searchable": true, "displayOrder": 3,
          "values": [ { "key": "dried", "names": { "en": "dried" } },
                      { "key": "fresh", "names": { "en": "fresh" }, "flags": ["perishable"] } ] }
      ]
    },
    "sugar": {
      "type": "packaged", "names": { "en": "Sugar" }, "status": "published",
      "unitName": { "en": "bag" },
      "attributes": [
        { "key": "brand", "role": "specification", "searchable": true, "displayOrder": 1,
          "values": [ { "key": "kakira", "names": { "en": "Kakira" } },
                      { "key": "kinyara", "names": { "en": "Kinyara" } },
                      { "key": "scoul", "names": { "en": "SCOUL" } } ] },
        { "key": "pack", "role": "specification", "searchable": false, "displayOrder": 2,
          "values": [ { "key": "50kg-bag", "names": { "en": "50 kg bag" } } ] }
      ],
      "weights": [ { "when": { "pack": "50kg-bag" }, "kg": 50 } ]
    },
    "lpg": {
      "type": "returnable", "names": { "en": "LPG" }, "status": "published",
      "unitName": { "en": "cylinder" },
      "attributes": [
        { "key": "brand", "role": "specification", "searchable": true, "displayOrder": 1,
          "values": [ { "key": "total", "names": { "en": "Total" } },
                      { "key": "shell", "names": { "en": "Shell" } },
                      { "key": "hass", "names": { "en": "Hass" } },
                      { "key": "stabex", "names": { "en": "Stabex" } } ] },
        { "key": "size", "role": "specification", "searchable": true, "displayOrder": 2,
          "values": [ { "key": "6kg", "names": { "en": "6 kg" } },
                      { "key": "13kg", "names": { "en": "13 kg" } } ] }
      ],
      "weights": [ { "when": { "size": "6kg" }, "kg": 15 },
                   { "when": { "size": "13kg" }, "kg": 28 } ]
    },
    "jibu-water": {
      "type": "returnable", "names": { "en": "Jibu water" }, "status": "published",
      "unitName": { "en": "bottle" },
      "attributes": [
        { "key": "size", "role": "specification", "searchable": true, "displayOrder": 1,
          "values": [ { "key": "20l", "names": { "en": "20 L" } } ] }
      ],
      "weights": [ { "when": { "size": "20l" }, "kg": 22 } ]
    }
  }
}
```

Variant counts: maize 6 (grade × state), beans 12 (variety × grade × state), sugar 3, LPG 8, Jibu 1. Examples of keys: `maize:grade=A:state=dried`, `beans:variety=k132:grade=B:state=dried`, `lpg:brand=total:size=13kg`.

### 11.3 Seller offers

```json
{
  "offers": [
    { "id": "of_1", "seller": "seller_a", "location": "nakasero",
      "variant": "maize:grade=A:state=dried",
      "prices": { "goods": 1350 }, "stock": { "default": true },
      "stated": { "variety": "longe5", "origin": "Masindi" }, "status": "active" },

    { "id": "of_2", "seller": "seller_b", "location": "owino",
      "variant": "maize:grade=A:state=dried",
      "prices": { "goods": 1280 }, "stock": { "default": true },
      "stated": { "origin": "Lira" }, "status": "active" },

    { "id": "of_3", "seller": "seller_a", "location": "kampala_depot",
      "variant": "lpg:brand=total:size=13kg",
      "prices": { "contents": 115000, "container": 150000 },
      "stock": { "swap": true, "new": true }, "status": "active" },

    { "id": "of_4", "seller": "seller_c", "location": "kawempe",
      "variant": "lpg:brand=total:size=13kg",
      "prices": { "contents": 118000 },
      "stock": { "swap": true }, "status": "active" },

    { "id": "of_5", "seller": "seller_b", "location": "owino",
      "variant": "sugar:brand=kakira:pack=50kg-bag",
      "prices": { "goods": 205000 }, "stock": { "default": true }, "status": "active" }
  ]
}
```

### 11.4 Order-line snapshot

```json
{
  "snapshot": {
    "catalogVersion": "2026.11",
    "variant": "lpg:brand=total:size=13kg",
    "displayName": "LPG, Total, 13 kg (swap)",
    "specification": { "brand": "total", "size": "13kg" },
    "mode": "swap", "quantity": 2, "unit": "cylinder",
    "charged": { "contents": 115000 },
    "mustHandBack": { "component": "container",
                      "specification": { "brand": "total", "size": "13kg" }, "quantity": 2 },
    "fulfilment": { "heavy": true, "returnsEmpties": true, "shippingWeightKg": 56 },
    "offer": "of_3"
  }
}
```

### 11.5 Scenarios

**S1. Dried grade A maize, 200 kg.** Eligible offers are `of_1` (1,350 per kg) and `of_2` (1,280 per kg). The range for 200 kg is 256,000 to 270,000, and the buyer's ceiling is 270,000. A seller can claim only at their own price. Origin and variety are shown from the seller's stated values; they do not affect which offers compare.

**S2. Total 13 kg LPG, swap.** The mode is offered by `of_3` (115,000) and `of_4` (118,000). The range is 115,000 to 118,000. The buyer must hand back a Total 13 kg empty per cylinder.

**S3. The same LPG, new.** Only `of_3` offers `new`, because `of_4` has no container price and no `new` stock. The price is 115,000 + 150,000 = 265,000, with no hand-back.

**S4. Add soya flour.** Another `by_measure` product of type `bulk_goods`. Author a product block with its attributes and values; no type or code changes.

**S5. Add Hass 6 kg.** Already declared. A seller just offers on `lpg:brand=hass:size=6kg`.

---

## 12. Extension guide

| You want to… | Do this | Code change? |
|---|---|---|
| Add a product of an existing type | Add a Product with attributes and values | No |
| Add a value (brand, grade, variety) | Add it to the attribute's value list | No |
| Remove a combination that does not exist | Add an exclusion | No |
| Add a language or search alias | Add names or aliases | No |
| Add a type from existing vocabulary | Declare sale style, components, modes | No |
| Change a seller's price or stock | Edit the offer | No |
| Add a new component kind, sale style (for example `by_quote` for services), fulfilment property or attribute role | Extend the vocabulary | **Yes**, deliberately, with a change to this document |

---

## 13. Relationship to the business specification

| This model | Business specification (`docs/architecture.md`) |
|---|---|
| Offer, stock per mode | Seller standing offers and the in-stock status (decision 39) |
| Mode, `handBack` | Returnable containers: swap or new, empties returned (decisions 38 and 47) |
| Mode price, price range, ceiling | Range pricing and the buyer's approved ceiling (decision 6) |
| Order-line snapshot | Price locked at claim |
| Fulfilment flags and weight | Heavy goods, perishables, vehicle class (deferred) |
| Specification attributes | "The variant defines the container" (brand and size) |
| (not here) | The return container factor of 1.5 is a delivery pricing rule |

---

## 14. Relationship to the reference model

**Kept:** declared types; attributes with roles; per-product value lists; labels, aliases and sort order on values; typed price parts; derived behaviours; an extension guide that separates data from code.

**Changed for Nyange:**
- The reference Offering is split into a catalog-owned **Variant** and a seller-owned **Offer**.
- The deposit and the returnable-asset capability are replaced by **modes** and **hand-back**: a new container is a purchase, and a swap returns the empty.
- Composition becomes **components of one claimable line**, not separate cart lines.
- Roles are declared **per product**, and reduced to two.
- Capabilities are reduced to the sale style, components and modes.
- UI configuration (presentation and search profiles, controls, badges) is removed from the domain.
- **Snapshots** and **units with steps** are added.

---

## 15. Out of scope

- Delivery fees and routes, including the return container factor.
- Order lifecycle, claiming, payment and holds (the business specification).
- Quantity-level inventory counts. Stock is an in-stock status per mode.
- Promotions, bundles and subscriptions.
- Tax and receipts.
- Images and media.
- Services (quotes, bookings, rides), which need a new ordering style in the vocabulary.

---

## 16. Glossary

| Term | Meaning |
|---|---|
| **ProductType** | The shape of a family of products: sale style, components, modes |
| **Product** | A catalog entry with its attributes and value lists |
| **Attribute** | A named characteristic of a product, with a role |
| **Specification** | A role: the attribute must match and splits variants |
| **Descriptive** | A role: information only; does not split variants |
| **Variant** | One combination of specification values; catalog-owned, no price |
| **Offer** | A seller location's price and stock on a variant |
| **Component** | A separately priced part (goods, contents, container) |
| **Mode** | A way to buy a variant: which components are charged and what is handed back |
| **Hand-back** | What the buyer returns in a mode, matching the variant's specification |
| **Snapshot** | The record of a line as fixed at the price lock |

---

## 17. Open points

- The official grade scheme for cereals (none found). The grade values here are placeholders.
- Whether maize variety is really descriptive for buyers (it is a specification for beans). Confirm with traders.
- Whether "grade A or better" matching should be allowed later to enlarge pools.
- Real step and minimum quantities per product, from traders. The 10 kg defaults are placeholders; households and bulk buyers differ.
- Real shipping weights for cylinders and bottles.
- Languages beyond English (Luganda) and their search aliases.
- How services will extend the vocabulary.
