# Cloud application testing

Local tests must establish application behavior under the service contract. Live
CloudKit setup is not an explanation for missing application coverage. Build 29
failed before a service write because our sharing validator rejected valid
physical replicas. A correctly configured live service could not repair that
application decision.

## Test boundaries

| Layer | What remains real | What is controlled |
| --- | --- | --- |
| Unit contracts | Reducers, validation, state transitions, account cache rules, status rules | Explicit inputs, causal evidence and external observations |
| Mock contracts | The reusable fake's state and operation semantics | Record identity, expected versions, pending/accepted membership, link availability, errors and lost completion |
| Application integration | Core Data stores, services, graph validation, native-facing application transports, coordinators, journals and presentation decisions | External sharing operations, account lookup and delivery order |
| Release configuration | Signed exported phone/Watch apps and production service configuration | Exact source/build, established tester audience and reviewed schema changes |

The integration path must use production composition. `HomeInvitationWorkflow`
is called by both the app's Invite action and the sharing fixture. The fixture
does not create a successful delivery or membership snapshot in place of the
application. `HomeSharingBackend` exposes observed service facts and external
operations; graph, account, authority and recovery policy stay in application
code. The native backend retains managed Core Data sharing APIs.

## Coverage ownership

- `HomeSharingBackendContractTests` checks the stateful sharing fake itself.
  `HomeSharingApplicationContractTests` crosses stored graph validation,
  provisioning, membership, journals and Home Details state. Existing native
  participant archive tests remain responsible for the SDK value contract.
- `PersonalCartReducerContractTests` checks causal input/output rules.
  `ReplicaApplicationContractTests` crosses independent SQLite stores, import
  ordering, cart and grocery services, checkout/undo, restrictions and recovery.
- `AccountCloudApplicationContractTests` checks overlapping account observations,
  cache scoping, provider-to-service authorization, persisted permission changes
  and cloud status observations alongside real local saves/history consumption.
- Existing invitation inbox/controller/bootstrap tests own acceptance, discovery,
  home activation and navigation fencing. The reopened accepted-link regression
  adds actual bootstrap activation after persisted resolution and relaunch.

The issue records in `docs/testing/shopping-198-contracts.md`,
`shopping-199-contracts.md` and `shopping-200-contracts.md` identify exact methods,
fixtures, revisions, failures and results. The central test ownership ledger
records integration evidence.

## Rules for trustworthy mocks

A fake must retain meaningful service behavior. It must not deduplicate by an
application event ID when two distinct physical records can carry that ID, erase
conflicts, authorize another account, or return success merely because an app
asked for it. Repeated delivery of the same physical record and independent
physical replicas of one logical event are separate cases.

Use one isolated fixture per test, real durable journals for relaunch, explicit
controlled suspension for ordering, and terminal cleanup for every background
worker. Check resulting data and state as well as external write counts. Keep
unit and integration proof complementary; a passing component test does not
establish that its callers and dependencies are connected correctly.

For a reported application defect, preserve a synthetic representation of the
failure and show that restoring the defect makes its regression test fail. Run
these deterministic contracts in Fast on every PR. Native UI tests retain the
interaction proof that service tests cannot provide. Live release checks then
cover configuration and actual service interoperability, using the exact
candidate; they do not substitute for local application tests.
