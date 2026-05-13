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
# just prints the existing public key. We capture stdout for paste-ready
# output.
PUBLIC_KEY="$(./bin/generate_keys 2>&1 | tail -n 1 | tr -d '[:space:]')"

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "✗ Could not read public key from generate_keys output."; exit 1
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

echo "── PRIVATE KEY (base64; paste into GitHub Actions Secrets) ────"
echo "$PRIVATE_B64"
echo "───────────────────────────────────────────────────────────────"
echo ""

# Copy to clipboard if available — convenient for pasting into the GitHub
# secret form. We deliberately use pbcopy without a tee so it stays out of
# any shell history.
if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$PRIVATE_B64" | pbcopy
    echo "(Private key base64 copied to clipboard.)"
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
