# Releasing Fivebars

Releases are a notarized DMG for first installs and a Sparkle update (zip plus appcast item),
all served from callingcodes.com: the Cloudflare R2 bucket `fivebars-releases` behind the site's
Worker (see the callingcodes.com repository). Flat keys: `Fivebars-<version>.zip`,
`Fivebars-<version>.dmg`, `appcast.xml`, `latest.json` (read by `/fivebars/download/latest`).

```sh
echo 2.0.1 > VERSION                       # then commit
$EDITOR release-notes/2.0.1.html           # HTML fragment shown in the update window; commit
scripts/release.sh 2.0.1                   # test, build, sign, notarize, staple, zip, DMG, appcast
scripts/release.sh 2.0.1 --publish         # same, then uploads to R2 (archives first, latest.json last)
```

`scripts/release.sh <version>` writes everything to `build/release/<version>/`: `Fivebars.app`,
`Fivebars-<version>.zip`, `Fivebars-<version>.dmg`, `appcast.xml` (the live appcast with the new item
first) and `latest.json`. Without `--publish` it prints the exact `npx wrangler r2 object put`
commands instead of running them. It stops with instructions if the Developer ID certificate, the
notary profile or the EdDSA key is missing, if the tree is dirty, if `VERSION` differs, or if the
release notes are missing.

Dry runs (never publish their output):

- `scripts/release.sh 0.9.1 --adhoc` (alias `--dry-run`): ad-hoc signed, no notarization. Works
  without any Apple credentials.
- `scripts/release.sh 0.9.1 --no-notarize`: signed with the Developer ID and the hardened runtime,
  not notarized (`spctl` says "rejected, source=Unnotarized Developer ID" until notarized).
- `scripts/release.sh 0.9.0 --test`: the full Developer ID path (notarized and stapled app and
  DMG, EdDSA-signed zip, appcast) for any version, with relaxed checks (dirty tree, other version,
  no release notes) and no upload. A rehearsal of a real release.
- `scripts/release.sh 2.0.1 --resume`: finishes a `--publish` that failed midway, without
  rebuilding. It re-checks the files in `build/release/2.0.1/`, uploads an archive only if it is
  not published yet (never over different bytes), then the appcast and `latest.json`.
- Signing uses the certificate pinned by SHA-1 in `PINNED_SHA1` (release.sh): the G2
  "Developer ID Application: Calling Code (232ZPKUQMV)", `9B2724121C10B0414AD15A3230FCE816A5B86B85`,
  valid until 2027-11-23. An older non-G2 certificate with the same name
  (`0AE0602CA8CF714F2E982BD0EEC204B7F9D50570`, expires 2027-02-01) is also in the Keychain, so the
  name alone is ambiguous. `FIVEBARS_SIGN_IDENTITY=<sha1>` overrides the hash (a name must match one
  certificate). Before building, the script refuses a certificate that is not issued by the G2 CA or
  expires within 30 days (it warns under 90). After signing, and again before any upload, the app,
  its Sparkle helpers, the zip's app, the DMG and the DMG's app must carry that leaf certificate, the
  G2 issuer, team 232ZPKUQMV, a secure timestamp and the hardened runtime; a notarized build must also
  pass `spctl` as "Notarized Developer ID" and `stapler validate`.
- `--publish` refuses `--download-base`, refuses a build that isn't newer than every build in the
  live appcast, and aborts if the live appcast can't be read (only a 404 means first release).

Dry runs chain their appcasts in `build/release/appcast.xml`, so an upgrade can be tested locally:

```sh
scripts/release.sh 0.9.0 --adhoc --download-base http://127.0.0.1:8765/0.9.0
scripts/release.sh 0.9.1 --adhoc --download-base http://127.0.0.1:8765/0.9.1
(cd build/release && python3 -m http.server 8765 --bind 127.0.0.1) &
defaults write com.callingcodes.fivebars SUFeedURL http://127.0.0.1:8765/appcast.xml
open build/release/0.9.0/Fivebars.app      # then Check for Updates… (in the menu)
defaults delete com.callingcodes.fivebars SUFeedURL   # afterwards
```

Before every public release, update the previous public build to the new one this way (with a
Developer ID build), and check that it relaunches as the new version.

## One-time setup

1. **Developer ID Application certificate** (Account Holder role), Profile Type **G2 Sub-CA**:
   developer.apple.com > Certificates > + > Developer ID Application, with a CSR from Keychain
   Access > Certificate Assistant > Request a Certificate From a Certificate Authority. Install the
   downloaded .cer, then check: `security find-identity -v -p codesigning`. A certificate under the
   previous Developer ID CA expires on 1 February 2027; signing a release after that date needs a
   G2 one.
2. **Notary credentials**, stored once in the Keychain under the profile name the script uses:
   `xcrun notarytool store-credentials fivebars-notary --apple-id <apple-id> --team-id 232ZPKUQMV --password <app-specific password>`
   (app-specific password: account.apple.com > Sign-In and Security > App-Specific Passwords).
   Check: `xcrun notarytool history --keychain-profile fivebars-notary`.
3. **Back up the Sparkle EdDSA private key.** It lives in the login Keychain (item
   "Private key for signing Sparkle updates", account `ed25519`); its public half is `SUPublicEDKey`
   in `Resources/Info.plist`. Export it to a path you choose and store it in your password manager:
   `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x <path>/fivebars-sparkle-ed25519.key`
   (restore with `generate_keys -f <file>`). If it is lost, shipped copies can never be updated
   again. Never commit it.
4. **Wrangler login** for `--publish`: `npx wrangler login`.

Sparkle is pinned exactly in `Package.swift` (2.10.0). Updating it is a deliberate change: build,
then test an update from the previous release.
