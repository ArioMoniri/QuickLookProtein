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
  version "1.7.92"
  sha256 "5731f5ca490a8c3e7e185166d30a0093810fa63479d4437897521a923ed1f002"

  url "https://github.com/ArioMoniri/QuickLookProtein/releases/download/v#{version}/QuickLookProtein-#{version}.dmg",
      verified: "github.com/ArioMoniri/QuickLookProtein/"
  name "QuickLookProtein2"
  # `desc` is hard-limited to 80 chars by `brew audit`.  Keep the
  # full format list in README; the desc is the search-result tag-
  # line.
  desc "Quick Look extension for previewing 3D molecular structure files"
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
  # `depends_on macos: :big_sur` already means ">= Big Sur" - the
  # symbol is interpreted as the minimum supported macOS, not a
  # pin.  Older "macos: ">= :big_sur" syntax is now flagged by
  # `brew style` (Homebrew/OSDependsOn).
  depends_on macos: :big_sur

  # The bundle on disk is still named QuickLookProtein.app — the "2"
  # in the marketing name is delivered via CFBundleDisplayName /
  # CFBundleName only. PRODUCT_NAME and the bundle identifier are
  # unchanged so Sparkle can keep replacing the .app in place after
  # the initial brew install, and so existing Spotlight / Quick Look
  # registrations against the old bundle continue to resolve.
  app "QuickLookProtein.app"

  # `brew audit` enforces alphabetical order in the zap array.
  # Quick Look / Spotlight extension prefs and the Sparkle plist
  # all share that sort key.  We keep one logical comment up here
  # rather than scattering them per-line so the alphabetisation
  # rule doesn't conflict with explanatory comments.
  zap trash: [
    "~/Library/Application Scripts/com.ariomoniri.QuickLookProtein",
    "~/Library/Caches/com.ariomoniri.QuickLookProtein",
    "~/Library/Containers/com.ariomoniri.QuickLookProtein",
    "~/Library/Preferences/com.ariomoniri.QuickLookProtein.MDImporter.plist",
    "~/Library/Preferences/com.ariomoniri.QuickLookProtein.plist",
    "~/Library/Preferences/com.ariomoniri.QuickLookProtein.QLExtension.plist",
    "~/Library/Preferences/com.ariomoniri.QuickLookProtein.QLThumbnail.plist",
    "~/Library/Preferences/org.sparkle-project.Sparkle.plist",
  ]
end
