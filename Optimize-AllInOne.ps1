<#
.SYNOPSIS
    Windows 11 Optimization - SINGLE SELF-CONTAINED SCRIPT.
    Everything in one file: hardware detection, debloat, telemetry, services,
    power, gaming, regional/paper prefs, app installs, ad blocker, and optional
    per-game resolution auto-switching.

.USAGE
    EASIEST: double-click RUN-ME.bat (it handles elevation for you).

    Or right-click this file -> "Run with PowerShell" - it will prompt for
    admin rights automatically if you're not already elevated.

.NOTES
    Portable - reads live state on whatever device it runs on and adapts
    (desktop vs laptop/handheld). Idempotent - safe to run repeatedly.
    Never installs GPU drivers unattended (can break display output).
#>

# ---- Who are we running as? (checked early - $ScriptDir and self-elevation both need it) ----
# IsInRole(Administrator) checks membership in BUILTIN\Administrators, which
# NT AUTHORITY\SYSTEM is NOT a member of even though it has full rights - so
# this check alone would misfire under unattended SYSTEM execution (e.g. an
# Intune Platform Script), attempting a UAC relaunch with no desktop session
# to show the prompt on. Checking the well-known SYSTEM SID (S-1-5-18)
# directly avoids that.
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$currentIdentity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSystemAccount = $currentIdentity.User.Value -eq 'S-1-5-18'

# ---- Working directory ----
# $PSScriptRoot is EMPTY when this script is piped straight into PowerShell
# (irm <url> | iex), which would put helper files at the drive root.
# Under SYSTEM (e.g. Intune), a per-user profile path like %LOCALAPPDATA%
# isn't readable by the actual signed-in user's own scheduled tasks, so use
# ProgramData instead - readable by everyone, standard location for exactly
# this "SYSTEM writes it, a user's task reads it" situation.
$ScriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($isSystemAccount) {
    Join-Path $env:ProgramData 'Win11Optimize'
} else {
    Join-Path $env:LOCALAPPDATA 'Win11Optimize'
}
if (-not (Test-Path $ScriptDir)) { New-Item -ItemType Directory -Path $ScriptDir -Force | Out-Null }

if (-not $isAdmin -and -not $isSystemAccount) {
    Write-Host "Not running as Administrator - relaunching with elevation..." -ForegroundColor Yellow
    # When piped from the web there is no file to relaunch, so write ourselves out first.
    $selfPath = $PSCommandPath
    if (-not $selfPath) {
        $selfPath = Join-Path $ScriptDir 'Optimize-AllInOne.ps1'
        try {
            $MyInvocation.MyCommand.ScriptBlock.ToString() | Set-Content -Path $selfPath -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Host "Could not save a local copy to elevate with: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Re-run from an Administrator PowerShell window instead." -ForegroundColor Red
            return
        }
    }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-NoExit', '-File', "`"$selfPath`""
        ) -ErrorAction Stop
    } catch {
        Write-Host "Elevation was declined or failed. This script needs Administrator" -ForegroundColor Red
        Write-Host "rights to change services, policies, and machine-wide settings." -ForegroundColor Red
    }
    return
}

# ============================================================
# CONFIG
# ============================================================
$RemoveXbox            = $false   # $true only if you DON'T use Game Pass
$RemoveMixedReality    = $true
$RemoveBingWeather     = $true
$RemoveSpotify         = $true
$RemoveZune            = $true
$RemoveWidgets         = $true
$RemoveCopilot         = $true
$RemoveOemBloatware    = $true
$DisableTelemetry      = $true
$DisableAdvertisingId  = $true
$DisableWebSearch      = $true
$TuneDiagnosticsFeedback = $true
$ClearDiagnosticDataNow  = $true
$DisableBackgroundApps = $true
$TuneStartupApps       = $true
$TuneServices          = $true
$SetBalancedPowerPlan  = $true
$DisablePcieLSPM       = $true    # auto-disabled on battery devices below
$GamingTweaks          = $true
$DisableNotificationsToasts = $true
$DisableVBS            = $true    # OFF: gains ~3-8% FPS in some games, reduces exploit protection. Set $false to keep Memory Integrity on.
$AutoDetectDefenderExclusions = $true
$ExtraDefenderExclusionPaths  = @()
$SetWindowsUpdateRestartNotify = $true
$SetDeliveryOptimizationLanOnly = $true  # Windows Update P2P: local-network peering on, internet peering off
$EnableAdminForLaps = $false  # OFF by default: enables built-in Administrator, NO password set here -
                               # pair with a Windows LAPS policy in Intune to actually manage/rotate the
                               # password. Never set a static password here or anywhere - see README.
$SetRegionalPreferences = $true   # 12-hour time, dd-MM-yyyy
$SetPrintersToA4        = $true
$InstallApps            = $true
$DeployAdBlocker        = $true
$SetupResolutionWatcher = $true   # writes watcher files + scheduled task

$AppsToInstall = @(
    @{ Id = 'Google.Chrome';    Name = 'Google Chrome' },
    @{ Id = 'Microsoft.Office'; Name = 'Microsoft 365' },
    @{ Id = 'RARLab.WinRAR';    Name = 'WinRAR' }
)

$StartupKeepKeywords = @(
    'nvidia','amd','radeon','intel','realtek','audio','synaptics','elan',
    'steam','epic','gog','ubisoft','battle.net','ea desktop','origin',
    'legion','lenovo','armoury','asus','msi center','g-helper',
    'rgb','icue','synapse','aura','lighting','fancontrol','fan control',
    'lghub','logitech','razer','corsair','steelseries',
    'defender','security','windows security'
)

function Write-Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }

function Set-RegistryValue {
    param($Path, $Name, $Value, $Type = 'DWord')
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "Skipped $Path\$Name (access denied - some policy keys are locked even for admins)" -ForegroundColor DarkYellow
    }
}

# ============================================================
# 1 - HARDWARE DETECTION
# ============================================================
Write-Section "Hardware detection"

$enclosure = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue
$cs   = Get-CimInstance Win32_ComputerSystem
$board= Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
$gpus = Get-CimInstance Win32_VideoController

