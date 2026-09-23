# TestFlight distribution plan

SHOPPING-94 defines the release automation before the Apple signing account is ready. It does not prove that Shopping can be signed, accepted by App Store Connect, or installed through TestFlight. SHOPPING-10 owns enrollment and signing readiness, SHOPPING-30 owns two-iPhone household-sharing proof, and SHOPPING-5 owns the validated TestFlight release.

## Rollout

The upload workflow pins Xcode 26.3 on macos-15 independently of test CI.
Apple requires Xcode 26 or later and the iOS 26 SDK or later for uploads
since April 28, 2026; the older Xcode 16.4 CI pin is not suitable for release
uploads. See [Apple's SDK requirements](https://developer.apple.com/news/upcoming-requirements/?id=04282026a).

1. Merge and statically validate the manual workflow without configuring or exposing signing material.
2. Finish Apple Developer and App Store Connect setup under SHOPPING-10. Register `com.mggarofalo.shopping`, enable the required iCloud/CloudKit capabilities, create the App Store Connect app record, and create the distribution assets below.
3. Create and protect the GitHub `testflight` environment, then add its secrets. Restrict deployments to the intended release branch and require review before the job can access secrets.
4. Dispatch one build with a new positive App Store Connect build number. The workflow validates the profile, archives the Release configuration, validates the IPA with Apple, and uploads it. Do not describe this stage as successful until App Store Connect finishes processing the build.
5. Complete production CloudKit schema and two-iPhone sharing validation under SHOPPING-30 before inviting household testers. Then finish the installation and regression evidence required by SHOPPING-5.

## Apple assets

The workflow requires:

- an Apple Distribution certificate exported with its private key as a password-protected `.p12` file;
- an App Store Connect distribution provisioning profile for `com.mggarofalo.shopping`;
- an App Store Connect API key with the minimum access needed to upload builds, including its key ID, issuer ID, and original `.p8` private key; and
- an App Store Connect app record whose bundle ID is `com.mggarofalo.shopping`.

The upload script rejects a provisioning profile for another bundle or team. It also rejects profiles containing registered device identifiers, because those are Ad Hoc rather than App Store Connect profiles.

## GitHub environment

In repository **Settings → Environments**, create an environment named `testflight`. Configure the intended release branch and a required reviewer before adding these environment secrets:

| Secret | Value |
| --- | --- |
| `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` | Base64 contents of the exported `.p12` file. |
| `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` file. |
| `APP_STORE_PROVISIONING_PROFILE_BASE64` | Base64 contents of the App Store Connect `.mobileprovision` file. |
| `APP_STORE_CONNECT_API_KEY_ID` | App Store Connect API key ID. |
| `APP_STORE_CONNECT_API_ISSUER_ID` | App Store Connect API issuer ID. |
| `APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64` | Base64 contents of the API key `.p8` file. |

On macOS, encode each file without modifying it:

```bash
base64 -i Distribution.p12 | pbcopy
base64 -i Shopping_App_Store.mobileprovision | pbcopy
base64 -i AuthKey_KEYID.p8 | pbcopy
```

Base64 is transport encoding, not encryption. Keep all six values in the protected GitHub environment; never commit them, attach them to a GitHub release, or paste them into workflow inputs or logs.

## Manual upload

After the workflow reaches the repository's default branch:

1. Open **Actions → Upload to TestFlight → Run workflow**.
2. Select the intended release branch or tag.
3. Enter a positive build number that has never been uploaded for the current marketing version.
4. Select the upload confirmation checkbox and run the workflow. The workflow
   waits for App Store Connect processing, then copies the tester groups from
   known available build 6 before reporting success. Update
   `DISTRIBUTE_FROM_BUILD` if the intended tester groups change.
   For a build that already uploaded, run the workflow with `confirm_upload`
   cleared and `verify_only` selected. This retries the distribution check
   without spending another build number.
   When a processed build is marked Missing Compliance, the check copies the
   exempt encryption classification only if known available build 6 has the
   same classification. The app also declares this classification in its
   generated Info.plist for future uploads. Any change in encryption use
   requires a fresh export-compliance review before distribution.
5. Approve the `testflight` environment deployment when GitHub requests it.
6. Confirm any required export-compliance or external beta review in App Store
   Connect. The workflow reports the internal and external beta states after
   adding the build to the same tester groups as the confirmed build.

The workflow is manual-only, grants the GitHub token read-only repository access, serializes uploads, and never cancels an upload in progress. It creates a random temporary keychain and temporary signing directory on the hosted runner. Its exit trap removes the installed profile, keychain, certificate, private key, archive, and exported IPA whether the job succeeds or fails.

## Validation without credentials

Run the static contract locally:

```bash
.github/scripts/test-testflight-workflow.sh
```

The check parses the YAML, syntax-checks the upload script, verifies the manual/environment/permission guards, verifies all secret references, and checks the validate/upload and cleanup paths. The normal Swift CI workflow runs the same check. A live archive or upload is intentionally out of scope until SHOPPING-10 is complete.
