# Appearance and swipe update

SHOPPING-51 moves Catalog filters into the grouped scrolling list. A 12-point
section gap separates filters from item cards, with adaptive grouped surfaces
in light and dark mode. Filters scroll away at accessibility text sizes so
rows have room to become fully visible. Empty-state actions scroll too.

SHOPPING-52 adds a Remove swipe action to Groceries and In cart. The existing
cart/uncart action remains first and retains full-swipe behavior. Remove asks
for confirmation and uses the captured occurrence, revision, household and
list. Undo and Recently cleared restore the same occurrence; catalog data and
newer changes remain protected.

Catalog offers Archive and Restore swipe actions with confirmation.
Archiving hides the remembered item without removing current groceries or
saved purchase details. The Archived items filter exposes restoration.

The appearance checks capture Groceries, Catalog, Settings, and grocery and
catalog editors/filters in light and dark mode at standard and accessibility
XXXL text sizes. Focused swipe checks cover confirmation cancellation,
immediate Undo, durable relaunch recovery, catalog restoration, and the
existing full-swipe cart behavior.
