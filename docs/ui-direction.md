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

## Add, edit and recover a grocery

Add starts as Remember this item and Normal. Matching names appear beside the new draft: an active grocery opens its current details without mutation, and an explicit Need again renews a carted or previously cleared remembered item with its own saved purchase rules. New drafts in a store view start with that store; opening a saved grocery always uses that grocery's own rules, including an empty literal-tag set for Any store.

New remembered Save commits catalog knowledge and current demand together. Existing edits stage catalog and current-purchase fields until Save; edits follow the agreed last-update-wins behavior. One-time Save writes only the current grocery. Switching identity is a creation choice; promotion of an existing one-time grocery remains a separate explicit action. Name collision discovery uses normalized names, and a distinct-item choice applies only to that save attempt.

Remove is a separate confirmed action with Undo. Its confirmation captures the occurrence, revision and household before acting; a changed grocery is not removed by a stale confirmation. Recovery is persisted and does not create reusable knowledge for one-time groceries. Carted remembered rows offer Need again; carted one-time rows move the same occurrence back without creating a template. A saved or renewed grocery hidden by the current filters receives a Show all action after the local view observes the saved change.

## Checklist and recovery

Cart and quantity controls save immediately to the current household list. Separate 44-point minus, plus, cart and edit targets keep the visible quantity readable and avoid shared list-row button actions. At accessibility text sizes, scope controls scroll with groceries so the header cannot consume the shopping area.

Carted inherits the store, explicit tag, search, category and urgency filters shown in Groceries. Its local All carted option broadens only that recovery view. Uncart preserves urgency and offers Show all on return when the original grocery filters hide the item. Deliberate remembered Need again remains a separate action that resets urgency to Normal.

Clear carted previews the exact names, quantities, count and readable scope. Confirmation and retry keep the same captured occurrence IDs and revisions; changed rows are skipped. Cancel does not write. Clear errors remain visible inside the confirmation sheet, and Undo and Recently cleared explain when newer changes prevent restoration. One-time recovery creates no remembered catalog item.

## Explicitly remembering a one-time grocery

An existing one-time grocery stays independent until the user chooses Remember this item and confirms. Create new stages the name, category, purchase rules and separate catalog notes. Use existing shows saved catalog details for an explicitly selected item; those details are read-only. Quantity, purchase notes and urgency stay with the current grocery in either case. Successful promotion keeps its occurrence identity and carted state.

Cancel and Keep as one-time do not promote or create catalog knowledge. A matching name requires choosing the existing item or explicitly creating a distinct item. If the selected catalog item is already needed, both groceries stay intact; the user can view the existing grocery or choose another item. Carted groceries also put Urgent before Normal within their store sections.