$chassisCode = if ($enclosure -and $enclosure.ChassisTypes) { $enclosure.ChassisTypes[0] } else { 0 }
$deviceCategory = switch ($chassisCode) {
    { $_ -in 9,10,14 } { "Laptop"; break }
    11                 { "Handheld"; break }
    { $_ -in 3,4,6,7 } { "Desktop"; break }
    13                 { "All-in-One"; break }
    30                 { "Tablet"; break }
    { $_ -in 31,32 }   { "Convertible/Detachable"; break }
    default            { if ($cs.PCSystemType -eq 2) { "Laptop (assumed)" } else { "Desktop (assumed)" } }
}

$manufacturer = $cs.Manufacturer
$model = $cs.Model
if ($model -match 'To be filled|System Product Name|Default string') {
    $model = "$($board.Manufacturer) $($board.Product)".Trim()
    if (-not $manufacturer -or $manufacturer -match 'To be filled') { $manufacturer = $board.Manufacturer }
}

Write-Host "  Category     : $deviceCategory"
Write-Host "  Manufacturer : $manufacturer"
Write-Host "  Model        : $model"
Write-Host "  CPU          : $($cpu.Name)"
foreach ($gpu in $gpus) {
    Write-Host "`n  GPU: $($gpu.Name)"
    Write-Host "    Driver: $($gpu.DriverVersion)  ($($gpu.DriverDate))"
    $vendorPage = switch -Wildcard ($gpu.Name) {
        "*NVIDIA*"  { "https://www.nvidia.com/Download/index.aspx"; break }
        "*GeForce*" { "https://www.nvidia.com/Download/index.aspx"; break }
        "*AMD*"     { "https://www.amd.com/en/support"; break }
        "*Radeon*"  { "https://www.amd.com/en/support"; break }
        "*Intel*"   { "https://www.intel.com/content/www/us/en/support/detect.html"; break }
        default     { $null }
    }
    if ($vendorPage) { Write-Host "    Updates: $vendorPage" -ForegroundColor Yellow }
}

# Companion app: check installed, open a SEARCH tab if missing (never downloads)
function Test-AppInstalled {
    param([string[]]$NamePatterns)
    foreach ($p in $NamePatterns) { if (Get-AppxPackage -Name "*$p*" -ErrorAction SilentlyContinue) { return $true } }
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $installed = Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty DisplayName -ErrorAction SilentlyContinue
    foreach ($p in $NamePatterns) { if ($installed -match [regex]::Escape($p)) { return $true } }
    return $false
}

$mfrLower = "$manufacturer $model".ToLower()
$companionApp = $null
if ($mfrLower -match 'lenovo') {
    $companionApp = if ($mfrLower -match 'legion go' -or $deviceCategory -eq 'Handheld') { 'Legion Space' } else { 'Lenovo Vantage' }
} elseif ($mfrLower -match 'asus|asustek|rog') { $companionApp = 'Armoury Crate' }
elseif ($mfrLower -match 'msi')               { $companionApp = 'MSI Center' }
elseif ($mfrLower -match 'alienware')         { $companionApp = 'Alienware Command Center' }
elseif ($mfrLower -match 'dell')              { $companionApp = 'Dell Power Manager' }
elseif ($mfrLower -match 'omen')              { $companionApp = 'Omen Gaming Hub' }
elseif ($mfrLower -match 'hp')                { $companionApp = 'HP Command Center' }
elseif ($mfrLower -match 'predator')          { $companionApp = 'PredatorSense' }
elseif ($mfrLower -match 'acer')              { $companionApp = 'Acer Care Center' }

if ($companionApp) {
    Write-Host "`n  Companion app: $companionApp"
    if (Test-AppInstalled -NamePatterns @($companionApp)) {
        Write-Host "    Already installed." -ForegroundColor Green
    } else {
        Write-Host "    Not installed - opening a search in your browser..." -ForegroundColor Yellow
        try { Start-Process ("https://www.bing.com/search?q=" + [uri]::EscapeDataString("$companionApp download")) -ErrorAction Stop } catch {}
    }
}

# ---- Device-aware overrides ----
$isBatteryDevice = $false
if ($deviceCategory -match 'Laptop|Handheld|Tablet|Convertible') { $isBatteryDevice = $true }
elseif (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) { $isBatteryDevice = $true }

if ($isBatteryDevice -and $DisablePcieLSPM) {
    $DisablePcieLSPM = $false
    Write-Host "`n  Battery device: leaving PCIe Link State Power Mgmt ENABLED (disabling it" -ForegroundColor Yellow
    Write-Host "  gains a little FPS but measurably increases power draw)." -ForegroundColor Yellow
} elseif (-not $isBatteryDevice) {
    Write-Host "`n  Desktop/AC device: applying full performance settings." -ForegroundColor Green
}

# ============================================================
# 2 - DEBLOAT
# ============================================================
Write-Section "Debloat"
if ($RemoveBingWeather)  { Get-AppxPackage -AllUsers *BingWeather* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue }
if ($RemoveSpotify)      { Get-AppxPackage -AllUsers *Spotify*     | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue }
if ($RemoveZune)         { Get-AppxPackage -AllUsers *Zune*        | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue }
if ($RemoveMixedReality) { Get-AppxPackage -AllUsers *Microsoft.MixedReality* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue }
if ($RemoveXbox) {
    Get-AppxPackage -AllUsers *Xbox* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like "*Xbox*" } |
        Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
}
if ($RemoveOemBloatware) {
    foreach ($pattern in @('*McAfee*','*Norton*','*WildTangent*')) {
        Get-Package -Name $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            try { Write-Host "  Uninstalling $($_.Name)..."; $_ | Uninstall-Package -Force -ErrorAction Stop }
            catch { Write-Host "  Could not silently remove $($_.Name) - use Settings > Apps" -ForegroundColor DarkYellow }
        }
    }
    Write-Host "  Not auto-removed (needs your judgment): Office, Lenovo Vantage, Dell/HP Support Assist." -ForegroundColor Yellow
}

