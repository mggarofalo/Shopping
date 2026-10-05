# SHOPPING-198 sharing contract evidence

Build 29 rejected valid physical replicas of a household event before native Invite.
The existing validator regression established the local rule, while provisioning,
membership and Home Details doubles supplied results above the persisted graph boundary.
This issue adds proof across those boundaries without contacting a CloudKit account.

## Fixture boundary

Each application contract gets a unique SQLite directory. A relaunch closes the contexts
and persistent stores, then reopens the same SQLite file and recovery journals without
reseeding. The fixture uses production graph validation, share provisioning, membership
coordination, journal encoding and Home Details presentation decisions. Only account
lookup and the external sharing backend are replaced.

The stateful backend owns object-to-share associations, persisted share versions,
participant material, membership and link availability. It derives responses from this
state and checks mutation preconditions. A configured lost completion applies the write
before returning an error; an unavailable link changes only link delivery. These are
external boundary conditions, not precomputed application outcomes.

## Retained proof owners

| Existing owner | Retained proof |
| --- | --- |
| `HomeShareGraphTests` | Reachability, archived/one-time data, private graph exclusion and domain identity rules. |
| `HomeShareProvisionerTests` | Provisioning journal scope, replay and concurrent waiter policy. |
| `HomeMembershipCoordinatorTests` | Invitation/removal serialization, acknowledgement and journal recovery permutations. |
| `ManagedHomeMembershipTransportTests` | Native one-time participant factory and secure archive contract on a supported runtime. |
| `HomeDetailsModelTests` | Presentation affordances, retired results and error/recovery wording. |
| `HomeDetailsUITests` | Native sharing presentation, pending-member workflow and accessibility. |
| `HomeInvitationAcceptanceTests` / `HomeInvitationControllerTests` | Incoming acceptance, causal recovery and explicit navigation fences. |

## Validation

A provisional focused sharing selection passed 14 tests on October 5, 2026 with Xcode 27.0 and
an iPhone 17 Pro iOS 26.5 simulator. Command: the documented ShoppingFast command plus
`-only-testing:ShoppingPersistenceTests/HomeSharingApplicationContractTests` and
`-only-testing:ShoppingPersistenceTests/HomeSharingBackendContractTests`.
A handoff overlapped another agent’s test startup near the end of this run. Final
source proof therefore comes from the subsequent serialized validation, rather than
this provisional run. Evidence: `/tmp/shopping-198-sharing-focused-3.log` and
`/tmp/shopping-198-sharing-focused-3.xcresult` (exit 0).

The first run failed compilation in new tests (availability annotation and erased fetch
request result type). The second run passed 11 of 13, exposing two overstrict test
expectations: a shared-membership refresh can retain an empty invitation journal, and
retired presentation authority uses the existing generic action error. Both expectations
were corrected without changing product behavior. Those artifacts are retained as
`/tmp/shopping-198-sharing-focused-1.*` and `-2.*`.

| Application contract method | Boundary proved |
| --- | --- |
| `testOwnerInviteTraversesPersistedEquivalentReplicasBeforePresentingDelivery` | Actual SQLite replicas → graph validation → managed transport → provisioning → membership → journal → Home Details delivery. |
| `testGraphMutationAtCreateBoundaryIsValidatedBeforeExternalSubmission` | Graph changes after initial lookup are revalidated on the submission context before any external create. |
| `testInvalidDomainIdentityStopsInviteBeforeExternalWriteOrJournal` | Conflicting Category identities block writes before any preparation or invitation intent. |
| `testAssociatedPrivateRecordStopsNewInvitationAndRetainsPrivateData` | A private cart record associated with a share blocks Invite while retaining the record. |
| `testUnavailableLinkPendingStateSurvivesOfflineSQLiteReopenAndRecoversSameInvitation` | Link delivery failure and offline refresh retain a real journal; reopening recovers the same participant with no write. |
| `testLostSaveCompletionRecoversAppliedMembershipWithoutDuplicateWriteAfterReopen` | Applied membership with lost completion is reconciled and replayed without another add. |
| `testOfflinePreparationAfterReopenRequiresExplicitSameRootRetry` | Offline preparation retains its intent; after reopening, only an explicit retry submits the same root. |
| `testLostCreateCompletionRecoversManagedAssociationBeforeMembershipWrite` | Applied root share with lost completion is discovered before membership submission. |
| `testUnobservedSaveOutcomeRemainsSubmittedAfterReopenWithoutAnotherWrite` | Unobserved application never authorizes duplicate membership submission. |
| `testAcceptedMembershipRetiresPendingJournalAndAllowsDistinctNextInvitation` | Server acceptance retires outgoing recovery and allows a fresh participant. |
| `testAuthorityRetirementAtSubmissionBoundaryPreventsWriteAndKeepsPreparedIntent` | Retiring the screen at external submission prevents writes. |
| `testAccountInvalidationAtSubmissionBoundaryPreventsWriteAndKeepsPreparedIntent` | Invalidating the account at external submission prevents writes. |
| `testPermissionLossWithholdsInviteAndCannotSubmitAgainstEarlierSnapshot` | Fresh permission loss rejects an earlier owner snapshot before submission. |

