# Release & notarisation workflow

This document covers a full **build → sign → notarise → staple → publish** flow
for the signed branch (`feature/ario-signed`), driven by
[`scripts/release.sh`](../scripts/release.sh).

If you've never notarised a macOS app before, the one-time setup section
below will take about 15 minutes. Each subsequent release is then a single
command.

---

## What is notarisation, and why?

Since macOS 10.15, every developer-distributed app needs to be **notarised**
or Gatekeeper will block first-launch with "Apple could not verify […] is
free of malware". Notarisation = you upload your signed app to Apple, their
service scans it for known malware, and emits a **notary ticket**. You then
**staple** that ticket to the app so it works offline.

You need three things:

1. A paid **Apple Developer Program** membership ($99/year).
2. A **Developer ID Application** certificate (download/install into your
   login keychain).
3. An **app-specific password** for `notarytool` — your main Apple ID
   password is *not* accepted by the API.

---

## One-time setup (do this once on your build machine)

### 1. Install the Developer ID Application certificate

If you don't already have one:

1. Open Xcode → *Settings → Accounts → Manage Certificates…* → `+` →
   **Developer ID Application**.
2. Xcode generates the cert and installs it in your login keychain.
3. Verify with:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You should see one line, ending in `(FF68N39FU5)`.

### 2. Create an app-specific password

1. Go to <https://appleid.apple.com> → sign in → **App-Specific Passwords**.
2. Click `+`, label it `QuickLookProtein notarytool`, copy the
   16-character password Apple generates.
3. Store it in the macOS keychain so the script never has to see the
   plaintext:

```bash
xcrun notarytool store-credentials notarytool-profile \
    --apple-id    YOUR_APPLE_ID@example.com \
    --team-id     FF68N39FU5 \
    --password    abcd-efgh-ijkl-mnop
```

This stores the credentials under the profile name `notarytool-profile`,
which is what `release.sh` reads by default.

> ⚠️ **Never put the app-specific password into any file in this
> repository.** It belongs only in your keychain. The script reads it by
> profile name; you don't pass it as an argument.

### 3. Verify the credentials

```bash
xcrun notarytool history --keychain-profile notarytool-profile | head
```

You should get a "No submissions found" response (success — the credentials
authenticate).

---

## Per-release workflow

From a clean working tree on `feature/ario-signed`:

```bash
# Bump the version in Xcode → project → MARKETING_VERSION,
# OR pass it on the command line:
./scripts/release.sh 2.0.0
```

The script will:

1. Archive the project at version `2.0.0` (this builds all 4 targets:
   main app, QLExtension, QLThumbnail, MDImporter).
2. Export a signed `.app` using your Developer ID Application identity.
3. Verify the local code signature.
4. ZIP the `.app` into `QuickLookProtein-2.0.0.zip`.
5. Submit the ZIP to Apple's notary service and wait for the verdict
   (2–10 minutes typically).
6. Staple the notary ticket to the `.app` so it works offline.
7. Re-zip the stapled `.app` so the published artifact is what users get.

Final artifact: `build/release/QuickLookProtein-2.0.0.zip`.

### Publish

Either via the `gh` CLI:

```bash
gh release create v2.0.0 build/release/QuickLookProtein-2.0.0.zip \
   --notes-file CHANGELOG.md \
   --title "QuickLookProtein 2.0.0"
```

Or upload manually at <https://github.com/ArioMoniri/QuickLookProtein/releases/new>.

As soon as the release is published, the in-app updater (`Updater.swift`)
will pick it up on the next launch / check.

---

## Troubleshooting

### "User interaction is not allowed" during `codesign`

The keychain is locked. Unlock it:

```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

### Notarisation fails with "Code object is not signed at all"

Usually a missing entitlement or a nested binary that wasn't re-signed.
Check the log:

```bash
xcrun notarytool log <submission-uuid> --keychain-profile notarytool-profile
```

The log file (`.json`) lists exact paths inside the bundle that failed.

### "The provided entity includes an unsigned framework"

Means one of the extension `.appex` bundles isn't signed correctly. The
script signs with `--deep --options runtime`; if you've added new
extensions, make sure their *Hardened Runtime* checkbox is on under
*Signing & Capabilities* in Xcode.

### Gatekeeper still blocks the app after install

Right-click the app → Open. If macOS still refuses, run:

```bash
spctl -a -t exec -vv /Applications/QuickLookProtein.app
```

A "source=Notarized Developer ID" response means notarisation worked; a
"source=Unverified Developer" means the ticket wasn't stapled or hadn't
propagated yet (give it a few minutes).

### The Spotlight indexer isn't picking up files after install

Spotlight caches importer plists. Force a re-import:

```bash
mdimport -r /Applications/QuickLookProtein.app/Contents/PlugIns/MDImporter.appex
mdimport ~/some-test-file.pdb
mdls ~/some-test-file.pdb | head -20
```

---

## What the GitHub auto-updater expects

The updater (`Xcode/QuickLookProtein/Updater.swift`) calls
`https://api.github.com/repos/ArioMoniri/QuickLookProtein/releases/latest`
on launch. It only requires the GitHub Release object's `tag_name` field
(parsed as `vX.Y.Z` or `X.Y.Z`) and `html_url`. Asset filenames don't
matter for the check itself — the user clicks "Download" which opens the
release page.

You can tag releases as either `v2.0.0` or `2.0.0`; the parser handles
both. Stick to one convention to keep the tags tidy.

If you ever switch to Sparkle, this file becomes obsolete — the
`appcast.xml` + `sign_update` flow replaces everything above. See
[FUTURE_WORK.md](FUTURE_WORK.md).
