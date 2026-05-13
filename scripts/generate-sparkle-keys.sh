#!/usr/bin/env bash
#
# generate-sparkle-keys.sh — one-time generation of the Sparkle EdDSA key pair.
#
# What this does:
#   1. Downloads the matching Sparkle release tarball (so `generate_keys` is
#      available without polluting your system).
#   2. Runs `generate_keys`. This creates a private key in the macOS keychain
#      (under a generic password named `https://sparkle-project.org`) and
#      prints the public key to stdout.
#   3. Exports the private key in base64 form, ready to paste into the
#      GitHub Actions secret `SPARKLE_ED_PRIVATE_KEY`.
#
# Run this once. Save:
#   - the PUBLIC key into Info.plist (key `SUPublicEDKey`)
#   - the BASE64 PRIVATE key into the GitHub Actions secret
#     `SPARKLE_ED_PRIVATE_KEY` (Settings → Secrets and variables → Actions)
#
# After that you never touch the private key again — the GitHub Action signs
# every release using the secret.
#
set -euo pipefail

SPARKLE_VERSION="${SPARKLE_VERSION:-2.6.4}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$WORK_DIR"

echo "▶ Downloading Sparkle ${SPARKLE_VERSION} (just for the tools)…"
curl -fsSL -o Sparkle.tar.xz \
     "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
tar -xf Sparkle.tar.xz

if [[ ! -x ./bin/generate_keys ]]; then
    echo "✗ Sparkle tarball did not contain bin/generate_keys"; exit 1
fi

echo ""
echo "▶ Generating EdDSA key pair…"
echo "  (you may be prompted for your login keychain password)"
echo ""

# `generate_keys` is idempotent: if a key already exists in the keychain it
# just prints the existing public key. Sparkle 2.6.x wraps the value in an
# Info.plist snippet — extract from <string>…</string>. Fallback: scan for
# any 44-char base64 token (32-byte Ed25519 key, base64-padded).
GEN_OUTPUT="$(./bin/generate_keys 2>&1)"
PUBLIC_KEY="$(printf '%s\n' "$GEN_OUTPUT" \
    | sed -nE 's:.*<string>([A-Za-z0-9+/=]+)</string>.*:\1:p' \
    | head -n 1)"
if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY="$(printf '%s\n' "$GEN_OUTPUT" \
        | grep -oE '[A-Za-z0-9+/]{43}=' \
        | head -n 1)"
fi

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "✗ Could not read public key from generate_keys output. Raw:"
    printf '%s\n' "$GEN_OUTPUT"
    exit 1
fi

echo "── PUBLIC KEY (for Info.plist SUPublicEDKey) ──────────────────"
echo "$PUBLIC_KEY"
echo "───────────────────────────────────────────────────────────────"
echo ""

# Read the private key out of the keychain and base64-encode it for GitHub
# Actions. Sparkle stores it as a generic password whose account is the
# public key. We use `security find-generic-password -w` to dump just the
# password bytes.
PRIVATE_RAW="$(
    security find-generic-password \
        -s 'https://sparkle-project.org' \
        -a "$PUBLIC_KEY" \
        -w 2>/dev/null || true
)"

if [[ -z "$PRIVATE_RAW" ]]; then
    # Older Sparkle versions stored under a fixed account name "ed25519".
    PRIVATE_RAW="$(
        security find-generic-password \
            -s 'https://sparkle-project.org' \
            -a 'ed25519' \
            -w 2>/dev/null || true
    )"
fi

if [[ -z "$PRIVATE_RAW" ]]; then
    echo "⚠ Could not pull the private key from the keychain automatically."
    echo "  Open Keychain Access, search for 'sparkle-project', and copy the"
    echo "  password manually. Then run:"
    echo ""
    echo "    echo -n 'THE_PRIVATE_KEY' | base64 | pbcopy"
    echo ""
    echo "  and paste that into the GitHub Actions secret SPARKLE_ED_PRIVATE_KEY."
    exit 0
fi

PRIVATE_B64="$(printf '%s' "$PRIVATE_RAW" | base64)"

# Deliberately NOT printing the private key to stdout — terminal scrollback,
# tmux/screen captures, and SSH logs are all places we don't want it
# appearing. We copy it straight to the clipboard so the user can paste
# into GitHub Secrets directly. If pbcopy isn't available (you're SSH'd
# in somewhere headless), we write to a tempfile with restricted perms
# and tell the user the path.
if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$PRIVATE_B64" | pbcopy
    echo "── PRIVATE KEY ────────────────────────────────────────────────"
    echo "✅ Copied to clipboard. Paste into the GitHub Actions secret"
    echo "   SPARKLE_ED_PRIVATE_KEY now, before doing anything else that"
    echo "   touches your clipboard."
    echo "───────────────────────────────────────────────────────────────"
else
    TMPFILE="$(mktemp -t sparkle-private.XXXXXX)"
    chmod 600 "$TMPFILE"
    printf '%s' "$PRIVATE_B64" > "$TMPFILE"
    echo "── PRIVATE KEY ────────────────────────────────────────────────"
    echo "✅ Written to $TMPFILE (chmod 600)."
    echo "   Paste its contents into the GitHub Actions secret"
    echo "   SPARKLE_ED_PRIVATE_KEY, then delete the file:"
    echo "       rm $TMPFILE"
    echo "───────────────────────────────────────────────────────────────"
fi

echo ""
echo "▶ Next steps:"
echo "  1. Paste the PUBLIC key above into"
echo "     Xcode/QuickLookProtein/Info.plist under SUPublicEDKey"
echo "     (replace the REPLACE_WITH_… placeholder)."
echo "  2. Go to https://github.com/ArioMoniri/QuickLookProtein/settings/secrets/actions"
echo "     and add a new secret named SPARKLE_ED_PRIVATE_KEY with the base64"
echo "     value above as its content."
echo "  3. Commit + push the Info.plist change."
echo "  4. Tag a release: git tag v2.0.0 && git push origin v2.0.0"
