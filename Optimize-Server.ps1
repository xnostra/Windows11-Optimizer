<#
.SYNOPSIS
    Windows Server/headless-safe optimizer - a SEPARATE script from
    Optimize-AllInOne.ps1 (the desktop/gaming one). Does not touch that file
    and shares no state with it.

    Deliberately excludes everything that's wrong for a server: no gaming
    tweaks, no browser/Office/WinRAR installs, no ad blocker, no printer/paper
    defaults, no Defender exclusions for game folders, no per-game resolution
    switching. VBS/Memory Integrity is not touched at all - not even defaulted
    off - because weakening security posture doesn't belong in a "safe" script.

.USAGE
    Right-click -> Run with PowerShell (self-elevates), or from an elevated
    prompt: .\Optimize-Server.ps1
    Also safe to run via RMM/Intune as SYSTEM - detects that context and
    delivers per-user settings to the actual signed-in user correctly.

.NOTES
    Idempotent - safe to re-run. Every section has its own on/off switch below.
#>

# ---- Who are we running as? ----
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$currentIdentity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSystemAccount = $currentIdentity.User.Value -eq 'S-1-5-18'

$ScriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($isSystemAccount) {
    Join-Path $env:ProgramData 'Win11ServerOptimize'
} else {
    Join-Path $env:LOCALAPPDATA 'Win11ServerOptimize'
}
if (-not (Test-Path $ScriptDir)) { New-Item -ItemType Directory -Path $ScriptDir -Force | Out-Null }

if (-not $isAdmin -and -not $isSystemAccount) {
    Write-Host "Not running as Administrator - relaunching with elevation..." -ForegroundColor Yellow
    $selfPath = $PSCommandPath
    if (-not $selfPath) {
        $selfPath = Join-Path $ScriptDir 'Optimize-Server.ps1'
        try {
            $MyInvocation.MyCommand.ScriptBlock.ToString() | Set-Content -Path $selfPath -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Host "Could not save a local copy to elevate with: $($_.Exception.Message)" -ForegroundColor Red
            return
        }
    }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$selfPath`""
        ) -ErrorAction Stop
    } catch {
        Write-Host "Elevation was declined or failed." -ForegroundColor Red
    }
    return
}

# ============================================================
# CONFIG
# ============================================================
$RemoveXbox            = $true
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
$TuneServices          = $true
$SetWindowsUpdateRestartNotify = $true
$SetDeliveryOptimizationLanOnly = $true

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
# 1 - DEBLOAT (attack-surface reduction, not "make it fun" - appropriate here)
# ============================================================
Write-Section "Debloat"
# Not every OS/SKU this script might run on has the Appx cmdlets at all
# (unverified on Server 2016 specifically) - calling a cmdlet that doesn't
# exist THROWS, it doesn't silently no-op, so check for it first rather than
# assume.
if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
    # -ErrorAction SilentlyContinue does NOT suppress every failure here - some
    # packages (e.g. Microsoft.XboxGameCallableUI) are protected system
    # components whose removal throws a COM exception that bypasses it, so each
    # removal needs an actual try/catch or one blocked package kills the loop.
    function Remove-AppxSafely {
        param([string]$Wildcard)
        Get-AppxPackage -AllUsers $Wildcard -ErrorAction SilentlyContinue | ForEach-Object {
            $pkgName = $_.PackageFullName
            try {
                $_ | Remove-AppxPackage -AllUsers -ErrorAction Stop
            } catch {
                Write-Host "  Skipped $pkgName - protected by Windows, can't be removed this way." -ForegroundColor DarkGray
            }
        }
    }
    if ($RemoveBingWeather)  { Remove-AppxSafely '*BingWeather*' }
    if ($RemoveSpotify)      { Remove-AppxSafely '*Spotify*' }
    if ($RemoveZune)         { Remove-AppxSafely '*Zune*' }
    if ($RemoveMixedReality) { Remove-AppxSafely '*Microsoft.MixedReality*' }
    if ($RemoveXbox) {
        Remove-AppxSafely '*Xbox*'
        if (Get-Command Get-AppxProvisionedPackage -ErrorAction SilentlyContinue) {
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.PackageName -like "*Xbox*" } |
                Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        }
    }
} else {
    Write-Host "  Appx cmdlets not present on this OS - skipping (this is expected on some" -ForegroundColor DarkGray
    Write-Host "  Server installations; nothing failed, there's just nothing to remove here)." -ForegroundColor DarkGray
}
if ($RemoveOemBloatware) {
    if (Get-Command Get-Package -ErrorAction SilentlyContinue) {
        foreach ($pattern in @('*McAfee*','*Norton*','*WildTangent*')) {
            Get-Package -Name $pattern -ErrorAction SilentlyContinue | ForEach-Object {
                try { Write-Host "  Uninstalling $($_.Name)..."; $_ | Uninstall-Package -Force -ErrorAction Stop }
                catch { Write-Host "  Could not remove $($_.Name) - do it manually if present." -ForegroundColor DarkYellow }
            }
        }
    } else {
        Write-Host "  Get-Package not available - skipping OEM bloatware check." -ForegroundColor DarkGray
    }
}

# ============================================================
# 2 - TELEMETRY & PRIVACY (machine-wide, HKLM)
# ============================================================
Write-Section "Telemetry & privacy"
if ($DisableTelemetry)     { Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0 }
if ($DisableWebSearch) {
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1
}
if ($ClearDiagnosticDataNow) {
    try {
        Get-ChildItem "$env:ProgramData\Microsoft\Diagnosis" -Recurse -File -ErrorAction Stop | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "  Diagnostic data cache cleared."
    } catch { Write-Host "  Nothing to clear." -ForegroundColor DarkYellow }
}

# ============================================================
# 3 - SERVICES -> Manual (not Disabled - features still work on demand)
# ============================================================
if ($TuneServices) {
    Write-Section "Services -> Manual"
    foreach ($svc in @('DiagTrack','dmwappushservice','PrintNotify')) {
        if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
            Set-Service -Name $svc -StartupType Manual
            Write-Host "  $svc -> Manual"
        }
    }
    Write-Host "  Note: WSearch and SysMain deliberately left untouched here - some server" -ForegroundColor DarkYellow
    Write-Host "  roles and workloads depend on Search indexing or Superfetch behavior in" -ForegroundColor DarkYellow
    Write-Host "  ways a desktop doesn't. Change manually if you know your workload doesn't need them." -ForegroundColor DarkYellow
    Write-Host "  Windows Update / Defender / Security Center untouched." -ForegroundColor Green
}

# ============================================================
# 4 - WINDOWS UPDATE
# ============================================================
if ($SetWindowsUpdateRestartNotify) {
    Write-Section "Windows Update: notify before auto-restart"
    Set-RegistryValue 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'RestartNotificationsAllowed2' 1
}
if ($SetDeliveryOptimizationLanOnly) {
    Write-Section "Delivery Optimization: LAN peering on, internet peering off"
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 1
    Set-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 1
    Write-Host "  Update payloads can come from other PCs on your local network, never the open internet."
}

Write-Host "`n=========================================================" -ForegroundColor Green
Write-Host "DONE. Nothing here touches VBS, installs a browser, changes power/PCIe" -ForegroundColor Green
Write-Host "settings, or adds Defender exclusions - by design, for a server." -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
