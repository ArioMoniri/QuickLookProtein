# Sparkle + automated release setup

This is the one-time setup for the **fully automated release pipeline**:
push a tag, GitHub Actions builds + signs + notarises + publishes + updates
the auto-update feed.

Time investment: about **20 minutes**, once. After that, every release is
literally `git tag v2.0.0 && git push origin v2.0.0`.

The pieces:

```
┌──────────────────┐    push tag v*    ┌────────────────────────┐
│  Your laptop     │ ───────────────▶  │   GitHub Actions       │
│  (one-time setup)│                   │  ┌──────────────────┐  │
└──────────────────┘                   │  │ build .app       │  │
                                       │  │ sign (Dev ID)    │  │
                                       │  │ notarise+staple  │  │
                                       │  │ Sparkle-sign zip │  │
                                       │  │ publish release  │  │
                                       │  │ update appcast   │  │
                                       │  └──────────────────┘  │
                                       └───────────┬────────────┘
                                                   │
                                                   ▼
                                   ┌────────────────────────────────┐
                                   │ GitHub Pages serves            │
                                   │ docs/appcast.xml at            │
                                   │ ariomoniri.github.io/...       │
                                   └────────────────────────────────┘
                                                   │
                                                   ▼
                                   ┌────────────────────────────────┐
                                   │ Installed app's Sparkle client │
                                   │ polls the feed, prompts the    │
                                   │ user, downloads + installs     │
                                   │ in place, relaunches.          │
                                   └────────────────────────────────┘
```

---

## Step 1 — add Sparkle to the Xcode project (one click)

The Sparkle Swift Package isn't declared in `project.pbxproj` because
adding SPM dependencies via raw text edits is the single Xcode-project
mutation I don't trust myself to do reliably. Adding it via the Xcode UI
takes about 10 seconds and is known-good.

1. Open `Xcode/QuickLookProtein.xcodeproj`.
2. **File → Add Package Dependencies…**
3. Paste `https://github.com/sparkle-project/Sparkle` into the search.
4. *Dependency Rule:* **Up to Next Major Version** from `2.6.0`.
5. Click **Add Package**.
6. In the next sheet, check **Sparkle** under *Add to Target →
   QuickLookProtein* (the main app, not any of the extensions). Click
   **Add Package**.
7. Done. Build the project once (`⌘B`) to confirm the import resolves —
   `Updater.swift` should now compile the real branch (`#if canImport(Sparkle)`)
   instead of the fallback stub.

> ℹ️ Don't add Sparkle to the QLExtension, QLThumbnail, or MDImporter
> targets. App extensions can't (and shouldn't) update themselves —
> they're updated as part of the host app bundle.

---

## Step 2 — generate the Sparkle EdDSA key pair (one time)

Run the helper:

```bash
./scripts/generate-sparkle-keys.sh
```

It will:

