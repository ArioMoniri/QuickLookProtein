# Homebrew Cask for QuickLookProtein2 — Ariorad Moniri's signed,
# notarised fork of Jethro Hemmann's original QuickLookProtein.
#
# Install from a personal tap until this lands in homebrew-cask:
#
#   brew tap ariomoniri/quicklookprotein https://github.com/ArioMoniri/QuickLookProtein
#   brew install --cask quicklookprotein
#
# A tap pointed at the repo root will discover this file
# automatically because Homebrew searches Casks/ in addition to the
# conventional HomebrewFormula/ — no separate tap repo required.
#
# Why a versioned URL: Homebrew's update model is "version bump
# triggers re-download + sha256 verify". Pointing at the versioned
# asset (QuickLookProtein-#{version}.dmg) plus a real digest makes
# `brew upgrade --cask quicklookprotein` strictly cryptographically
# pinned to a known artifact. The release workflow also uploads an
# unversioned alias (QuickLookProtein.dmg) for the README's "Download
# DMG" button, but that one moves between releases and is unsuitable
# for hashing here.

cask "quicklookprotein" do
  version "1.7.65"
  sha256 "2de193e03d4f94b242b3c33a897e5d317724794d72e1b9ad86b2e32f411b6a11"

  url "https://github.com/ArioMoniri/QuickLookProtein/releases/download/v#{version}/QuickLookProtein-#{version}.dmg",
      verified: "github.com/ArioMoniri/QuickLookProtein/"
  name "QuickLookProtein2"
  desc "Quick Look extension for previewing 3D molecular structure files (PDB, CIF, SDF, MOL2, …)"
  homepage "https://github.com/ArioMoniri/QuickLookProtein"

  # The release workflow tags every release as v{MARKETING_VERSION}
  # and uploads QuickLookProtein-#{version}.dmg as an asset. Livecheck
  # reads the /releases/latest API endpoint via the github_latest
  # strategy so upgrades surface as soon as a new tag is published.
  livecheck do
    url :url
    strategy :github_latest
  end

  # Sparkle handles in-app updates already; keep auto_updates true so
  # Homebrew doesn't fight the app's own updater for control of the
  # /Applications bundle. CFBundleIdentifier and the Sparkle appcast
  # URL are deliberately unchanged from the original QuickLookProtein
  # so an existing user can install via brew and continue to receive
  # Sparkle updates without reinstalling.
  auto_updates true
  depends_on macos: ">= :big_sur"

  # The bundle on disk is still named QuickLookProtein.app — the "2"
  # in the marketing name is delivered via CFBundleDisplayName /
  # CFBundleName only. PRODUCT_NAME and the bundle identifier are
  # unchanged so Sparkle can keep replacing the .app in place after
  # the initial brew install, and so existing Spotlight / Quick Look
  # registrations against the old bundle continue to resolve.
  app "QuickLookProtein.app"

  zap trash: [
    "~/Library/Preferences/com.ariomoniri.QuickLookProtein.plist",
    "~/Library/Application Scripts/com.ariomoniri.QuickLookProtein",
    "~/Library/Containers/com.ariomoniri.QuickLookProtein",
    "~/Library/Caches/com.ariomoniri.QuickLookProtein",
    # Quick Look / Spotlight extensions live under the host app and
    # are removed with the .app, but their preference plists hang
    # around. Mop them up on `brew uninstall --zap`.
    "~/Library/Preferences/com.ariomoniri.QuickLookProtein.QLExtension.plist",
    "~/Library/Preferences/com.ariomoniri.QuickLookProtein.QLThumbnail.plist",
    "~/Library/Preferences/com.ariomoniri.QuickLookProtein.MDImporter.plist",
    # Sparkle persisted state — preferences for "skip this version",
    # last-check timestamp, etc. Not bundle-id-keyed on every Sparkle
    # version so we wipe the umbrella plist by name.
    "~/Library/Preferences/org.sparkle-project.Sparkle.plist",
  ]
end
