---
name: shopping-release
description: Prepare and verify Shopping iPhone and Watch TestFlight releases, including marketing-version decisions, build numbers, exact-source validation, and tester distribution.
---

# Shopping release

Use this for a requested Shopping version bump or TestFlight build. Read [the TestFlight plan](../../../docs/testflight.md) for the current upload workflow, signing and CloudKit prerequisites. Follow the issue, worktree, milestone PR, CI, and approval rules in [AGENTS.md](../../../AGENTS.md).

## Choose the version

- **Patch** (`1.2.0` → `1.2.1`): fixes, performance work, and UI corrections that preserve existing product capabilities and saved-data meaning.
- **Minor** (`1.2.x` → `1.3.0`): a new user-facing capability or a meaningful workflow change while existing data and clients remain compatible. A Core Data model change can occur in either kind of release; inspect the actual compatibility and CloudKit schema impact instead of deciding from the version number alone.
- For an incompatible data or sharing change, establish a migration and rollout plan before choosing a major version. Do not use a version bump as a substitute for migration proof.

Record the reason in the release issue. Change `MARKETING_VERSION` together for the iPhone app and Watch app, in Debug and Release configurations. Confirm all four values match. The upload workflow overrides `CURRENT_PROJECT_VERSION` with its `build_number` input; choose a positive number unused in App Store Connect for this marketing version. Prefer a number greater than every previous Shopping upload so runs remain easy to compare. Check the latest processed build and recent workflow runs before dispatch. The protected `preflight_only=true` mode can read App Store Connect inventory and check an explicit unused version/build pair; with a blank number it selects the next number across existing iOS builds. It uses GET requests only and does not reserve the number.

## Release the exact source

1. Review the candidate diff, including the managed Core Data model. If the model changed, complete the Development-to-Production schema check in the TestFlight plan before upload. An unchanged model needs no new model-schema deployment. For a first sharing release or changed share provisioning, separately verify the built-in `cloudkit.share` type exists in Production; model initialization and signed entitlements do not prove it. Follow the TestFlight plan for an isolated Development share and reviewed deployment if missing.
2. Merge the version change through the repository workflow. Confirm the `main` SHA and its required CI results. Run `.github/scripts/test-testflight-workflow.sh` if the upload workflow or scripts changed.
3. Choose the upload route using the current state of SHOPPING-132. The hosted archive needs separate, capability-correct App Store profiles for the iPhone and Watch bundle IDs, applied per target. Until that issue has live archive proof, use the [local automatic-signing fallback](../../../docs/testflight.md#local-automatic-signing-fallback). A failed hosted archive before upload leaves the build number unused; check the log before retrying.
4. For a working hosted route, dispatch `.github/workflows/testflight.yml` on `main` with only `confirm_upload=true`. Enter the chosen unused build number or leave it blank for allocation within the serialized upload job. The latest exact-source push-to-main CI and both required jobs must pass. The workflow rechecks the unused pair immediately before uploading. Verify the run's source SHA equals the intended `main` SHA. Do not dispatch a second upload merely because processing is slow.
5. Approve the protected `testflight` environment when requested, then wait for archive, validation, upload, App Store Connect processing, and tester-group assignment. After a local upload, use the workflow's `verify_only=true` path for processing and distribution. If upload succeeded but distribution verification failed, retry that path with the same build number and marketing version rather than uploading a duplicate. Verification defaults to the checked-out marketing version; supply `marketing_version` for an older release. It verifies only the approved existing Garofalo Home group and fails if the baseline audience differs.
6. Record the marketing version, build number, source SHA, workflow URL, processing result, tester-group assignment, and internal/external beta states in the release issue. State any external review still pending. Tag `v<marketing-version>` at the released source commit after successful processing if that tag does not already exist.

A workflow dispatch, successful archive, or upload command alone is not a completed TestFlight release. Do not claim CloudKit convergence or physical-device responsiveness from the upload; those need their own device evidence.
