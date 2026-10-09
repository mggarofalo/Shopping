# System actions · 1.6.0

Milk & Bananas exposes three actions: Add item, Open grocery list, and Search
catalog. The icon menu is a UIKit Home Screen Quick Action surface. Siri and
Shortcuts use App Intents. Both enter the same app-owned routing and persistence
lifecycle; neither owns another Core Data stack.

A request for navigation carries the current presentation identity when a Home
is ready. One request may wait while an editor or invitation is presented. It
never dismisses that presentation. Cancel, five-minute expiry, or a changed
Home/account retires it. An unbound cold navigation request may enter the normal
Home setup/selection flow; it is not authority to write data. System Add starts
with no store, category, urgency or text filter, preserving the separate
contextual behavior of the in-app Add button.

The shared runtime drives bootstrap loading without needing a mounted root view.
Initial UI/background requests coalesce. Store transitions continue to wait for
mounted views to retire; a cancelled intent does not tear down stores used by UI.
The existing scoped service and presentation authority remain the command fence.

Siri accepts a free-text item prompt so unknown names can reach an explicit
creation handoff. Required catalog entity resolution must not swallow that path.
Exact normalized matches outrank substring matches. Ambiguous results need a
choice; no result offers a prefilled editor after native foreground continuation.
Only an explicit save creates catalog data. If a subsequent list add fails, the
saved catalog item is retained and the partial result is explained. Existing
needs, including carted ones, are reported without silently renewing or editing
quantity, person or urgency. Reads and writes retain the captured Home/account.

No persistent Spotlight donation or remote inference is introduced. Siri speech
processing is controlled by iOS; app-qualified phrases and actual supported
language/device behavior need system-level evidence, independently of tests.

The framework distinctions and foreground handoff are documented by Apple:
[Home Screen quick actions](https://developer.apple.com/documentation/uikit/add-home-screen-quick-actions),
[App Shortcuts](https://developer.apple.com/design/human-interface-guidelines/app-shortcuts),
and [ForegroundContinuableIntent](https://developer.apple.com/documentation/appintents/foregroundcontinuableintent).
Use APIs available to iOS 17 and the pinned Xcode 16.4 compiler.

The three App Shortcuts use app-qualified phrases, such as “Add an item in
Milk & Bananas”. Add asks for an item name when none is supplied; Shortcuts can
also supply text or a remembered catalog entity. Matching folds case, diacritics,
width and whitespace. Duplicate matches present numbered native choices with
category and purchase rules. More than twenty matches requests a narrower name;
no candidate is silently chosen or truncated. Archived items, one-time needs and
unresolved catalog relationships do not become suggestions. Entity identities
include the captured local Home graph, so reimported or other-Home entities must
be selected again. No command crosses an account or Home change during dialogue.

All three intents require device authentication. Catalog reads use the existing
writer and return immutable values. The add captures catalog and need revisions
before disambiguation, then uses the existing duplicate-safe catalog-add command.
Cancellation is checked before command dispatch. Success dialogue follows the
durable save; existing needs report “already on your grocery list”. There is no
invented native grocery-list integration or unrestricted natural-language parser.