# ============================================================
# 3 - TELEMETRY & PRIVACY
# ============================================================
Write-Section "Telemetry & privacy"
if ($DisableTelemetry)     { Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0 }
if ($DisableAdvertisingId) { Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 }
if ($TuneDiagnosticsFeedback) {
    Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
    Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules' 'PeriodInNanoSeconds' 0
    Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsMSACloudSearchEnabled' 0
    Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsAADCloudSearchEnabled' 0
    $cdm = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in @('SubscribedContent-338388Enabled','SubscribedContent-338389Enabled',
                     'SubscribedContent-353694Enabled','SubscribedContent-353696Enabled',
                     'SilentInstalledAppsEnabled','SystemPaneSuggestionsEnabled',
                     'PreInstalledAppsEnabled','OemPreInstalledAppsEnabled',
                     'RotatingLockScreenEnabled','SoftLandingEnabled')) {
        Set-RegistryValue $cdm $n 0
    }
}
if ($ClearDiagnosticDataNow) {
    try {
        Get-ChildItem "$env:ProgramData\Microsoft\Diagnosis" -Recurse -File -ErrorAction Stop |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "  Diagnostic data cache cleared."
    } catch { Write-Host "  Nothing to clear (not critical)." -ForegroundColor DarkYellow }
}

# ============================================================
# 4 - WIDGETS / COPILOT / WEB SEARCH
# ============================================================
Write-Section "Widgets, Copilot, web search"
if ($RemoveWidgets) {
    Get-AppxPackage -AllUsers *WebExperience* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like "*WebExperience*" } |
        Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
}
if ($RemoveCopilot) {
    Get-AppxPackage -AllUsers *Copilot* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like "*Copilot*" } |
        Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
    Set-RegistryValue 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-RegistryValue 'HKLM:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
}
if ($DisableWebSearch) {
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1
}

# ============================================================
# 5 - BACKGROUND APPS & STARTUP
# ============================================================
if ($DisableBackgroundApps) {
    Write-Section "Background apps"
    $bgPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
    if (Test-Path $bgPath) {
        Get-ChildItem $bgPath | ForEach-Object {
            Set-RegistryValue $_.PSPath 'Disabled' 1
            Set-RegistryValue $_.PSPath 'DisabledByUser' 1
        }
        Write-Host "  Background access disabled for all listed apps."
    } else { Write-Host "  No background app entries found." -ForegroundColor DarkYellow }
}

if ($TuneStartupApps) {
    Write-Section "Startup apps"
    $runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $approved = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    if (-not (Test-Path $approved)) { New-Item -Path $approved -Force | Out-Null }
    if (Test-Path $runKey) {
        foreach ($name in (Get-Item $runKey).Property) {
            $cmd = (Get-ItemProperty -Path $runKey -Name $name).$name
            $keep = $false
            foreach ($kw in $StartupKeepKeywords) {
                if ($name -match [regex]::Escape($kw) -or $cmd -match [regex]::Escape($kw)) { $keep = $true; break }
            }
            if ($keep) { Write-Host "  Keeping: $name" }
            else {
                Set-ItemProperty -Path $approved -Name $name -Value ([byte[]](0x03,0,0,0,0,0,0,0,0,0,0,0)) -Type Binary -Force -ErrorAction SilentlyContinue
                Write-Host "  Disabled: $name"
            }
        }
    }
    Write-Host "  (HKCU Run entries only - machine-wide entries left alone.)" -ForegroundColor DarkYellow
}

# ============================================================
# 6 - SERVICES
# ============================================================
if ($TuneServices) {
    Write-Section "Services -> Manual"
    foreach ($svc in @('DiagTrack','dmwappushservice','PrintNotify','WSearch','SysMain')) {
        if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
            Set-Service -Name $svc -StartupType Manual
            Write-Host "  $svc -> Manual"
        }
    }
    Write-Host "  Windows Update / Defender / Security Center untouched." -ForegroundColor Green
}

# ============================================================
# 7 - POWER
# ============================================================
if ($SetBalancedPowerPlan) {
    Write-Section "Power plan: Balanced"
    powercfg /setactive SCHEME_BALANCED
    powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5
    powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100
    if ($isBatteryDevice) {
        powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5
        powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100
        Write-Host "  Applied to AC + DC (battery) profiles."
    } else { Write-Host "  Applied to AC profile." }
    powercfg /setactive SCHEME_CURRENT
}
if ($DisablePcieLSPM) {
    Write-Section "PCIe Link State Power Management: Off"
    powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
    powercfg /setactive SCHEME_CURRENT
}

