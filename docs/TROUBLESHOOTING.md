# Troubleshooting

When something doesn't render, the first move is to capture the actual error. Both apps have built-in log viewers that bypass the need to spelunk through Console / `log show`.

## 🍎 macOS

All logs live under `~/Library/Group Containers/<group>/Library/Logs/QuickLookProtein/` (sandbox fallback: `~/Library/Logs/QuickLookProtein/`). Open them from inside the app at **Settings → Software Update → Extension logs**:

| Symptom | Log to open | Most common cause |
|---|---|---|
| "An error occurred while launching the installer" | `updater.log` | Sparkle install-launch failure; the unwrapped `NSError` is in the log + shown inline in the panel. |
| Quick Look shows a blank document | `qlpreview.log` | `preparePreviewOfFile` failed before HTML was written; line tells you the exact step. |
| Thumbnails come back generic in Finder | `qlthumbnail.log` | `provideThumbnail` parser/render error; full exception stack on disk. |
| Quick Action menu item misbehaving | `qlactions.log` | `beginRequest` / render / merged-PDB writer failure. |

**Software Update fallback.** If Sparkle can't start at all (older dev builds, missing entitlement), the Software Update panel falls back to a **Download from GitHub** button. After one manual DMG install, Sparkle resumes.

## 🪟 Windows

Logs live under `%LocalAppData%\QuickLookProtein\`. Open them from **QuickLookProtein Settings → About → Diagnostics**:

| Symptom | What to do |
|---|---|
| Space-bar shows raw text instead of 3D | **Open plugin log** — if empty, QL-Win never loaded the DLL (use **Open QuickLook log** for the host-side reason). |
| Icon-view thumbnails are blank/white | **Test thumbnail provider** — if step 2 reports MISSING, tap **Yes** on the prompt to **Repair now**. Or hit **Repair thumbnail registration** directly. |
| Thumbnails appear in Icon view but not Details/List view | This is normal Windows behaviour. `IThumbnailProvider` is only invoked for Icon / Tile / Gallery / Content views; Details/List use `IExtractIcon` (different shell interface, not what custom thumbnail providers plug into). Switch view modes to see thumbnails. |
| Update check fails with 403 | GitHub's anonymous API limit (60 req/IP/hour). Wait an hour or use **Open release page**; the inline error shows the actual reset time from v1.7.82+. |
| Setup.exe finished but Settings app missing | Open `%LocalAppData%\Temp\QuickLookProtein-install.log` — usually a locked DLL on upgrade-over-running-QL-Win (fixed in 1.7.79+). |
| Two `QuickLook.exe` processes running | You have both the Microsoft Store and GitHub releases of QL-Win installed. Uninstall one (Settings → Apps). The Store version is recommended. |

**Refresh thumbnails.** If thumbnails don't repaint after a fresh install, Explorer cached the old `<ext> → CLSID` map. **Settings → About → Diagnostics → Refresh thumbnails** broadcasts `SHChangeNotify(SHCNE_ASSOCCHANGED)` + clears the icon cache. **Shift-click** for a full `explorer.exe` restart (the shell auto-respawns) when SHChangeNotify isn't enough.

**WebView2 ObjectDisposedException** in `plugin.log` after fast-advancing through previews is harmless from v1.7.88+ — logged as INFO ("cancelled (WebView disposed)") rather than ERR. The race is handled.

**WebView2 ArgumentException: "Value does not fall within the expected range"** with a stack ending in `NavigateToString` happened on large PDBs through v1.7.88 (~2 MB content-string limit). Fixed in v1.7.89+: the rendered HTML is written to a temp file and navigated via a virtual-host mapping instead.

## Common log locations

| Component | Path |
|---|---|
| 🍎 Updater | `~/Library/Group Containers/<group>/Library/Logs/QuickLookProtein/updater.log` |
| 🍎 Quick Look preview | `~/Library/Group Containers/<group>/Library/Logs/QuickLookProtein/qlpreview.log` |
| 🍎 Thumbnail | `~/Library/Group Containers/<group>/Library/Logs/QuickLookProtein/qlthumbnail.log` |
| 🍎 Quick Actions | `~/Library/Group Containers/<group>/Library/Logs/QuickLookProtein/qlactions.log` |
| 🪟 In-app updater | `%LocalAppData%\QuickLookProtein\update.log` |
| 🪟 Thumbnail provider | `%LocalAppData%\QuickLookProtein\thumbnail.log` |
| 🪟 Plugin | `%AppData%\pooi.moe\QuickLook\QuickLook.Plugin\QuickLookProtein\plugin.log` |
| 🪟 Setup.exe install steps | `%LocalAppData%\Temp\QuickLookProtein-install.log` |

When filing an issue, the relevant log usually pins the problem to a single line.