The backend contract methods own create/association state, version conflicts, lost
completion semantics, offline read isolation, link readiness and acceptance behavior.
They exercise the same reusable fake used by application tests.

All 16 sharing tests passed in the final serial run against production
refactor `19623ee`. The combined 17-test command also selected the new incoming-link
bootstrap regression, which failed; the complete run therefore exited 65. Artifacts:
`/tmp/shopping-198-sharing-focused-final2.log` and
`/tmp/shopping-198-sharing-focused-final2.xcresult`; source revision, dirty state and
SHA-256 inputs are in `/tmp/shopping-198-sharing-final2-source.txt`. The incoming
regression is being diagnosed independently and is not claimed as passing evidence.
The preceding combined run likewise passed 16 sharing tests and failed that incoming
case (`/tmp/shopping-198-sharing-focused-final.*`). No native backend warnings remain
in the final run; inherited warnings elsewhere are unchanged.

The new create-boundary test exposed an implementation gap during review: validating
in one context and resolving the root in a second context allowed newly saved graph
changes to escape validation. The backend now invokes the production validation
callback on its submission context immediately before SDK submission. Its fake invokes
the same callback on a real fixture context.

### Mutation experiment

The exact method `testOwnerInviteTraversesPersistedEquivalentReplicasBeforePresentingDelivery`
passed with the fix, failed when only the validator's event exception was removed, then
passed again after byte-for-byte restoration of the validator. The mutated run executed
one test with one failure (missing `HomeInvitationDelivery`) and exited 65. The restored
run executed one test and exited 0. This demonstrates that the assembled path detects
the build-29 defect before native Invite.

Evidence: `/tmp/shopping-198-sharing-mutation.log` / `.xcresult` and
`/tmp/shopping-198-sharing-restored.log` / `.xcresult`; validator digests are in
`/tmp/shopping-198-sharing-mutation-source.txt` and
`/tmp/shopping-198-sharing-restored-source.txt`. The mutated runner finished its test
but stalled collecting simulator diagnostics. After samples confirmed the wait and
no test runner remained active, only its `simctl diagnose` child was terminated after
3 minutes 11 seconds. Xcode then finalized the result with the expected exit 65. This
infrastructure cleanup did not change the assertion or turn the run into a success;
samples are retained as `/tmp/shopping-198-mutation-*-sample.txt`.

The production refactor and tests are separate commits. Repository Fast, representative
UI and exact-source CI remain the integration workflow's required gates.

These simulations do not establish CloudKit schema readiness, real managed association
delivery, cross-account acceptance, revocation convergence or two-phone sharing.
SHOPPING-10 and SHOPPING-30 retain those live proof obligations.

## Accepted-link integration follow-up

The new bootstrap regression exercised durable accepted-link ingress after cold
reconstruction, a newer explicit home choice during held verification, and another
fresh ingress that should open without repeating acceptance. Initial runs failed
before verification. A fresh same-account provider corrected the cold-process
fixture but did not resolve that failure.

Tracing found that value ingress publishes its renewed entry before clearing the
pending-choice fence. Automatic Open scheduled too early and remembered its own
busy rejection. The scheduler now waits for that selected entry's choice change
to finish, preserving the latest requested invitation. Native scene ingress clears
its fence synchronously; the value-ingress failure alone does not establish an
identical native scene race.

With that guard, the test reached verification and exposed a second application
gap: reaffirming the selected home skipped automatic-Open deferral, and the held
Open could override it. Every explicit home selection now defers pending automatic
Opens before completing. The completion observer also requires ingress to finish,
so an old resolved snapshot cannot satisfy the new Open assertion.

`/tmp/shopping-198-ingress-fix.log` and `.xcresult` retain the intermediate four
failures. The complete regression then passed once, exit 0, with no failures or
skips in `/tmp/shopping-198-ingress-fix2.log` and `.xcresult` (0.245 seconds test
execution). Both runs used `125a3e0` plus the explicitly dirty bootstrap/test/doc
changes captured in the corresponding `-source.json` files. Two independent
production reviewers verified both fixes without additional findings. Clean
integrated source validation follows in the central ownership ledger.