# ============================================================
# 8 - GAMING
# ============================================================
if ($GamingTweaks) {
    Write-Section "Gaming"
    Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Set-RegistryValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
    Write-Host "  Game Mode on, Game Bar off, HAGS on."

    # Optimizations for windowed games - DirectXUserGlobalSettings is a semicolon
    # string that also holds AutoHDR, so parse and merge rather than overwrite.
    try {
        $gpuPref = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
        $gfx     = 'HKCU:\Software\Microsoft\DirectX\GraphicsSettings'
        if (-not (Test-Path $gpuPref)) { New-Item -Path $gpuPref -Force -ErrorAction Stop | Out-Null }
        $existing = (Get-ItemProperty -Path $gpuPref -Name 'DirectXUserGlobalSettings' -ErrorAction SilentlyContinue).DirectXUserGlobalSettings
        $settings = [ordered]@{}
        if ($existing) {
            foreach ($pair in $existing.Split(';', [StringSplitOptions]::RemoveEmptyEntries)) {
                $kv = $pair.Split('=', 2)
                if ($kv.Count -eq 2) { $settings[$kv[0].Trim()] = $kv[1].Trim() }
            }
        }
        $settings['SwapEffectUpgradeEnable'] = '1'
        $newVal = (($settings.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';') + ';'
        Set-ItemProperty -Path $gpuPref -Name 'DirectXUserGlobalSettings' -Value $newVal -Type String -Force -ErrorAction Stop
        if (-not (Test-Path $gfx)) { New-Item -Path $gfx -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $gfx -Name 'SwapEffectUpgradeCache' -Value 1 -Type DWord -Force -ErrorAction Stop
        Write-Host "  Optimizations for windowed games: ENABLED"
    } catch { Write-Host "  Windowed-game optimizations failed: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}

# ============================================================
# 9 - DEFENDER EXCLUSIONS
# ============================================================
Write-Section "Defender exclusions"
$exclusions = @($ExtraDefenderExclusionPaths)
if ($AutoDetectDefenderExclusions) {
    foreach ($c in @("${env:ProgramFiles(x86)}\Steam", "C:\SteamLibrary",
                     "$env:ProgramFiles\Epic Games", "${env:ProgramFiles(x86)}\GOG Galaxy",
                     "C:\GOG Games", "C:\XboxGames", "$env:ProgramFiles\WindowsApps")) {
        if ($c -and (Test-Path $c)) { $exclusions += $c }
    }
}
$exclusions = $exclusions | Select-Object -Unique
foreach ($path in $exclusions) {
    if (Test-Path $path) { Add-MpPreference -ExclusionPath $path; Write-Host "  Excluded: $path" }
}
if ($exclusions.Count -eq 0) { Write-Host "  No game folders found." -ForegroundColor DarkYellow }

# ============================================================
# 10 - WINDOWS UPDATE / VBS / NOTIFICATIONS
# ============================================================
if ($SetWindowsUpdateRestartNotify) {
    Set-RegistryValue 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'RestartNotificationsAllowed2' 1
    Write-Host "`n  Windows Update: notify before auto-restart."
}
if ($SetDeliveryOptimizationLanOnly) {
    # Delivery Optimization download mode. Value 1 = "Lan" = peer-download from
    # other PCs on your local network is allowed, but peering over the open
    # internet is not. This is both requirements at once: internet sharing is
    # off, and if you're on a network with peers, local downloads happen
    # automatically - Lan mode falls back to a normal download when no peers
    # are found, so no separate network-detection logic is needed.
    # Policy path is authoritative; the Config path keeps Settings UI in sync.
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 1
    Set-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 1
    Write-Host "  Windows Update delivery: local-network sharing only, internet sharing off."
    Write-Host "  (Settings > Windows Update > Delivery Optimization will show this as" -ForegroundColor DarkYellow
    Write-Host "  managed, since it's set by policy rather than the UI toggle.)" -ForegroundColor DarkYellow
}
if ($EnableAdminForLaps) {
    Write-Section "Built-in Administrator account (for Windows LAPS - no password set here)"
    try {
        net user Administrator /active:yes 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Enabled. NO password was set by this script." -ForegroundColor Green
            Write-Host "  This account is now usable but UNMANAGED until a Windows LAPS policy" -ForegroundColor Yellow
            Write-Host "  targets it - configure one in Intune now: Endpoint security > Account" -ForegroundColor Yellow
            Write-Host "  protection > Windows LAPS. Until that policy applies, don't rely on this" -ForegroundColor Yellow
            Write-Host "  account for access - it has no controlled credential yet." -ForegroundColor Yellow
        } else {
            Write-Host "  'net user' exited with code $LASTEXITCODE - account may not be enabled." -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "  Failed to enable: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}
if ($DisableVBS) {
    Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
    Write-Host "  VBS / Memory Integrity: OFF (reboot required; reduces exploit protection)." -ForegroundColor Yellow
}
if ($DisableNotificationsToasts) {
    Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
    Write-Host "  Notifications: OFF"
}

# ============================================================
# 11 - REGIONAL: 12-hour time, dd-MM-yyyy
# ============================================================
if ($SetRegionalPreferences) {
    Write-Section "Regional (12-hour time, dd-MM-yyyy)"
    $intl = 'HKCU:\Control Panel\International'
    $desired = @{ sShortDate='dd-MM-yyyy'; sLongDate='dd MMMM yyyy'; sShortTime='h:mm tt'
                  sTimeFormat='h:mm:ss tt'; iTime='0'; iTLZero='0' }
    foreach ($k in $desired.Keys) {
        $cur = (Get-ItemProperty -Path $intl -Name $k -ErrorAction SilentlyContinue).$k
        if ($cur -ne $desired[$k]) { Set-ItemProperty -Path $intl -Name $k -Value $desired[$k] -Force; Write-Host "  $k : '$cur' -> '$($desired[$k])'" }
        else { Write-Host "  $k : already correct" -ForegroundColor DarkGray }
    }
}

# ============================================================
# 12 - PAPER SIZE: A4  (spooler-safe)
# ============================================================
if ($SetPrintersToA4) {
    Write-Section "Paper size: A4"
    $intl = 'HKCU:\Control Panel\International'
    if ((Get-ItemProperty -Path $intl -Name 'iPaperSize' -ErrorAction SilentlyContinue).iPaperSize -ne '9') {
        Set-ItemProperty -Path $intl -Name 'iPaperSize' -Value '9' -Force
        Write-Host "  Locale paper -> A4"
    } else { Write-Host "  Locale paper: already A4" -ForegroundColor DarkGray }

    # Some virtual printer drivers CRASH the spooler on Set-PrintConfiguration.
    # Skip them by name and health-check the spooler after every change.
    $skipDrivers = @('OneNote','Virtual Print Class','Fax')
    if ((Get-Service Spooler -ErrorAction SilentlyContinue).Status -ne 'Running') {
        Start-Service Spooler -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2
    }
    foreach ($p in (Get-Printer -ErrorAction SilentlyContinue)) {
        $skip = $skipDrivers | Where-Object { $p.Name -match $_ -or $p.DriverName -match $_ } | Select-Object -First 1
        if ($skip) { Write-Host "  $($p.Name) : skipped (virtual '$skip' driver - crashes spooler)" -ForegroundColor DarkGray; continue }
        try {
            $cfg = Get-PrintConfiguration -PrinterName $p.Name -ErrorAction Stop
            if ($cfg.PaperSize -ne 'A4') {
                Set-PrintConfiguration -PrinterName $p.Name -PaperSize A4 -ErrorAction Stop
                Write-Host "  $($p.Name) : $($cfg.PaperSize) -> A4" -ForegroundColor Green
            } else { Write-Host "  $($p.Name) : already A4" -ForegroundColor DarkGray }
        } catch { Write-Host "  $($p.Name) : could not change" -ForegroundColor DarkYellow }
        if ((Get-Service Spooler -ErrorAction SilentlyContinue).Status -ne 'Running') {
            Write-Host "  WARNING: spooler stopped - restarting and skipping remaining printers." -ForegroundColor Red
            Start-Service Spooler -ErrorAction SilentlyContinue
            break
        }
    }
}

# ============================================================
# 13 - APPS (winget, skip if installed)
# ============================================================
if ($InstallApps) {
    Write-Section "Applications (winget)"
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "  winget not found - install 'App Installer' from the Microsoft Store." -ForegroundColor DarkYellow
    } else {
        foreach ($app in $AppsToInstall) {
            $out = winget list --id $app.Id --exact --accept-source-agreements 2>&1 | Out-String
            if ($out -match [regex]::Escape($app.Id)) {
                Write-Host "  $($app.Name) : already installed - skipped" -ForegroundColor DarkGray
            } else {
                Write-Host "  $($app.Name) : installing..." -ForegroundColor Yellow
                winget install --id $app.Id --exact --silent --accept-package-agreements --accept-source-agreements
            }
        }
        Write-Host "  Note: Microsoft 365 needs sign-in to activate; WinRAR is trialware." -ForegroundColor Yellow
    }
}

# ============================================================
# 14 - AD BLOCKER: uBlock Origin Lite (Chrome + Edge)
# ============================================================
if ($DeployAdBlocker) {
    Write-Section "Ad blocker (per-browser: full uBlock Origin where supported, Lite where not)"

    # Manifest V2 status as of Aug 2026 decides WHICH uBlock each browser gets:
    #   Chrome  - MV2 fully removed (Chrome 151 stripped the last flags) -> uBO Lite
    #   Edge    - MV2 phase-out began Aug 2026                           -> uBO Lite
    #   Vivaldi - Chromium-based, same MV2 removal                       -> uBO Lite
    #   Firefox - supports MV2 indefinitely                              -> FULL uBO
    #   Brave   - supports FULL uBO, but self-hosts MV2 extensions and its
    #             ExtensionInstallForcelist is known-unreliable, so it is NOT
    #             force-installed here (see the note printed below).
    # Extension IDs differ per store - a Chrome Web Store ID will not install
    # from the Edge Add-ons store, which is why each entry carries its own URL.
    $CWS  = 'https://clients2.google.com/service/update2/crx'
    $EDGE = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx'

    $targets = @(
        @{ Name='Chrome';  Exe=@("$env:ProgramFiles\Google\Chrome\Application\chrome.exe","${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
           Policy='HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
           Id='ddkjiahejlhfcafbddmgiahcphecmpfh'; Url=$CWS; Flavour='uBlock Origin Lite' }
        @{ Name='Edge';    Exe=@("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe","$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")
           Policy='HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist'
           Id='cimighlppcgcoapaliogpjjdehbnofhn'; Url=$EDGE; Flavour='uBlock Origin Lite' }
        @{ Name='Vivaldi'; Exe=@("$env:LOCALAPPDATA\Vivaldi\Application\vivaldi.exe","$env:ProgramFiles\Vivaldi\Application\vivaldi.exe")
           Policy='HKLM:\SOFTWARE\Policies\Vivaldi\ExtensionInstallForcelist'
           Id='ddkjiahejlhfcafbddmgiahcphecmpfh'; Url=$CWS; Flavour='uBlock Origin Lite' }
    )

    $anyDeployed = $false
    foreach ($b in $targets) {
        $installed = $b.Exe | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $installed) { Write-Host "  $($b.Name) : not installed - skipped" -ForegroundColor DarkGray; continue }

        try {
            if (-not (Test-Path $b.Policy)) { New-Item -Path $b.Policy -Force -ErrorAction Stop | Out-Null }
            $key = Get-Item $b.Policy
            $have = $false
            foreach ($v in $key.Property) {
                if ((Get-ItemProperty $b.Policy -Name $v).$v -like "$($b.Id)*") { $have = $true; break }
            }
            if ($have) {
                Write-Host "  $($b.Name) : $($b.Flavour) already in policy" -ForegroundColor DarkGray
            } else {
                $i = 1; while ($key.Property -contains "$i") { $i++ }
                Set-ItemProperty -Path $b.Policy -Name "$i" -Value "$($b.Id);$($b.Url)" -Type String -Force -ErrorAction Stop
                Write-Host "  $($b.Name) : $($b.Flavour) queued for install" -ForegroundColor Green
            }
            $anyDeployed = $true
        } catch { Write-Host "  $($b.Name) : policy failed - $($_.Exception.Message)" -ForegroundColor DarkYellow }
    }

    # ---- Firefox: different mechanism entirely (ExtensionSettings, not a forcelist) ----
    $ffExe = @("$env:ProgramFiles\Mozilla Firefox\firefox.exe","${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($ffExe) {
        try {
            $ffKey = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\ExtensionSettings\uBlock0@raymondhill.net'
            if (-not (Test-Path $ffKey)) { New-Item -Path $ffKey -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $ffKey -Name 'installation_mode' -Value 'force_installed' -Type String -Force -ErrorAction Stop
            Set-ItemProperty -Path $ffKey -Name 'install_url' -Value 'https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi' -Type String -Force -ErrorAction Stop
            Write-Host "  Firefox : FULL uBlock Origin queued (Firefox keeps MV2 support)" -ForegroundColor Green
            $anyDeployed = $true
        } catch { Write-Host "  Firefox : policy failed - $($_.Exception.Message)" -ForegroundColor DarkYellow }
    } else {
        Write-Host "  Firefox : not installed - skipped" -ForegroundColor DarkGray
    }

    # ---- Brave: detected but deliberately not automated ----
    $braveExe = @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
                  "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe",
                  "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($braveExe) {
        Write-Host "  Brave   : detected - NOT automated, on purpose:" -ForegroundColor Yellow
        Write-Host "            - Brave already blocks ads natively via Shields (no extension needed)" -ForegroundColor Yellow
        Write-Host "            - Brave's ExtensionInstallForcelist is known-unreliable" -ForegroundColor Yellow
        Write-Host "            - Brave self-hosts MV2 extensions, so a Chrome Web Store forcelist" -ForegroundColor Yellow
        Write-Host "              would break anyway once MV2 leaves that store (31 Aug 2026)" -ForegroundColor Yellow
        Write-Host "            To get the FULL uBlock Origin in Brave: brave://settings/extensions" -ForegroundColor Yellow
        Write-Host "            -> enable the Manifest V2 section, then install uBlock Origin." -ForegroundColor Yellow
    }

    if ($anyDeployed) {
        Write-Host "`n  Installs on next browser start. Those browsers will show 'Managed by your" -ForegroundColor Yellow
        Write-Host "  organization' and the extension can't be removed from their UI - delete the" -ForegroundColor Yellow
        Write-Host "  policy registry values to undo." -ForegroundColor Yellow
    }
}

# ============================================================
# 15 - PER-GAME RESOLUTION AUTO-SWITCHING (writes its own files)
# ============================================================
if ($SetupResolutionWatcher) {
    Write-Section "Per-game resolution auto-switching"
    $cfgPath     = "$ScriptDir\game-resolutions.json"
    $watcherPath = "$ScriptDir\GameResolutionWatcher.ps1"

    if (-not (Test-Path $cfgPath)) {
        '{ "Games": { } }' | Set-Content $cfgPath
        Write-Host "  Created game-resolutions.json"
    } else {
        # Strip shipped example/placeholder entries. Left in place they count as
        # real games, which schedules the watcher for nothing - and worse, would
        # actually change resolution if a game matching a placeholder name ran.
        # Identified by their Note text, so a genuinely discovered game with the
        # same name is never removed.
        try {
            $existingCfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
            $stripped = 0
            foreach ($n in @($existingCfg.Games.PSObject.Properties.Name)) {
                $note = $existingCfg.Games.$n.Note
                if ($n -eq 'REPLACE_WITH_AAA_GAME_EXE_NAME' -or ($note -and $note -like 'example -*')) {
                    $existingCfg.Games.PSObject.Properties.Remove($n)
                    $stripped++
                }
            }
            if ($stripped -gt 0) {
                $existingCfg | ConvertTo-Json -Depth 5 | Set-Content $cfgPath
                Write-Host "  Removed $stripped placeholder entr$(if($stripped -eq 1){'y'}else{'ies'}) from game-resolutions.json"
            }
        } catch { Write-Host "  Could not read existing game-resolutions.json - leaving as-is." -ForegroundColor DarkYellow }
    }

    # Write the watcher script out so a scheduled task can point at it.
    @'
param([string]$ConfigPath = "$PSScriptRoot\game-resolutions.json")
$code = @"
using System;
using System.Runtime.InteropServices;
public class ScreenResolution {
    [StructLayout(LayoutKind.Sequential)]
    private struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize;
        public short dmDriverExtra; public int dmFields; public int dmPositionX;
        public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution;
        public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth;
        public int dmPelsHeight; public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType;
        public int dmDitherType; public int dmReserved1; public int dmReserved2;
        public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll")] private static extern int EnumDisplaySettings(string d, int m, ref DEVMODE dm);
    [DllImport("user32.dll")] private static extern int ChangeDisplaySettings(ref DEVMODE dm, int f);
    private static DEVMODE GetCurrent() {
        DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        EnumDisplaySettings(null, -1, ref dm); return dm;
    }
    public static int SetResolution(int w, int h) {
        DEVMODE dm = GetCurrent(); dm.dmPelsWidth = w; dm.dmPelsHeight = h;
        dm.dmFields = 0x00080000 | 0x00100000; return ChangeDisplaySettings(ref dm, 0x01);
    }
    public static int GetWidth()  { return GetCurrent().dmPelsWidth; }
    public static int GetHeight() { return GetCurrent().dmPelsHeight; }
}
"@
if (-not ("ScreenResolution" -as [type])) { Add-Type -TypeDefinition $code -Language CSharp }

$log = "$PSScriptRoot\resolution-watcher.log"
function Write-Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Add-Content $log }
if (-not (Test-Path $ConfigPath)) { Write-Log "Config missing"; exit 1 }

$nativeW = [ScreenResolution]::GetWidth(); $nativeH = [ScreenResolution]::GetHeight()
Write-Log "Watcher started. Native ${nativeW}x${nativeH}."
$active = $null
while ($true) {
    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $running = Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        $match = $null
        foreach ($g in $cfg.Games.PSObject.Properties.Name) {
            if ($running -contains $g) { $match = $g; break }
        }
        if ($match -and $match -ne $active) {
            $p = $cfg.Games.$match
            [ScreenResolution]::SetResolution([int]$p.Width, [int]$p.Height)
            Write-Log "Detected $match - switched to $($p.Width)x$($p.Height)"
            $active = $match
        } elseif (-not $match -and $active) {
            [ScreenResolution]::SetResolution($nativeW, $nativeH)
            Write-Log "$active closed - reverted to ${nativeW}x${nativeH}"
            $active = $null
        }
    } catch { Write-Log "Error: $($_.Exception.Message)" }
    Start-Sleep -Seconds 3
}
'@ | Set-Content $watcherPath

    # Auto-discover installed games (Steam / GOG / Epic) into the config
    $discovered = @{}
    $steamPath = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($steamPath) { $steamPath = $steamPath -replace '/','\' } else { $steamPath = "${env:ProgramFiles(x86)}\Steam" }
    if (Test-Path $steamPath) {
        $libs = @($steamPath)
        $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libs += ($m.Groups[1].Value -replace '\\\\','\')
            }
        }
        foreach ($lib in ($libs | Select-Object -Unique)) {
            $sa = Join-Path $lib 'steamapps'
            if (-not (Test-Path $sa)) { continue }
            Get-ChildItem $sa -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue | ForEach-Object {
                $c = Get-Content $_.FullName -Raw
                $nm = [regex]::Match($c, '"name"\s+"([^"]+)"'); $dir = [regex]::Match($c, '"installdir"\s+"([^"]+)"')
                if (-not $nm.Success -or -not $dir.Success) { return }
                $installDir = Join-Path $sa "common\$($dir.Groups[1].Value)"
                if (-not (Test-Path $installDir)) { return }
                # @() forces an array even when Get-ChildItem finds exactly one match - without it,
                # PowerShell returns a bare FileInfo scalar and += fails with "does not contain a
                # method named 'op_Addition'" (hit on real Steam libraries with single-exe games).
                # -Recurse -Depth 1 already includes the top-level folder itself, so a separate
                # non-recursive call would just duplicate those entries - one call covers both.
                $exes = @(Get-ChildItem $installDir -Filter '*.exe' -File -Depth 1 -Recurse -ErrorAction SilentlyContinue)
                $exes = @($exes | Where-Object { $_.Name -notmatch 'unins|setup|redist|vcredist|directx|crash|helper|updater|prereq' })
                if ($exes) {
                    $best = ($exes | Sort-Object Length -Descending | Select-Object -First 1).Name
                    $discovered[[System.IO.Path]::GetFileNameWithoutExtension($best)] = $nm.Groups[1].Value
                }
            }
        }
    }
    if (Test-Path "C:\GOG Games") {
        Get-ChildItem "C:\GOG Games" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $info = Get-ChildItem $_.FullName -Filter 'goggame-*.info' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($info) {
                try {
                    $j = Get-Content $info.FullName -Raw | ConvertFrom-Json
                    $t = $j.playTasks | Where-Object { $_.isPrimary -eq $true -and $_.path } | Select-Object -First 1
                    if ($t) { $discovered[[System.IO.Path]::GetFileNameWithoutExtension($t.path)] = $j.name }
                } catch {}
            }
        }
    }
    $epicDir = "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests"
    if (Test-Path $epicDir) {
        Get-ChildItem $epicDir -Filter '*.item' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if ($j.LaunchExecutable) { $discovered[[System.IO.Path]::GetFileNameWithoutExtension($j.LaunchExecutable)] = $j.DisplayName }
            } catch {}
        }
    }

    if ($discovered.Count -gt 0) {
        Add-Type -AssemblyName System.Windows.Forms
        $nw = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
        $nh = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $added = 0
        foreach ($proc in $discovered.Keys) {
            if ($cfg.Games.PSObject.Properties.Name -notcontains $proc) {
                $cfg.Games | Add-Member -MemberType NoteProperty -Name $proc -Value ([PSCustomObject]@{
                    Width = $nw; Height = $nh; Note = "auto-discovered: $($discovered[$proc])"
                })
                Write-Host "  Added: $proc ($($discovered[$proc])) at ${nw}x${nh}" -ForegroundColor Green
                $added++
            }
        }
        if ($added -gt 0) { $cfg | ConvertTo-Json -Depth 5 | Set-Content $cfgPath }
        else { Write-Host "  All discovered games already in config." -ForegroundColor DarkGray }
    } else {
        Write-Host "  No Steam/GOG/Epic games found to auto-discover." -ForegroundColor DarkYellow
    }

    # Register the watcher only if there's something to watch
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    if ($cfg.Games.PSObject.Properties.Name.Count -gt 0) {
        # $env:USERNAME is "SYSTEM" under unattended SYSTEM execution (e.g. an
        # Intune Platform Script), which would register the task for a
        # nonexistent interactive "SYSTEM" logon and it would never fire. Fall
        # back to whoever is actually logged into the console in that case.
        $targetUser = $env:USERNAME
        if ($targetUser -eq 'SYSTEM') {
            $consoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
            if ($consoleUser) {
                $targetUser = ($consoleUser -split '\\')[-1]
            } else {
                Write-Host "  Running as SYSTEM with no logged-in user detected - skipping the" -ForegroundColor DarkYellow
                Write-Host "  resolution watcher (it needs a real user session to run under)." -ForegroundColor DarkYellow
                $targetUser = $null
            }
        }

        if ($targetUser) {
            $action = New-ScheduledTaskAction -Execute "powershell.exe" `
                -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcherPath`""
            $trigger = New-ScheduledTaskTrigger -AtLogOn
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            $principal = New-ScheduledTaskPrincipal -UserId $targetUser -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName "GameResolutionWatcher" -Action $action -Trigger $trigger `
                -Settings $settings -Principal $principal -Force | Out-Null
            Write-Host "  Watcher scheduled - starts at every login." -ForegroundColor Green
            Write-Host "  Games default to native res; edit game-resolutions.json to lower any." -ForegroundColor Yellow
        }
    } else {
        # Actively remove a previously-registered task, so a stale watcher isn't
        # left polling every 3 seconds for games that are no longer configured.
        if (Get-ScheduledTask -TaskName "GameResolutionWatcher" -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName "GameResolutionWatcher" -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName "GameResolutionWatcher" -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  No games configured - removed the previously scheduled watcher." -ForegroundColor Yellow
        } else {
            Write-Host "  No games configured yet - watcher not scheduled." -ForegroundColor DarkYellow
        }
    }
}

# ============================================================
# 16 - PER-USER SETTINGS UNDER SYSTEM CONTEXT (Intune, etc.)
# ============================================================
# Everything above this point that writes to HKCU actually wrote to SYSTEM's
# own unused profile when running as SYSTEM - not the signed-in Entra/local
# user. This section delivers those same ~18 settings correctly by running a
# small companion script AS the real console user, via a temporary scheduled
# task. Only runs when: (a) we're SYSTEM and (b) someone is actually signed
# in - if nobody's logged in there's no user context to deliver this to, and
# it'll simply be picked up next time the device syncs while someone is.
if ($isSystemAccount) {
    Write-Section "Per-user settings (delivering to the signed-in user)"

    $consoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $consoleUser) {
        Write-Host "  No user currently signed in - per-user settings will apply next sync while" -ForegroundColor DarkYellow
        Write-Host "  someone is logged in. Machine-wide settings above already applied." -ForegroundColor DarkYellow
    } else {
        $targetUserName = ($consoleUser -split '\\')[-1]
        $userScriptPath = Join-Path $ScriptDir 'Invoke-UserScopeTweaks.ps1'

        @'
# Per-user settings - runs in the signed-in user's own context so HKCU
# actually reaches them, not SYSTEM's unused profile.
function Set-RegistryValue {
    param($Path, $Name, $Value, $Type = 'DWord')
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    } catch {}
}

Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules' 'PeriodInNanoSeconds' 0
Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsMSACloudSearchEnabled' 0
Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsAADCloudSearchEnabled' 0

$cdm = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($n in @('SubscribedContent-338388Enabled','SubscribedContent-338389Enabled',
                 'SubscribedContent-353694Enabled','SubscribedContent-353696Enabled',
                 'SilentInstalledAppsEnabled','SystemPaneSuggestionsEnabled',
                 'PreInstalledAppsEnabled','OemPreInstalledAppsEnabled',
                 'RotatingLockScreenEnabled','SoftLandingEnabled')) {
    Set-RegistryValue $cdm $n 0
}

Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
Set-RegistryValue 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1

$bgPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
if (Test-Path $bgPath) {
    Get-ChildItem $bgPath | ForEach-Object {
        Set-RegistryValue $_.PSPath 'Disabled' 1
        Set-RegistryValue $_.PSPath 'DisabledByUser' 1
    }
}

$runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$approved = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$keepKeywords = @('nvidia','amd','radeon','intel','realtek','audio','synaptics','elan',
    'steam','epic','gog','ubisoft','battle.net','ea desktop','origin','legion','lenovo',
    'armoury','asus','msi center','g-helper','rgb','icue','synapse','aura','lighting',
    'fancontrol','fan control','lghub','logitech','razer','corsair','steelseries',
    'defender','security','windows security')
if (-not (Test-Path $approved)) { New-Item -Path $approved -Force | Out-Null }
if (Test-Path $runKey) {
    foreach ($name in (Get-Item $runKey).Property) {
        $cmd = (Get-ItemProperty -Path $runKey -Name $name).$name
        $keep = $false
        foreach ($kw in $keepKeywords) {
            if ($name -match [regex]::Escape($kw) -or $cmd -match [regex]::Escape($kw)) { $keep = $true; break }
        }
        if (-not $keep) {
            Set-ItemProperty -Path $approved -Name $name -Value ([byte[]](0x03,0,0,0,0,0,0,0,0,0,0,0)) -Type Binary -Force -ErrorAction SilentlyContinue
        }
    }
}

Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 1
Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
Set-RegistryValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
Set-RegistryValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0

try {
    $gpuPref = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $gfx     = 'HKCU:\Software\Microsoft\DirectX\GraphicsSettings'
    if (-not (Test-Path $gpuPref)) { New-Item -Path $gpuPref -Force -ErrorAction Stop | Out-Null }
    $existing = (Get-ItemProperty -Path $gpuPref -Name 'DirectXUserGlobalSettings' -ErrorAction SilentlyContinue).DirectXUserGlobalSettings
    $settings = [ordered]@{}
    if ($existing) {
        foreach ($pair in $existing.Split(';', [StringSplitOptions]::RemoveEmptyEntries)) {
            $kv = $pair.Split('=', 2)
            if ($kv.Count -eq 2) { $settings[$kv[0].Trim()] = $kv[1].Trim() }
        }
    }
    $settings['SwapEffectUpgradeEnable'] = '1'
    $newVal = (($settings.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';') + ';'
    Set-ItemProperty -Path $gpuPref -Name 'DirectXUserGlobalSettings' -Value $newVal -Type String -Force -ErrorAction Stop
    if (-not (Test-Path $gfx)) { New-Item -Path $gfx -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $gfx -Name 'SwapEffectUpgradeCache' -Value 1 -Type DWord -Force -ErrorAction Stop
} catch {}

$intl = 'HKCU:\Control Panel\International'
$desired = @{ sShortDate='dd-MM-yyyy'; sLongDate='dd MMMM yyyy'; sShortTime='h:mm tt'
              sTimeFormat='h:mm:ss tt'; iTime='0'; iTLZero='0'; iPaperSize='9' }
foreach ($k in $desired.Keys) { Set-ItemProperty -Path $intl -Name $k -Value $desired[$k] -Force -ErrorAction SilentlyContinue }

"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  Per-user tweaks applied for $env:USERNAME" |
    Add-Content "$PSScriptRoot\user-scope-tweaks.log" -ErrorAction SilentlyContinue
'@ | Set-Content $userScriptPath -Encoding UTF8

        try {
            $taskName = "Win11Optimize-UserScope-Temp"
            $action = New-ScheduledTaskAction -Execute "powershell.exe" `
                -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$userScriptPath`""
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
            $principal = New-ScheduledTaskPrincipal -UserId $targetUserName -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force -ErrorAction Stop | Out-Null
            Start-Sleep -Seconds 20
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  Delivered to signed-in user: $targetUserName" -ForegroundColor Green
        } catch {
            Write-Host "  Could not deliver per-user settings: $($_.Exception.Message)" -ForegroundColor DarkYellow
            Write-Host "  Machine-wide settings above still applied correctly." -ForegroundColor DarkYellow
        }
    }
}

Write-Host "`n=========================================================" -ForegroundColor Green
Write-Host "DONE. Reboot to apply HAGS / VBS / service changes." -ForegroundColor Green
Write-Host "Restart Chrome and Edge to pick up the ad blocker." -ForegroundColor Green
Write-Host "Still manual by design: GPU driver installs (auto-installing the" -ForegroundColor Yellow
Write-Host "wrong one can break display output) and any OEM power/TDP app." -ForegroundColor Yellow
Write-Host "=========================================================" -ForegroundColor Green
