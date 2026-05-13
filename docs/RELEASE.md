# Release workflow

> 📌 **Releases are fully automated via GitHub Actions.** The previous
> local-script flow is preserved at [`scripts/release.sh`](../scripts/release.sh)
> for emergency builds; the canonical path is to push a tag.

## The 30-second version

```bash
git checkout feature/ario-signed
git tag v2.0.0
git push origin v2.0.0
# Wait ~10 minutes. GitHub Release + appcast update happen automatically.
```

For the one-time setup (cert export, Sparkle keygen, GitHub Actions
secrets, GitHub Pages config), see [SPARKLE_SETUP.md](SPARKLE_SETUP.md).

## What happens when you push a tag

The [`.github/workflows/release.yml`](../.github/workflows/release.yml)
workflow runs on `macos-14`:

1. Imports your Developer ID Application certificate into a temporary,
   throwaway keychain (cert provided as a base64-encoded `.p12` in
   `BUILD_CERTIFICATE_BASE64`).
2. Runs `xcodebuild archive` with manual signing using that certificate
   and your team ID.
3. Exports the signed `.app` with `xcodebuild -exportArchive`.
4. Zips the `.app`.
5. Submits to Apple's notary service via
   `xcrun notarytool submit … --wait` and waits for the verdict.
6. Staples the notarisation ticket to the `.app`.
7. Re-zips the stapled `.app` (so the published artifact is the stapled
   version).
8. Downloads Sparkle's signed release tarball and runs `sign_update`
   against the zip with `SPARKLE_ED_PRIVATE_KEY` from secrets — produces
   the `sparkle:edSignature="…"` line.
9. Creates a GitHub Release with auto-generated notes and attaches the
   zip.
10. Runs `scripts/update-appcast.py` to append a new `<item>` to
    `docs/appcast.xml` (or replace the existing entry for that version).
11. Commits and pushes the updated `appcast.xml` back to the branch with
    `[skip ci]` so the push doesn't re-trigger the workflow.

GitHub Pages serves `docs/appcast.xml` at
`https://ariomoniri.github.io/QuickLookProtein/appcast.xml`. Sparkle
clients in the wild see the new release at their next scheduled check (or
immediately if the user clicks *Check for Updates…*).

## What the user experiences

1. They have version 2.0.0 installed. Sparkle's daily check fires.
2. Sparkle fetches `appcast.xml` from GitHub Pages.
3. It sees a `<sparkle:version>2.1.0</sparkle:version>` entry.
4. Dialog: *"A new version of QuickLookProtein is available — would you
   like to download it now?"* with options **Install Update** /
   **Remind Me Later** / **Skip This Version**.
5. User clicks **Install Update**. Sparkle downloads the zip in the
   background, verifies the EdDSA signature, replaces the app on disk,
   and relaunches.

No manual redownload, no zip extraction, no drag-to-Applications. That's
the whole point of switching from the GitHub-API checker.

## Triggering a release without pushing a tag

The workflow also supports `workflow_dispatch`:

1. Go to **Actions → Release → Run workflow** on GitHub.
2. Enter a version (e.g. `2.0.1`) and click *Run workflow*.
3. The build runs but **does not** create a GitHub Release — that part is
   gated on the tag. Useful for testing the build pipeline against the
   real notarisation service before you commit to a tag.

## Re-running a botched release

Tags can be force-deleted and re-pushed:

```bash
gh release delete v2.0.0 --yes --cleanup-tag
git tag -d v2.0.0
git push --delete origin v2.0.0
# Fix whatever was broken, then re-tag:
git tag v2.0.0
git push origin v2.0.0
```

`update-appcast.py` is idempotent — if an entry for the same version
already exists in `appcast.xml`, it's replaced (not duplicated).

## Local fallback build

The original local-build script is still here:

```bash
./scripts/release.sh 2.0.0
```

It produces an unzipped, signed, notarised, stapled `.app` locally and a
matching zip. **It does not Sparkle-sign or update the appcast** — that's
intentional, because local builds shouldn't be able to push updates to
your installed user base. Use this only for: smoke testing, debugging the
notarisation pipeline, or producing a one-off build for someone who can't
wait for the GitHub Actions run.

## Troubleshooting

The bulk of the troubleshooting notes are in
[SPARKLE_SETUP.md](SPARKLE_SETUP.md) under *Common failure modes*. The
main ones recap:

- **codesign auth prompt in CI:** the workflow handles this with
  `security set-key-partition-list`. If you customise it, keep that step.
- **Notarisation `Invalid`:** run `xcrun notarytool log <UUID>
  --apple-id … --team-id … --password …` to get the per-file failure
  list. Usually a nested binary needs `--options=runtime`.
- **`edSignature verification failed` on client:** the public key in
  Info.plist no longer matches the private key in
  `SPARKLE_ED_PRIVATE_KEY`. Re-run `generate-sparkle-keys.sh` and update
  both.
- **GitHub Pages serves a stale appcast:** the CDN can lag ~5 minutes
  behind a push. Visiting the page from Settings → Pages triggers a
  refresh.
