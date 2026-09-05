# Preview fixtures and local context simulations

`ShoppingPreviewFixtures` creates isolated sample data for previews and tests. Its default store is in memory. Disk-backed fixture tests use a new temporary SQLite location; an existing database must never be seeded with preview groceries. Callers own a unique temporary URL per fixture; the existing-file check catches sequential reuse and is not a lock for concurrent creators. The production bootstrap does not call this factory.

`ShoppingPreviewHost` supplies the same managed-object context, command service and household/list selection environment as the app. Use it around a view's `#Preview` rather than opening the application's normal store. Cases cover empty and populated lists, long names, accessibility text sizes, store archival and a remembered need whose catalog relationship has not arrived.

The populated fixture includes Any-store bananas, Costco-only granola and strawberries, Publix chipotles, Costco/Walmart dinner rolls, a Needs store item, urgent needs, carted groceries and recoverable one-time groceries. One-time rows remain independent from the catalog. The archived-store case preserves the original tags so All can show needs that no longer have an active shopping destination.

`LocalTwoContextHarness` provides two independent Core Data contexts over an isolated SQLite store. Tests stage both edits before choosing a save order; automatic context merging is disabled and registered objects are retained so stale-state behavior is intentional. This is a local persistence simulation. It does not simulate network delivery, share permissions or CloudKit's scheduler, and it cannot establish two-account convergence.

Use these fixtures for filter, form, recovery, long-text and empty-state work. Real owner/participant sharing, offline reconciliation and remote clear races still require SHOPPING-30 on the two iPhones.
