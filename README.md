# RetroCam
Layout: `project.yml` (XcodeGen spec) + `RetroCam/*.swift` + `.github/workflows/`.
The .xcodeproj is generated in CI, so it isn't committed. Locally: `brew install xcodegen && xcodegen generate`.

## Unsigned IPA (no Apple account needed)
Push to `main` (or run "Build unsigned IPA" manually) → download `RetroCam-unsigned-ipa` from the run's Artifacts.
Install by signing it yourself with AltStore, Sideloadly, or TrollStore.

## Signed IPA
Run "Build signed IPA" manually. Add these repo secrets (Settings → Secrets → Actions):
- CERT_P12_BASE64 — `base64 -i cert.p12 | pbcopy`
- CERT_PASSWORD — password of the .p12
- PROVISION_PROFILE_BASE64 — `base64 -i profile.mobileprovision | pbcopy`
- KEYCHAIN_PASSWORD — any random string
- TEAM_ID — 10-char Apple team ID
Set `BUNDLE_ID` in the workflow (and project.yml) to match your profile. For a development profile, change
`CODE_SIGN_IDENTITY` to "Apple Development".
