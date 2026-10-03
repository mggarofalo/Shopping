# TestFlight distribution plan

SHOPPING-94 defines the release automation before the Apple signing account is ready. It does not prove that Shopping can be signed, accepted by App Store Connect, or installed through TestFlight. SHOPPING-10 owns enrollment and signing readiness, SHOPPING-30 owns two-iPhone household-sharing proof, and SHOPPING-5 owns the validated TestFlight release.

## Rollout

The upload workflow pins Xcode 26.3 on macos-15 independently of test CI.
Apple requires Xcode 26 or later and the iOS 26 SDK or later for uploads
since April 28, 2026; the older Xcode 16.4 CI pin is not suitable for release
uploads. See [Apple's SDK requirements](https://developer.apple.com/news/upcoming-requirements/?id=04282026a).

1. Merge and statically validate the manual workflow without configuring or exposing signing material.
2. Finish Apple Developer and App Store Connect setup under SHOPPING-10. Register `com.mggarofalo.shopping`, enable the required iCloud/CloudKit capabilities, create the App Store Connect app record, and create the distribution assets below.
3. Create and protect the GitHub `testflight` environment, then add its secrets. Restrict deployments to `main` and require review before the job can access secrets.
4. Verify the production CloudKit schema against the candidate model as described below, then dispatch one build with a new positive App Store Connect build number. The workflow validates the profile, archives the Release configuration, validates the IPA with Apple, and uploads it. Do not describe this stage as successful until App Store Connect finishes processing the build.
5. Complete production CloudKit schema and two-iPhone sharing validation under SHOPPING-30 before inviting household testers. Then finish the installation and regression evidence required by SHOPPING-5.

## CloudKit release prerequisite

Before distributing a build that changes the managed model, initialize the
**Development** schema from that candidate’s compiled `Shopping.momd` using
`NSPersistentCloudKitContainer.initializeCloudKitSchema(options:)`. Use a signed
development tool with a fresh, disposable local store and the existing container
`iCloud.com.mggarofalo.shopping`; never point the initializer at a shopper’s data
or reset a CloudKit environment. Apple’s initializer creates and removes its own
representative records to define every model field.

In CloudKit Console, review **Deploy Schema Changes** and deploy the required
additions to **Production** before inviting testers. Verify the resulting
production record types and deployment history. Signing entitlements, a valid
archive, and App Store Connect processing do not verify this prerequisite.
Record the source SHA, model version, schema deployment timestamp, and observed
upload/download results in the release issue. A device upload is not evidence
of another device receiving it; SHOPPING-30 and SHOPPING-122 retain their live
two-account and phone-independent Watch validation gates.

SHOPPING-133 found an empty production schema after build 13 had been delivered.
The corrective initialization used build 13’s exact archived model from source
`bcd8ba3fa2f88d4b6f408365f01ad8148c838f09`, without changing user records. The
production deployment was confirmed in CloudKit Console at 4:43 PM EDT on
September 24, 2026. The managed schema contains `CDMR` plus Category, ClearOperation, GroceryList,
Household, HouseholdCartRecord, Item, LegacyCartReview, Need, Person,
PersonalCartRecord, and Store record types (with the `CD_` prefix). Confirm both
fields and indexes on future model changes; matching type names alone is not
sufficient.

Sharing also requires the built-in `cloudkit.share` record type in Production,
even when the Core Data model is unchanged. Before a first sharing release or a
sharing-provisioning change, verify that type separately. Core Data model-schema
initialization does not prove that a share was created. If it is missing, create
a private zone share in a fresh disposable Development zone using a correctly
signed Development tool, review the resulting schema diff, deploy it, and delete
only that disposable zone. Never initialize against a shopper's stores or reset
an environment. On September 30, build 20's native export failed because this
type was absent; its deployment at 8:45 PM EDT cleared that rejection and allowed
the owner to create a Contributor invitation. The exported Production schema
and observed device result are recorded under SHOPPING-10.

## Apple assets

The workflow requires:

- an Apple Distribution certificate exported with its private key as a password-protected `.p12` file;
- separate App Store Connect distribution provisioning profiles for `com.mggarofalo.shopping` and `com.mggarofalo.shopping.watchkitapp`, both granting production push, the existing CloudKit container, and `InProcessOneTimeLinks` sharing;
- an App Store Connect API key with the minimum access needed to upload builds, including its key ID, issuer ID, and original `.p8` private key; and
- an App Store Connect app record whose bundle ID is `com.mggarofalo.shopping`.

The upload script validates both profiles against the established team `649367BDD4`, their exact bundle IDs, expiration, App Store distribution shape, required capabilities, and a shared valid certificate imported from the protected `.p12`. It binds the profiles per target and includes both bundle IDs in the manual export mapping. The signed export must match the intended version/build and clean source SHA before Apple validation/upload.

## GitHub environment

In repository **Settings → Environments**, create an environment named `testflight`. Configure the intended release branch and a required reviewer before adding these environment secrets:

| Secret | Value |
| --- | --- |
| `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` | Base64 contents of the exported `.p12` file. |
| `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` file. |
| `APP_STORE_PROVISIONING_PROFILE_BASE64` | Base64 contents of the capability-correct iPhone App Store Connect `.mobileprovision` file. |
| `APP_STORE_WATCH_PROVISIONING_PROFILE_BASE64` | Base64 contents of the capability-correct Watch App Store Connect `.mobileprovision` file. |
| `APP_STORE_CONNECT_API_KEY_ID` | App Store Connect API key ID. |
| `APP_STORE_CONNECT_API_ISSUER_ID` | App Store Connect API issuer ID. |
| `APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64` | Base64 contents of the API key `.p8` file. |

On macOS, encode each file without modifying it:

```bash
base64 -i Distribution.p12 | pbcopy
base64 -i Shopping_App_Store.mobileprovision | pbcopy
base64 -i AuthKey_KEYID.p8 | pbcopy
```

Base64 is transport encoding, not encryption. Keep all seven values in the protected GitHub environment; never commit them, attach them to a GitHub release, or paste them into workflow inputs or logs.

## Manual upload

SHOPPING-132 adds separate profile validation, target-specific archive settings,
and a two-bundle export mapping. The old iPhone secret must be replaced with a
capability-correct profile and the Watch profile secret must be configured before
using the hosted upload. Generating new credentials, changing protected secrets
or access, or accepting a new Apple agreement requires explicit approval. Local
fixtures and local signing compatibility do not prove hosted signing. Retain the
fallback until an approved hosted archive/export succeeds with these assets.

After the workflow reaches `main`:

1. Open **Actions → Upload to TestFlight → Run workflow** and select `main`.
   Select exactly one of `preflight_only`, `confirm_upload`, or `verify_only`.
   All modes use the protected `testflight` environment and are serialized.
2. For `preflight_only`, leave the build number blank to inspect the inventory
   and select the next integer greater than all existing iOS build numbers, or
   enter a number to check that the marketing-version/build pair is unused.
   This mode uses only App Store Connect GET requests and receives no signing
   secrets. It checks the existing Garofalo Home audience against baseline
   build 6. It does not reserve a build number or distribute anything.
3. For `confirm_upload`, source marketing versions must match across all four
   iPhone/Watch configurations. Leave the build number blank to allocate it
   inside the serialized upload job, or enter an explicit unused number. The
   latest push-to-main Swift CI run for the exact dispatched SHA must have
   successful **Release SDK Build** and **Build & Test** jobs. The upload job
   uses GitHub `actions: read` only to inspect those results; this proposed
   permission addition must be approved before deployment. A failing or pending
   newer run cannot be replaced by an older success.
4. Approve the protected environment when requested. The script validates both
   profiles and their certificate, archives, exports, checks signed capabilities
   and metadata, and asks Apple to validate the IPA. It repeats the GET-only
   unused-pair check immediately before the single upload. Other upload clients
   are outside this workflow's lock, so the check is not a reservation. Diagnose
   any upload error before retrying; never blindly upload again after a timeout.
5. For an already uploaded build, use `verify_only` with its explicit number.
   The optional `marketing_version` defaults to the checked-out source version;
   specify it when verifying an older release. Verification looks up the exact
   iOS marketing-version/build pair, waits for `VALID` processing, and verifies
   membership and availability in **Garofalo Home**. It assigns only that
   existing group when needed, never creates groups or invites testers. A source
   build 6 group mismatch or ambiguous source version fails before mutation.
   A future baseline change must be reviewed; `DISTRIBUTE_FROM_VERSION` can
   disambiguate that baseline without changing the audience.
6. If Missing Compliance is reported, the script copies exempt encryption only
   from the confirmed exempt baseline. Changes in encryption use require review.
   The workflow reports internal and external beta states. Group assignment alone
   is insufficient: testers must have a ready beta state. External beta review
   and production App Store submission are not automated here. Retry verify-only
   if processing or group availability is slow, without another upload.

The exit trap removes newly installed profiles and all temporary key/certificate,
keychain, archive and export files on success or failure, restores the original
keychain search list, preserves identical pre-existing profiles, and refuses to
overwrite conflicting profiles. Signing secrets are available only to the
protected upload step; the API key is also used by protected preflight/verification.

## Local automatic-signing fallback

While SHOPPING-132 is open, use a clean detached worktree at the exact merged
`main` SHA. Do not archive from a root checkout with unrelated local edits.
With the intended Apple team signed in to Xcode, archive the Release scheme for
`generic/platform=iOS` using `-allowProvisioningUpdates`,
`DEVELOPMENT_TEAM=649367BDD4`, `CODE_SIGN_STYLE=Automatic`, and the chosen
`CURRENT_PROJECT_VERSION`. Export with method `app-store-connect`, automatic
signing, the same team, `manageAppVersionAndBuildNumber=false`, and destination
`export`. Before upload, inspect the exported IPA, not just the archive:

- The iPhone and embedded Watch bundles have the same intended marketing
  version and build number.
- Both signed bundles have Production CloudKit and production push entitlements.
- For the household-sharing release, **both** apps' signed entitlements include
  `com.apple.developer.icloud-extended-share-access = [InProcessOneTimeLinks]`.
  Each app's provisioning profile must grant that access. The Watch needs it
  for Core Data's automatic share-metadata saves, even though the iPhone creates
  invitations. SHOPPING-168 captured a locally rejected Watch private export
  with CloudKit code 12 when the Watch lacked this entitlement.
  Verify the exported package with
  `python3 .github/scripts/validate-cloudkit-sharing.py --ipa /path/to/Shopping.ipa`.
  This checks every application target/configuration in the project, then every
  exported app and its provisioning profile. The hosted upload runs it before
  Apple validation; the local signing fallback must run it before upload too.
  Prove a saved-share link and Watch private-cart delivery work on the supported
  physical devices; unsigned simulator tests are insufficient.
- `BuildCommit.txt` in the iPhone bundle equals the clean `main` SHA.

Use the same export options with destination `upload` to submit through Xcode.
Wait for the explicit upload-complete response. That response means the package
is processing, not yet available to testers. Dispatch the repository's
`verify_only=true` workflow on the same source SHA and build number; approve
its protected environment, then wait for processing and tester-group
assignment. If processing is slow or verification fails, retry verify-only
without another upload. Record the local archive/export/upload evidence and the
verify-only workflow URL in the release issue. This fallback does not validate
or repair the hosted archive path.

## Validation without credentials

Run the static contract locally:

```bash
.github/scripts/test-testflight-workflow.sh
```

The check executes the release-mode truth table and tests profile capabilities, expiry and certificate compatibility, exact version/build collision detection, GET-only preflight and pagination, required exact-source CI jobs, approved audience and tester availability, exported metadata, and shell cleanup after signing/archive failure. Existing build-identity and source-sharing checks remain included. Normal Swift CI runs the same checks. Fixture tests do not prove authenticated App Store Connect behavior, protected secret correctness, or hosted signing; an approved hosted archive and subsequent real release remain separate evidence.

## Build identity

SHOPPING-98 uses the exact checked-out Git SHA as the build identifier. Every
Xcode build writes the full SHA to `BuildCommit.txt` in the app bundle; Settings
shows the marketing version and the first 8 SHA characters. Local builds with
uncommitted changes append `-dirty`. Missing or invalid metadata displays an
unknown commit, never the integer build number. Builds require a Git checkout.
The build phase runs on incremental builds too, including after a commit change.

TestFlight uploads are restricted to a clean `main` checkout. On GitHub Actions,
the checked-out SHA must equal the dispatched `main` SHA, even if `main` moves
while the run is queued. Workflow runs identify releases by that SHA.
`CFBundleVersion` remains a positive numeric upload value for Apple distribution;
it is not the app's source identifier. Continue choosing an unused upload number.
