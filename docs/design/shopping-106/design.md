# SHOPPING-106: compact category rhythm

Review [the before/after prototype](review.html), [All stores](proposed-all.png), and [Costco](proposed-costco.png). These are proposed layouts, not screenshots of an implemented change. Production views are unchanged. The issue has no blocking relations.

The current screenshots show six items spread across four categories. The last item’s note is obscured by the floating tab bar. Category headers consume more space than their single-item groups need, while person and note metadata add uneven-looking rows. Keep the existing white canvas, green actions and native navigation; spend the density gain on reducing section scaffolding.

## Measurements and hierarchy

All measurements are logical points at the default text size on the same 402 × 874 pt iPhone 17 Pro viewport (1206 × 2622 px at 3×).

| Element | Proposed treatment |
| --- | --- |
| Horizontal alignment | Category labels, item titles and notes share the existing 16 pt leading margin. Person and one-time labels start after their symbols. Quantity controls retain trailing alignment. |
| Category header | 13 pt semibold semantic caption, secondary foreground. A 28 pt band: 8 pt above, 16 pt line, 4 pt below. No uppercase transformation. |
| Ordinary item | 17 pt semantic body; 44 pt minimum content/touch height plus 2 pt top and bottom list insets = 48 pt row. |
| Metadata item | Content grows naturally. A title + person + note or title + one-time + note targets 70 pt at default size; never a fixed height. About 6 pt outer breathing room and 2 pt gaps between text lines. |
| Metadata | Existing 12 pt semantic caption and secondary color. Person icon + name occupy their own line; note follows, aligned with the item title. One-time identity stays explicit. No badge background. |
| Urgency | Existing orange exclamation circle immediately after the title; accessible “Urgent” value remains. |
| Quantity and store symbols | Center the controls on the item title line, including tall metadata rows. Keep separate minus/plus buttons at least 44 × 44 pt, with a monospaced value. Minimum-one and maximum-99 behavior stays intact. |
| Scope bar | Existing All, store chooser and Filters controls, icons and hit areas. Remove the rules above and below; keep its existing position. |

Category bands and title rows provide the grouping boundary. Remove section edge separators and the rules around the scope row. Keep only subtle separators **between siblings within a category**: two in the all-store Pantry section, none in the three single-item Costco categories. Do not insert a rule after the final item. The prototype uses a 0.5 pt `#E5E5E8` line; implementation should prefer the adaptive system separator.

The specimen uses white `#FFFFFF`, primary `#111111`, secondary `#626266`, green `#195B45`, urgent `#A93610`, and separator `#E5E5E8`. These approximate existing semantic colors in light appearance. Keep the app’s adaptive colors in SwiftUI. System typography matches the product’s iOS controls; a new display font or decorative cards would compete with the shopping task.

## Same viewport comparison

| Scenario | Current capture | Proposed layout |
| --- | --- | --- |
| All stores, person + note | Five complete items; Birthday candles begins but its note reaches under the tab bar. | Six complete items and every metadata line fit. Content ends at y=676 pt, about 116 pt above the tab bar’s y≈792 pt leading edge. |
| Costco | Three items in three categories; Dinner rolls row ends at y≈571 pt. | Three complete items end at y=482 pt, even with Michael added to Granola to exercise person + note. |

The all-store content budget is 444 pt: four 28 pt category bands + four 48 pt ordinary rows + two 70 pt metadata rows. It starts at y=232 pt. A hypothetical additional plain row in an existing category would consume 48 pt, but six fully visible items is the demonstrated result. Numbers are prototype geometry, not a guarantee across native OS versions, long names or large text.

## Accessibility and larger text

Use semantic fonts and minimum heights; do not set fixed text or row heights or shrink text to fit. Category headers remain accessibility headings. Titles, person, notes, one-time identity and urgent status remain exposed in the row’s combined accessibility description. Retain explicit quantity labels and cart/remove accessibility actions.

At accessibility Dynamic Type sizes, retain the existing `GroceryNeedRow` vertical layout: details take the full width, with the quantity cluster on its own trailing row and 8 pt separation. The person and note stay distinct wrapping lines. Allow title, metadata and headers to wrap, including localized and long person names. Each interactive target remains at least 44 × 44 pt. More scrolling is expected; fitting six rows is a default-size target, never a reason to clip or reduce text. Keep the existing accessibility bottom scroll inset so the final item can clear the floating tab bar.

Validate default, XXXL and an accessibility size with long names/notes and both quantity and store symbol present. Check VoiceOver reading order, edit versus quantity activation, swipe actions, dark mode and increased contrast. The browser mockup demonstrates visual spacing only; it does not prove native accessibility behavior.

## Implementation proposal after review

1. In `GroceriesView`, retain the native plain `List`, `Section`, search, scope controls and swipe behavior. Hide scope-row separators and section-edge separators. Give grocery category headers explicit semantic styling and a compact spacing target. Start with native `listSectionSpacing` and `defaultMinListHeaderHeight`; confirm how the plain style renders on iOS 17 and the current simulator before settling the exact composition. Do not replace `List` with a custom scrolling/gesture implementation just to force pixel parity.
2. In `GroceryNeedRow`, change the details stack spacing from 4 to 2 pt and establish consistent intrinsic vertical padding for metadata, keeping 44 pt minimum edit and quantity targets. Preserve separate person and note lines, wrapping and the current accessibility-size vertical layout. Ordinary row insets already total 4 pt in `ShoppingListStyle`; do not globally reduce them for Catalog/Settings.
3. Apply within-category separator visibility at the grocery row call site. If `ItemCollectionSections` needs a styling hook, default it to existing behavior so other lists remain unchanged. Category projection and sorting are untouched; groups still use Settings order. Store scope remains Any store OR eligible explicit restriction; urgency never broadens it.
4. Keep `lock.fill` for Only buy here and `checkmark.circle` for Can buy here; use existing accessible text, without repeated purchase-rule labels. SHOPPING-102’s potential symbol change is separate. Archived restrictions and unresolved identities retain existing behavior.
5. Add representative previews and UI checks for the same six-item fixture and selected-store sparse groups. Confirm quantities, editing, carting and full-note visibility. Native measurements and accessibility validation belong to implementation, after design review.

Apple’s [listSectionSpacing documentation](https://developer.apple.com/documentation/swiftui/view/listsectionspacing(_:)) describes spacing between native List sections and lists iOS 17 availability; it is the first native control to evaluate. The [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility) informs the adaptation checks.

## Artifacts and reproduction

`baseline-*.png` are preserved simulator evidence. `build-prototype.py` generates two self-contained SVGs with native chrome embedded from those captures. `proposed-*.png` are browser renders at 1206 × 2622 px; `review.html` switches between all-store and Costco comparisons without a build step or network dependency. The PNGs were inspected visually. The design covers the issue’s prototype acceptance criteria; no production behavior or sharing claim is changed.