1. Download a known-good Sparkle release tarball (for the `generate_keys`
   tool — doesn't install anything globally).
2. Generate the key pair (private goes into your macOS keychain; public is
   printed to the terminal).
3. Extract the private key, base64-encode it, and copy to your clipboard.

The output looks like:

```
── PUBLIC KEY (for Info.plist SUPublicEDKey) ──
J9aBcD…                       ← short base64 line, ~43 chars

── PRIVATE KEY (base64; paste into GitHub Actions Secrets) ──
MMNkX…                        ← longer base64 string
(Private key base64 copied to clipboard.)
```

What to do with each:

**Public key** → paste into
[Xcode/QuickLookProtein/Info.plist](../Xcode/QuickLookProtein/Info.plist),
replacing the `REPLACE_WITH_SPARKLE_PUBLIC_KEY_FROM_generate_keys`
placeholder string under the `SUPublicEDKey` entry. Commit + push.

**Private key (base64)** → goes into a GitHub Actions secret (next step).
Never commit it to the repo.

---

## Step 3 — add GitHub Actions secrets

Go to your fork's
[Actions secrets page](https://github.com/ArioMoniri/QuickLookProtein/settings/secrets/actions)
and add the following **Repository secrets**:

| Name | Value |
|------|-------|
| `BUILD_CERTIFICATE_BASE64` | base64 of your Developer ID Application `.p12` |
| `BUILD_CERTIFICATE_PASSWORD` | password you set when exporting the .p12 |
| `KEYCHAIN_PASSWORD` | any random string (e.g. `openssl rand -base64 32`) |
| `APPLE_ID` | your Apple Developer email |
| `APPLE_APP_PASSWORD` | the app-specific password from appleid.apple.com |
| `APPLE_TEAM_ID` | `FF68N39FU5` |
| `SPARKLE_ED_PRIVATE_KEY` | base64 from `generate-sparkle-keys.sh` |

### How to get `BUILD_CERTIFICATE_BASE64`

1. Open **Keychain Access**.
2. Find your **Developer ID Application: Ariorad Moniri (FF68N39FU5)**
   certificate (under "My Certificates").
3. Right-click → **Export…** → save as `.p12`. Set a password — this
   becomes `BUILD_CERTIFICATE_PASSWORD`.
4. In Terminal:

   ```bash
   base64 -i ~/Desktop/cert.p12 | pbcopy
   ```

   Paste into the GitHub secret. The original `.p12` can be deleted
   afterwards — it's already in your keychain.

### How to get `APPLE_APP_PASSWORD`

1. Sign in at <https://appleid.apple.com>.
2. **App-Specific Passwords** → `+` → label it
   `QuickLookProtein GitHub Actions`.
3. Copy the 16-character password Apple displays (it's only shown once).
4. Paste into the GitHub secret.

This password is *not* your Apple ID password and gives the holder
**only** the right to notarise things under your developer account. If
you ever suspect it's leaked, revoke it from the same Apple ID page.

---

## Step 4 — enable GitHub Pages for the appcast feed

1. Go to **Settings → Pages** on the fork.
2. Source: **Deploy from a branch**.
3. Branch: `feature/ario-signed` (or `main` after you merge). Folder: `/docs`.
4. Click **Save**.

After a minute, the appcast will be live at:

```
https://ariomoniri.github.io/QuickLookProtein/appcast.xml
```

This URL is already baked into the app's Info.plist as `SUFeedURL`. If
your GitHub username's canonical case is different from what GitHub Pages
serves, update `SUFeedURL` accordingly.

---

## Step 5 — your first release

```bash
# Make sure all the secrets above are set and Pages is enabled.
git checkout feature/ario-signed
git tag v2.0.0
git push origin v2.0.0
```

The Actions workflow takes about 8–15 minutes (most of it waiting on
Apple's notary service). When it completes, you'll have:

- A GitHub Release at `…/releases/v2.0.0` with
  `QuickLookProtein-2.0.0.zip` attached
- An updated `docs/appcast.xml` committed back to the branch
- `https://ariomoniri.github.io/QuickLookProtein/appcast.xml` listing the
  new release

The next time any installed copy of the app runs (or hits its 24-hour
scheduled check), Sparkle will see the new entry, present the user with an
"Install Update" dialog, download, verify the EdDSA signature, install in
place, and relaunch.

**No re-download required by the user.** That's the whole point of
Sparkle vs. the old GitHub-API checker.

---

## Re-running a release / fixing a botched release

The workflow is **idempotent** at the release level: pushing the same
`v2.0.0` tag twice will re-run the build, and the script will *replace*
(not duplicate) the entry in `appcast.xml` for that version. To delete a
release entirely:

```bash
gh release delete v2.0.0 --yes --cleanup-tag
# Then edit docs/appcast.xml manually to remove the corresponding <item>.
git commit -am "Remove stale 2.0.0 appcast entry"
git push
```

---

## Workflow inputs (manual dispatch)

The workflow can also be triggered without a tag — go to
**Actions → Release → Run workflow**, type a version number, and it'll
build that version. Useful for testing the pipeline before cutting a real
release. (Note: with no tag, no GitHub Release is created automatically;
you'd want to add the `gh release create` invocation manually.)

---

## Common failure modes

### "errSecInternalComponent" / "Authentication required" during codesign

The temp keychain wasn't unlocked properly. The workflow handles this, but
if you fork-and-customise the workflow, make sure
`security set-key-partition-list` runs after import — that's the magic
incantation that makes codesign skip the password prompt.

### Notarisation `Invalid` with no inner error

The most common cause is an unsigned framework or extension inside the
`.app`. Run

```bash
spctl -a -t exec -vv path/to/QuickLookProtein.app
```

locally to see which inner item failed.

### "edSignature verification failed" on the client

The public key in Info.plist doesn't match the private key in
`SPARKLE_ED_PRIVATE_KEY`. Re-export with
`./scripts/generate-sparkle-keys.sh` and update both.

### GitHub Pages doesn't update

GitHub Pages can take a few minutes to publish. Force a rebuild from
**Settings → Pages → Visit site** (or push a no-op commit to /docs/).
