# Windows 11 Optimizer

One PowerShell script that debloats Windows 11, cuts telemetry and background load, and applies gaming-oriented tweaks — adapting automatically to whatever device it runs on (desktop, laptop, or handheld).

Based on the r/LegionGo *Windows 11 Resource & Performance Optimization Guide*, translated into an idempotent, self-verifying script.

---

## ⚠️ Read before running

This script ships with **VBS / Memory Integrity disabled** (`$DisableVBS = $true`). That is a deliberate performance choice, not an oversight: it gains roughly 3–8% FPS in some games and costs you a layer of protection against attacks that abuse vulnerable drivers.

**If this is a work machine, a managed device, or anything you'd rather keep locked down, set `$DisableVBS = $false` before running.**

It also turns off all Windows notifications and force-installs an ad blocker via browser policy. Skim the config block at the top of the script — every section has an on/off switch.

---

## Run it

Paste this into **PowerShell** (open Start, type "PowerShell", hit Enter):

```powershell
$f = Join-Path $env:TEMP 'win11opt.ps1'; irm 'https://raw.githubusercontent.com/xnostra/Windows11-Optimizer/main/Optimize-AllInOne.ps1' -OutFile $f; Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',$f
```

It downloads the script, prompts for admin via UAC, and runs it in a new window that stays open so you can read the output. You do **not** need to open an admin shell first, and this must be run from **PowerShell, not Command Prompt** (`irm` doesn't exist in cmd).

From Command Prompt or Win+R instead, wrap it:

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f = Join-Path $env:TEMP 'win11opt.ps1'; irm 'https://raw.githubusercontent.com/xnostra/Windows11-Optimizer/main/Optimize-AllInOne.ps1' -OutFile $f; Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',$f"
```

> **`'irm' is not recognized`** — you're in Command Prompt; use the wrapped version above instead.

**Prefer to read it first?** Download `Optimize-AllInOne.ps1`, look it over, then double-click `RUN-ME.bat`.

---

## What it does

| Area | Actions |
|---|---|
| **Debloat** | Removes Bing Weather, Spotify stub, Zune, Mixed Reality, Widgets, Copilot; uninstalls McAfee/Norton/WildTangent trialware |
| **Privacy** | Telemetry to minimum, Advertising ID off, feedback frequency Never, Start-menu suggestions off, clears diagnostic cache |
| **Search** | Disables Bing/web results in the Start menu search box |
| **Background** | Bulk-disables background app permissions; disables startup entries not on a keep-list |
| **Services** | `DiagTrack`, `dmwappushservice`, `PrintNotify`, `WSearch`, `SysMain` → Manual (never Disabled) |
| **Power** | Balanced plan, min CPU 5% / max 100%, PCIe ASPM off on desktops |
| **Gaming** | Game Mode on, Game Bar/DVR off, HAGS on, windowed-game optimizations on |
| **Security** | Adds your game libraries to Defender exclusions (never the whole drive) |
| **Regional** | 12-hour time, `dd-MM-yyyy` dates, A4 paper (locale + physical printers) |
| **Apps** | Installs Chrome, Microsoft 365, WinRAR via winget — skips anything already present |
| **Delivery Optimization** | Windows Update peer-to-peer: local-network sharing allowed, internet sharing off |
| **Administrator account (OFF by default)** | Enables the built-in Administrator account, then interactively prompts YOU for its password - nothing hardcoded |
| **Ad blocker** | Deploys uBlock Origin per browser (see below) |
| **Resolution** | Optional per-game auto-switching (see below) |

### Adapts to the device

- **Desktop** → PCIe ASPM disabled for maximum performance, AC power profile only
- **Laptop / handheld** → PCIe ASPM left **enabled** (disabling it measurably increases power draw), and CPU limits applied to the battery profile too
- Detects your GPU and prints the correct driver page; detects the right OEM companion app (Legion Space, Armoury Crate, MSI Center, Alienware Command Center, Omen Gaming Hub, etc.) and opens a search only if it isn't installed

### Ad blocker: the right uBlock per browser

Manifest V2 is being removed across Chromium browsers, and that decides which version each browser can actually run:

| Browser | Installs | Why |
|---|---|---|
| Chrome | uBlock Origin **Lite** | Chrome 151 removed the last MV2 support — full uBO cannot run |
| Edge | uBlock Origin **Lite** | MV2 phase-out began Aug 2026 (uses Edge Add-ons store IDs, which differ from Chrome's) |
| Firefox | **Full** uBlock Origin | Firefox keeps MV2 support |
| Vivaldi | uBlock Origin **Lite** | Chromium-based, same removal |
| Brave | *not automated* | Brave's forcelist policy is unreliable, it self-hosts MV2 extensions, and Shields already blocks ads. For full uBO: `brave://settings/extensions` → enable Manifest V2 |

Extensions deploy via `ExtensionInstallForcelist`, so browsers will show **"Managed by your organization"** and the extension can't be removed from the browser UI. Delete the policy registry values to undo.

### Per-game resolution switching (optional)

Scans your Steam, GOG, and Epic libraries, adds what it finds to `game-resolutions.json` at native resolution, and registers a background task that switches resolution when a game launches and reverts when it closes. Useful on a 4K display where you'd rather play at 1440p.

Edit `game-resolutions.json` to set per-game resolutions. If no games are configured, the watcher isn't scheduled.

---

## Built-in Administrator account (OFF by default)

Set `$EnableAdminAccount = $true` to enable the built-in Administrator account for local/remote troubleshooting. Run manually, it enables the account and then **interactively prompts you to type its password** (with a confirmation entry) - the password is never hardcoded, never written to this script, never committed to this repo. Only you, at the moment you run it, know it.

This only works in a manual, interactive run. Under unattended execution (e.g. an Intune Platform Script running as SYSTEM), there's no one to answer the prompt, so this section is skipped automatically rather than hanging.

For managing this at fleet scale (many devices, IT staff needing walk-up admin access), the better-fitting tool is Intune's **Local user group membership** policy (Endpoint security → Account protection) - it adds an Entra security group to the local Administrators group on every enrolled device, so your team logs in with accounts they already have rather than a local account at all. That's a portal configuration, not something this script does.

---

## What it deliberately does **not** do

- **Install GPU drivers.** It detects your GPU and links the right page, but never downloads or runs a driver installer — a wrong unattended driver install can leave you with no display output.
- **Break Windows Update, Defender, or Security Center.** Those are left completely alone.
- **Disable services outright.** Everything goes to *Manual*, so features still work on demand.
- **Uninstall Office, Lenovo Vantage, or OEM support tools.** Auto-removing those risks killing a paid license or a tool your fan curves depend on. They're disabled from startup instead.

---

## Safe to re-run

Every action checks current state first. Re-running reports `already set` / `already installed` and changes nothing. There is no separate "undo" needed for a repeat run.

Configuration toggles are at the top of the script — set any to `$false` to skip that section. Worth reviewing before your first run:

- `$RemoveXbox` — `$false` by default; set `$true` only if you don't use Game Pass
- `$DisableVBS` — **`$true` by default**: turns OFF VBS / Memory Integrity. This gains roughly 3–8% FPS in some games but reduces exploit protection against malicious-driver attacks. Set it to `$false` to keep Memory Integrity enabled
- `$DisableNotificationsToasts` — turns off *all* Windows notifications
- `$AppsToInstall` — edit or empty this list to change what gets installed

---

## Verifying it worked

The script reports what it did, but the honest check is inspecting the system afterward. Useful spot-checks:

```powershell
Get-Service DiagTrack, SysMain, WSearch | Select-Object Name, StartType
powercfg /getactivescheme
Get-MpPreference | Select-Object -ExpandProperty ExclusionPath
```

Some policy keys (`EnableFeeds`, `AllowNewsAndInterests`, `TaskbarDa`) can be blocked even for administrators on certain builds — the script reports these as skipped and continues. They only affect Widgets, which is removed outright anyway.

---

## Requirements

- Windows 11 (most of it works on Windows 10)
- Administrator rights — the script self-elevates
- `winget` for app installs (ships with Windows 11; otherwise install *App Installer* from the Microsoft Store)

## License

MIT
