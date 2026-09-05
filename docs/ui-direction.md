# Native grocery UI direction

Audience: a couple planning and shopping across familiar stores. Primary task: see what must be bought here, what may be bought here, and mark the same household grocery as carted.

## Compact visual tokens
- Canvas: adaptive system background (light #FFFFFF); supporting surfaces: system grouped background (light #F2F2F7).
- Text: adaptive label (light #1C1C1E); secondary text: adaptive secondary label (light approximately #636366).
- Primary action/selected store: restrained grocery green #25634B, with an appropriate lighter dark-mode variant.
- Urgency: #B54A1E in light mode, always accompanied by the word Urgent and an icon; never color alone.
- Type: native SF text styles for Dynamic Type—largeTitle, headline, body, subheadline, caption. SF is deliberate for one-handed native iPhone use, rather than importing a web display face.
- Controls: native 44pt minimum tap regions; list rows grow for long names and accessibility type sizes. No fixed-height text clipping.

## Layout choices
A horizontal chip strip for every store would bury All and make long names awkward. Use a compact explicit All button plus selected-store menu, with a labeled Filters action. Let the store choice and required/flexible split carry the visual identity; keep rows quiet.

    Groceries                              +
    Search groceries
    All     Costco v              Filters 2

    Must buy here
    ( ) Frozen strawberries             2
        Urgent       Only buy at Costco

    Flexible here
    ( ) Dinner rolls                    1
        Buy at Costco, Walmart

    Carted (3) >
    Recently cleared >

    Groceries       Catalog       Settings

Left-align names and supporting detail; align quantity at the trailing edge. Tapping the cart control changes carted state. Tapping the row edits details. Clear carted belongs inside carted/recovery actions with count/scope confirmation; no Delete all control exists.

All view groups uncarted needs with urgency first and optional global category order; Uncategorized last. A selected store always partitions eligible rows into Must buy here then Flexible here, with urgency first inside each section. Text/category/urgency/include-exclude only narrow those rows.

Empty household: Add groceries is the primary action. Empty filtered result: explain no matches and Reset filters; don't imply the underlying list is empty. Catalog has reusable items only; Recently cleared is explicit recovery, never a suggestion source. Forms stage data until Save and preserve input on failure.

## Review against brief
This is a native utility, so avoid a marketing hero, decorative cards, gradients, custom animation or artificial branding. The useful distinction is the buying rule: Only buy at Costco vs Buy at Costco/Walmart vs Any store. No retailer-stock claims, trips, events, reminders or price engine. Native text scaling, VoiceOver labels, reduced motion and clear item state have priority over ornamental novelty.

Implementation follows Plane issue dependencies. Navigation destinations may be scaffolded first; usable add/edit and safe clear are completed by their dedicated issues before any MVP claim.

## Store management and purchase tags

Settings supports explicit store creation, staged rename, exact-set ordering, and archive/restore. Archive preserves catalog memberships and groceries. Archived tags remain known; they do not make a grocery eligible at a current store. All and Catalog expose Needs store when no active purchase option remains.

The purchase-rule picker keeps Any store separate from literal tags. Existing archived tags may remain alongside an active tag or Any store; unavailable identities can be explicitly removed. Choices and inline existing-store suggestions use the selected list's household object and persistent store, and exclude ambiguous store IDs.

Add store opens within the tagging form. Cancel leaves the grocery draft intact. Save store explicitly adds household metadata and selects its tag; the grocery remains staged until Add. Canceling the parent after Save store retains that explicitly saved store but creates no grocery or catalog entry.

## Reusable catalog

Catalog stores general item knowledge independently of current demand. Create/edit stages the name, general notes, optional category, Any store flag, and literal store tags; Save submits them in one atomic command. Cancel makes no catalog or grocery change. A new item starts with the current catalog availability-store filter as its explicit tag, or asks for a store/Any store when viewing all stores. Existing items always start with their own saved rules.

Search shows existing matches before creation. Introducing a normalized same-name item through creation or rename requires an explicit distinct-item choice; editing an already intentional same-name variant does not require reconfirming its identity. Match selection opens that existing item's staged editor and does not add a grocery.

Available at store first limits eligibility. Tagged (any selected), Not tagged (none selected), text, and optional category then narrow the result. Filter chips expose literal membership and can be removed individually. Reset filters changes no stored data. Archived items have their own filter, and archive/restore never changes current grocery demand. Discarding a dirty draft during archive or restore requires confirmation.

## Grocery filters and category grouping

All changes only the store selection. Reset filters clears the store, search, urgency, category and literal tag filters; neither action changes groceries. Removable chips make each additional filter visible. Include and exclude selections remain independent, so selecting the same literal tag in both produces no matches until one is removed. Any store never implies a literal store tag.

Within Must buy here/Flexible here (or All), urgency comes first, followed by the household's category order and then Uncategorized. Category management supports staged rename, exact reorder and confirmed removal. Removing a category keeps its groceries and catalog items, with their category becoming Uncategorized; it is not grocery deletion.

Rows show One-time and Urgent in words, and describe only valid active purchase choices. Any-store rows also show their explicit active tags, so literal tag filters remain understandable. Missing, archived-only or ambiguous store choices show Needs store in All. Imported ambiguous category identities group under Uncategorized consistently with the category filter.
