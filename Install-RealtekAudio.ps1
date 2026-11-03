<#
.SYNOPSIS
    Automated zero-reboot installer for Realtek High Definition Audio (R2.83 / 6.0.1.8186 WHQL)
    on Windows 11 (x64) laptops and all-in-one systems with built-in Realtek speakers.

.DESCRIPTION
    Designed for unattended enterprise provisioning (SCCM / Microsoft Intune / GPO / PDQ / RMM)
    as well as interactive technician deployment on clean or updated Windows 11 installations:

      1. Validates 64-bit Windows 11 client OS (Build >= 22000).
      2. Verifies the presence of a supported onboard Realtek audio codec (HDAUDIO or INTELAUDIO
         VEN_10EC) AND built-in speakers before modifying the system. Non-matching machines exit
         cleanly with code 2 (Not Applicable).
      3. Verifies WHQL catalog integrity (HDXRT.CAT signed by Microsoft Windows Hardware
         Compatibility Publisher) in the companion 'drivers' directory.
      4. Automatically stages driver files locally when executed from an SMB/UNC network share
         so Windows PnP (drvinst.exe running as SYSTEM) never encounters double-hop access errors.
      5. Stops the Windows Audio stack and removes conflicting OEM/Windows Update UAD driver and
         Extension INF packages targeting the Realtek audio codec without touching network, camera,
         Bluetooth, or GPU/HDMI audio drivers.
      6. Force-binds the WHQL driver (HDXRT.inf or HDXSST.inf v6.0.1.8186) via Win32 API
         newdev.dll!UpdateDriverForPlugAndPlayDevicesW with INSTALLFLAG_FORCE (0x1), overriding
         higher-ranked (0x00FF0001) broken SUBSYS UAD drivers without requiring a system reboot.
      7. Configures Realtek HD Audio Manager background startup (RTHDVCPL -> RAVCpl64.exe -s),
         restarts Windows Audio live, and applies a scoped PnP DenyDeviceIDs policy
         (DenyDeviceIDsRetroactive = 0) so Windows Update cannot overwrite the working driver.
      8. Installs a self-contained SYSTEM Scheduled Task (RealtekHDA-ResumeRecovery) and local
         recovery script (C:\ProgramData\RealtekHDA\Resume-RealtekAudio.ps1) triggered on
         system resume from Hibernation (S4) / Sleep (Event IDs 1, 107, 507) that performs a
         clean zero-veto PnP device restart (IRP_MN_START_DEVICE) so the codec and speaker
         amplifier are fully re-initialized after S4 power loss on modern laptop platforms.

.PARAMETER DriverDir
    Path to the directory containing the extracted WHQL driver binaries (defaults to .\drivers).

.PARAMETER CheckOnly
    Run OS, hardware, built-in speaker, and driver package checks without modifying the system.

.PARAMETER ForceReinstall
    Reinstall the driver even if clean Realtek version 6.0.1.8186 is already active.

.PARAMETER SkipWindowsUpdateLock
    Do not configure the device-scoped PnP policy blocking future Windows Update driver replacements.

.PARAMETER NoElevate
    Fail immediately with exit code 3 instead of prompting for UAC elevation when not running as Administrator.

.PARAMETER PlayTestSound
    Play a short system notification sound after installation (ignored in non-interactive Session 0).

.PARAMETER Return3010OnRebootFlag
    Return standard deployment exit code 3010 (ERROR_SUCCESS_REBOOT_REQUIRED) if PnP reports a reboot flag.

.PARAMETER LogPath
    Path to the execution log file (defaults to %TEMP%\Realtek_HDA_Install.log, or %WINDIR%\Temp under SYSTEM).

.NOTES
    Exit Codes:
      0    - Success (installed or already compliant)
      1    - Fatal error during installation
      2    - Not applicable (unsupported OS, no Realtek audio codec, or no built-in speakers)
      3    - Insufficient privileges (Administrator / SYSTEM required)
      3010 - Success with reboot flag (only when -Return3010OnRebootFlag is specified)
#>
[CmdletBinding()]
param(
    [string]$DriverDir = "",
    [switch]$CheckOnly,
    [switch]$ForceReinstall,
    [switch]$SkipWindowsUpdateLock,
    [switch]$NoElevate,
    [switch]$PlayTestSound,
    [switch]$Return3010OnRebootFlag,
    [string]$LogPath = "",
    [switch]$InternalElevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$TargetDriverVersion = "6.0.1.8186"
$ExpectedFileCount   = 179

# Complete list of 67 Realtek HDA / Intel SST codec Device IDs supported by R2.83 (HDXRT.inf & HDXSST.inf)
$SupportedCodecDevIds = @(
    "0210","0215","0221","0225","0230","0231","0233","0234","0235","0236",
    "0255","0256","0257","0260","0262","0267","0268","0269","0270","0272",
    "0273","0274","0275","0276","0280","0282","0283","0284","0285","0286",
    "0288","0289","0290","0292","0293","0294","0295","0296","0298","0299",
    "0383","0660","0662","0663","0665","0667","0668","0670","0671","0672",
    "0676","0680","0700","0701","0862","0867","0882","0883","0885","0887",
    "0888","0889","0892","0899","0900","1168","1220"
)

if ([string]::IsNullOrWhiteSpace($DriverDir)) {
    $DriverDir = Join-Path $PSScriptRoot "drivers"
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $defaultLogDir = if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        Join-Path $env:SystemRoot "Temp"
    } else {
        $env:TEMP
    }
    $LogPath = Join-Path $defaultLogDir "Realtek_HDA_Install.log"
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "OK", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host $line -ForegroundColor $color
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsInteractiveSession {
    try {
        $proc = Get-Process -Id $PID -ErrorAction Stop
        return ([Environment]::UserInteractive -and ($proc.SessionId -ne 0))
    } catch {
        return $false
    }
}

function Assert-Windows11x64 {
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw "Unsupported architecture: 32-bit OS detected. This package requires 64-bit Windows 11."
    }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $build = [int]$os.BuildNumber
    # Windows 11 client releases start at Build 22000 with ProductType == 1 (Workstation)
    if ($build -lt 22000 -or $os.ProductType -ne 1) {
        throw "Unsupported OS: $($os.Caption.Trim()) (Build $build, ProductType $($os.ProductType)). Windows 11 (Build 22000+) is required."
    }

    Write-Log "OS check passed: $($os.Caption.Trim()) (Version $($os.Version), Build $build, x64)." "OK"
}

function Assert-DriverPackageIntegrity {
    param([Parameter(Mandatory = $true)][string]$SourceDir)

    if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
        throw "Driver directory not found: $SourceDir"
    }

    $requiredCoreFiles = @("HDXRT.inf", "HDXSST.inf", "HDXRT.CAT", "RTKVHD64.sys", "RAVCpl64.exe", "RtkCoLDR64.dll")
    foreach ($req in $requiredCoreFiles) {
        $fullReq = Join-Path $SourceDir $req
        if (-not (Test-Path -LiteralPath $fullReq -PathType Leaf)) {
            throw "Driver package is incomplete -- missing required file: $fullReq"
        }
    }

    $allFiles = @(Get-ChildItem -LiteralPath $SourceDir -File -ErrorAction Stop)
    if ($allFiles.Count -lt $ExpectedFileCount) {
        throw "Driver package file count mismatch in '$SourceDir': found $($allFiles.Count) files, expected at least $ExpectedFileCount."
    }

    $catPath = Join-Path $SourceDir "HDXRT.CAT"
    $sig = Get-AuthenticodeSignature -LiteralPath $catPath -ErrorAction Stop
    if ($sig.Status -ne "Valid") {
        throw "WHQL catalog signature validation failed for '$catPath' (Status: $($sig.Status))."
    }

    Write-Log "Driver package verified: $($allFiles.Count) files in '$SourceDir', WHQL catalog Valid ($($sig.SignerCertificate.Subject))." "OK"
}

function Get-RealtekAudioTargets {
    param(
        [switch]$AllowRescan,
        [switch]$RequireActiveEndpoint
    )

    $scanAttempt = 0
    $allPnp = @()
    while ($true) {
        $scanAttempt++
        $allPnp = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Where-Object {
            $null -ne $_.PNPDeviceID -and
            $_.PNPDeviceID -match '^(HDAUDIO|INTELAUDIO)\\FUNC_01&VEN_10EC&DEV_([0-9A-F]{4})'
        })

        if ($allPnp.Count -gt 0 -or -not $AllowRescan -or $scanAttempt -ge 2) {
            break
        }

        Write-Log "Realtek audio codec not yet visible in PnP tree; scanning hardware (pnputil /scan-devices)..." "WARN"
        $null = & "$env:SystemRoot\System32\pnputil.exe" /scan-devices 2>&1
        Start-Sleep -Seconds 2
    }

    if ($allPnp.Count -eq 0) {
        return @()
    }

    # Query MMDevices\Audio\Render directly via Registry API (locale-independent and StrictMode-safe)
    $renderEndpoints = @()
    $renderRoot = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render"
    if (Test-Path -LiteralPath $renderRoot) {
        foreach ($epKey in (Get-ChildItem -LiteralPath $renderRoot -ErrorAction SilentlyContinue)) {
            $propSubKey = $null
            try {
                $rawState = $epKey.GetValue("DeviceState", $null)
                if ($null -eq $rawState) { continue }
                # Lower 4 bits (DEVICE_STATEMASK_ALL = 0xF): 1=Active, 2=Disabled, 4=NotPresent, 8=Unplugged
                $maskedState = ([uint32]$rawState) -band 0x0000000F

                $propSubKey = $epKey.OpenSubKey("Properties")
                if ($null -eq $propSubKey) { continue }

                $parentStr   = [string]$propSubKey.GetValue("{b3f8fa53-0004-438e-9003-51a46e139bfc},2", "")
                $formFactor  = $propSubKey.GetValue("{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},0", $null)
                $jackSubType = [string]$propSubKey.GetValue("{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},8", "")
                $iconRes     = [string]$propSubKey.GetValue("{259abffc-50a7-47ce-af08-68c9a7d73366},12", "")
                $epName      = [string]$propSubKey.GetValue("{a45c254e-df1c-4efd-8020-67d146a850e0},2", "")
                $devDesc     = [string]$propSubKey.GetValue("{b3f8fa53-0004-438e-9003-51a46e139bfc},6", "")

                $isSpeakerForm = (
                    ($null -ne $formFactor -and [uint32]$formFactor -eq 1) -or
                    ($jackSubType -ieq "{DFF21CE1-F70F-11D0-B917-00A0C9223196}") -or
                    ($iconRes -match "-3010$")
                )

                $renderEndpoints += [PSCustomObject]@{
                    Guid          = $epKey.PSChildName
                    DeviceState   = [uint32]$maskedState
                    ParentString  = $parentStr
                    FormFactor    = $formFactor
                    IsSpeakerForm = [bool]$isSpeakerForm
                    EndpointName  = $epName
                    AdapterName   = $devDesc
                }
            } catch {
            } finally {
                if ($null -ne $propSubKey) {
                    $propSubKey.Dispose()
                }
            }
        }
    }

    # Check SMBIOS enclosure type for portable / all-in-one form factors (fallback when codec has no active driver yet)
    $builtinSpeakerChassisTypes = @(8, 9, 10, 11, 12, 13, 14, 18, 21, 30, 31, 32)
    $isPortableChassis = $false
    try {
        $enclosures = @(Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue)
        foreach ($enc in $enclosures) {
            if ($null -ne $enc.ChassisTypes) {
                foreach ($ct in @($enc.ChassisTypes)) {
                    if ($builtinSpeakerChassisTypes -contains [int]$ct) {
                        $isPortableChassis = $true
                    }
                }
            }
        }
    } catch {}

    $results = @()
    foreach ($dev in $allPnp) {
        $instId = [string]$dev.PNPDeviceID
        if ($instId -notmatch '^(?<Bus>HDAUDIO|INTELAUDIO)\\FUNC_01&VEN_10EC&DEV_(?<Dev>[0-9A-F]{4})(?:&SUBSYS_(?<Subsys>[0-9A-F]{8}))?') {
            continue
        }
        $bus = $Matches['Bus'].ToUpperInvariant()
        $codecDev = $Matches['Dev'].ToUpperInvariant()
        $subsys = if ($Matches.ContainsKey('Subsys') -and $null -ne $Matches['Subsys']) { $Matches['Subsys'].ToUpperInvariant() } else { "" }

        $isCodecSupported = ($SupportedCodecDevIds -contains $codecDev)
        $hwIds = @()
        if ($null -ne $dev.HardwareID) {
            $hwIds = @($dev.HardwareID | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        $primaryHwId = if ($hwIds.Count -gt 0) { [string]$hwIds[0] } else { (($instId -split '\\')[0..1] -join '\') }

        $escapedInst = [regex]::Escape($instId)
        $matchingSpeakerEps = @($renderEndpoints | Where-Object {
            $_.IsSpeakerForm -and (
                $_.ParentString -match $escapedInst -or
                $_.ParentString -match ("VEN_10EC&DEV_" + $codecDev)
            )
        })

        # Built-in internal speakers use a fixed pin connection (DeviceState 1=Active or 2=Disabled by user),
        # whereas unplugged desktop 3.5mm line-out jacks report DeviceState 8 (Unplugged).
        $activeBuiltinSpeakers = @($matchingSpeakerEps | Where-Object { $_.DeviceState -in @(1, 2) })
        $historicalSpeakers    = @($matchingSpeakerEps | Where-Object { $_.DeviceState -eq 4 })

        $errCode = if ($null -ne $dev.ConfigManagerErrorCode) { [uint32]$dev.ConfigManagerErrorCode } else { 0 }
        $svcName = [string]$dev.Service

        $hasBuiltinSpeakers = $false
        $speakerDetectionReason = ""

        if ($activeBuiltinSpeakers.Count -gt 0) {
            $hasBuiltinSpeakers = $true
            $epDesc = ($activeBuiltinSpeakers | ForEach-Object { "$($_.EndpointName) [$($_.AdapterName)]" }) -join ", "
            $speakerDetectionReason = "Active built-in speaker endpoint detected: $epDesc"
        } elseif (-not $RequireActiveEndpoint) {
            if ($historicalSpeakers.Count -gt 0 -and ($isPortableChassis -or $errCode -ne 0 -or $svcName -ieq "HdAudAddService")) {
                $hasBuiltinSpeakers = $true
                $speakerDetectionReason = "Registered built-in Realtek speaker profile found in MMDevices (codec in transition, PnP ErrorCode=$errCode)"
            } elseif ($isPortableChassis -and ($errCode -ne 0 -or [string]::IsNullOrWhiteSpace($svcName) -or $svcName -ieq "HdAudAddService")) {
                $hasBuiltinSpeakers = $true
                $speakerDetectionReason = "Portable/AIO chassis with onboard Realtek codec confirmed (driver not yet initialized, PnP ErrorCode=$errCode)"
            }
        }

        $infName = if ($bus -eq "INTELAUDIO") { "HDXSST.inf" } else { "HDXRT.inf" }

        $results += [PSCustomObject]@{
            InstanceId             = $instId
            Name                   = [string]$dev.Name
            Bus                    = $bus
            CodecDevId             = $codecDev
            Subsys                 = $subsys
            HardwareIds            = $hwIds
            PrimaryHardwareId      = $primaryHwId
            ConfigManagerErrorCode = $errCode
            IsCodecSupported       = $isCodecSupported
            HasBuiltinSpeakers     = $hasBuiltinSpeakers
            SpeakerDetectionReason = $speakerDetectionReason
            InfFileName            = $infName
        }
    }

    return $results
}

function Set-RealtekWindowsUpdateLock {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$HardwareIds,
        [Parameter(Mandatory = $true)][bool]$EnableLock
    )

    $restrictKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
    $denyListKey = Join-Path $restrictKey "DenyDeviceIDs"

    if (-not $EnableLock) {
        if (Test-Path -LiteralPath $denyListKey) {
            $props = Get-ItemProperty -LiteralPath $denyListKey -ErrorAction SilentlyContinue
            $remaining = New-Object System.Collections.Generic.List[string]
            if ($null -ne $props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -match '^\d+$') {
                        $val = [string]$p.Value
                        if ($val -notmatch 'VEN_10EC') {
                            $remaining.Add($val)
                        }
                    }
                }
            }
            Remove-Item -LiteralPath $denyListKey -Recurse -Force -ErrorAction SilentlyContinue
            if ($remaining.Count -gt 0) {
                New-Item -Path $denyListKey -Force | Out-Null
                for ($i = 0; $i -lt $remaining.Count; $i++) {
                    New-ItemProperty -LiteralPath $denyListKey -Name ([string]($i + 1)) -Value $remaining[$i] -PropertyType String -Force | Out-Null
                }
            } else {
                if (Test-Path -LiteralPath $restrictKey) {
                    Set-ItemProperty -LiteralPath $restrictKey -Name "DenyDeviceIDs" -Value 0 -Type DWord -ErrorAction SilentlyContinue
                }
            }
        }
        return
    }

    New-Item -Path $restrictKey -Force | Out-Null
    New-Item -Path $denyListKey -Force | Out-Null

    $existing = New-Object System.Collections.Generic.List[string]
    $props = Get-ItemProperty -LiteralPath $denyListKey -ErrorAction SilentlyContinue
    if ($null -ne $props) {
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -match '^\d+$') {
                $val = [string]$p.Value
                if (-not [string]::IsNullOrWhiteSpace($val) -and ($existing -notcontains $val)) {
                    $existing.Add($val)
                }
            }
        }
    }

    foreach ($id in $HardwareIds) {
        if (-not [string]::IsNullOrWhiteSpace($id) -and ($existing -notcontains $id)) {
            $existing.Add($id)
        }
    }

    Remove-Item -LiteralPath $denyListKey -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $denyListKey -Force | Out-Null
    for ($i = 0; $i -lt $existing.Count; $i++) {
        New-ItemProperty -LiteralPath $denyListKey -Name ([string]($i + 1)) -Value $existing[$i] -PropertyType String -Force | Out-Null
    }

    # DenyDeviceIDsRetroactive = 0 keeps the currently installed 6.0.1.8186 driver active
    # while blocking future Windows Update driver or UAD Extension INF replacements for these IDs.
    Set-ItemProperty -LiteralPath $restrictKey -Name "DenyDeviceIDs" -Value 1 -Type DWord -Force
    Set-ItemProperty -LiteralPath $restrictKey -Name "DenyDeviceIDsRetroactive" -Value 0 -Type DWord -Force
}

function Get-ConflictingRealtekOemInfs {
    # Locale-independent inspection of C:\Windows\INF\oem*.inf:
    #   1) All Realtek-provided packages in audio classes (MEDIA, Extension, SoftwareComponent, AudioProcessingObject)
    #   2) Any third-party UAD Extension / MEDIA INF explicitly targeting (HDAUDIO|INTELAUDIO)\FUNC_01&VEN_10EC
    # Never touches Network (Net), Camera, CardReader, Bluetooth, or Intel/AMD/NVIDIA GPU/HDMI audio packages.
    $audioClassGuids = @(
        "{4d36e96c-e325-11ce-bfc1-08002be10318}", # MEDIA
        "{e2f84ce7-8efa-411c-aa69-97454ca4cb57}", # Extension
        "{5c4c3332-344d-483c-8739-259e934c9cc8}", # SoftwareComponent
        "{5989fce8-9cd0-467d-8a6a-5419e31529d4}"  # AudioProcessingObject
    )

    $matched = @()
    foreach ($inf in (Get-ChildItem -Path "$env:SystemRoot\INF\oem*.inf" -File -ErrorAction SilentlyContinue)) {
        try {
            $rawText = Get-Content -LiteralPath $inf.FullName -Raw -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($rawText)) { continue }

            if ($rawText -notmatch '(?im)^\s*ClassGUID\s*=\s*(\{[0-9a-fA-F\-]+\})') { continue }
            $classGuid = $Matches[1].Trim().ToLowerInvariant()
            if ($audioClassGuids -notcontains $classGuid) { continue }

            $lines = $rawText -split "`r?`n"
            $providerRaw = ""
            $driverVer = ""
            $stringsMap = @{}
            $section = ""

            foreach ($rawLine in $lines) {
                $l = $rawLine.Trim()
                if ($l.Length -eq 0 -or $l.StartsWith(";")) { continue }
                if ($l -match '^\[([^\]]+)\]') {
                    $section = $Matches[1].ToLowerInvariant()
                    continue
                }
                if ($section -eq "version") {
                    if ($l -match '^Provider\s*=\s*(.+)$') {
                        $providerRaw = ($Matches[1] -split ';')[0].Trim().Trim('"')
                    } elseif ($l -match '^DriverVer\s*=\s*(.+)$') {
                        $driverVer = ($Matches[1] -split ';')[0].Trim()
                    }
                } elseif ($section -like "strings*") {
                    if ($l -match '^([^=\s]+)\s*=\s*(.+)$') {
                        $k = $Matches[1].Trim().ToLowerInvariant()
                        $v = ($Matches[2] -split ';')[0].Trim().Trim('"')
                        if (-not $stringsMap.ContainsKey($k)) {
                            $stringsMap[$k] = $v
                        }
                    }
                }
            }

            $providerResolved = $providerRaw
            if ($providerRaw -match '^%(.+)%$') {
                $tok = $Matches[1].ToLowerInvariant()
                if ($stringsMap.ContainsKey($tok)) {
                    $providerResolved = $stringsMap[$tok]
                }
            }

            $targetsRealtekCodec = (
                ($classGuid -in @("{4d36e96c-e325-11ce-bfc1-08002be10318}", "{e2f84ce7-8efa-411c-aa69-97454ca4cb57}")) -and
                ($rawText -match '(HDAUDIO|INTELAUDIO)\\FUNC_01&VEN_10EC')
            )

            if ($providerResolved -match 'Realtek' -or $targetsRealtekCodec) {
                $matched += [PSCustomObject]@{
                    OemInf    = $inf.Name
                    ClassGuid = $classGuid
                    Provider  = $providerResolved
                    DriverVer = $driverVer
                }
            }
        } catch {}
    }

    return $matched
}

function Stop-AudioStackForLiveSwap {
    Write-Log "Stopping audio services and companion processes for zero-reboot driver swap..." "INFO"
    $servicesToStop = @(
        "RtkAudioUniversalService",
        "RtkAudioService",
        "SECOMNService",
        "FMService64",
        "WavesSysSvc",
        "NahimicService",
        "Audiosrv",
        "AudioEndpointBuilder"
    )
    foreach ($svcName in $servicesToStop) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($null -ne $svc -and $svc.Status -ne "Stopped") {
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        }
    }

    $procsToStop = @(
        "audiodg",
        "RtkAudUService64",
        "RtkAudioService64",
        "FMService64",
        "WavesSvc64",
        "RAVCpl64",
        "RtkNGUI64",
        "RAVBg64"
    )
    foreach ($procName in $procsToStop) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 800
}

function Start-AudioStack {
    Write-Log "Starting Windows Audio services (AudioEndpointBuilder, Audiosrv)..." "INFO"
    foreach ($svcName in @("AudioEndpointBuilder", "Audiosrv")) {
        Set-Service -Name $svcName -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name $svcName -ErrorAction Stop
    }
}

function Remove-StaleRealtekSoftwareNodes {
    $swdPattern = '^SWD\\DRIVERENUM\\.*(REALTEK|FM|WAVES|NAHIMIC|DOLBY)(APO|SRV|APP|HSA)|^SWD\\.*VEN_10EC'
    $swdIds = New-Object System.Collections.Generic.List[string]

    try {
        foreach ($d in @(Get-PnpDevice -ErrorAction SilentlyContinue)) {
            if ($null -ne $d.InstanceId -and $d.InstanceId -match $swdPattern) {
                if ($swdIds -notcontains [string]$d.InstanceId) {
                    $swdIds.Add([string]$d.InstanceId)
                }
            }
        }
    } catch {}

    try {
        foreach ($c in @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue)) {
            if ($null -ne $c.PNPDeviceID -and $c.PNPDeviceID -match $swdPattern) {
                if ($swdIds -notcontains [string]$c.PNPDeviceID) {
                    $swdIds.Add([string]$c.PNPDeviceID)
                }
            }
        }
    } catch {}

    foreach ($id in $swdIds) {
        Write-Log "Removing UAD software component node: $id" "INFO"
        $null = & "$env:SystemRoot\System32\pnputil.exe" /remove-device "$id" 2>&1
    }
}

function Install-RealtekHibernateResumeTask {
    <#
    .SYNOPSIS
        Deploys a self-contained local recovery script and SYSTEM Scheduled Task that
        re-initializes the Realtek HDA codec (IRP_MN_START_DEVICE) upon resuming from
        Hibernation (S4) or Sleep (S3).
    .DESCRIPTION
        In RTKVHD64.sys v6.0.1.8186 (June 2017), the D3 -> D0 power restoration path
        (PowerChangeState / ALC256::SetPowerState) gates widget and external amplifier
        unmuting on a 2017 OEM Subsystem ID lookup table. On newer laptops (e.g., HP
        SUBSYS_103C8DFB), resuming from Hibernation (S4) only sends IRP_MN_SET_POWER
        (D3 -> D0) without IRP_MN_START_DEVICE, leaving the physical speaker amplifier
        uninitialized after S4 power loss while Windows Audio reports the endpoint as
        active. Performing a clean PnP device restart (with Audiosrv stopped to prevent
        handle vetoes) forces IRP_MN_START_DEVICE (HardWareInit + ResetAudioFgOnStart)
        and restores audio immediately upon wake.
    #>
    $recoveryDir        = Join-Path $env:ProgramData "RealtekHDA"
    $recoveryScriptPath = Join-Path $recoveryDir "Resume-RealtekAudio.ps1"
    $taskName           = "RealtekHDA-ResumeRecovery"

    New-Item -ItemType Directory -Path $recoveryDir -Force | Out-Null

    $recoveryScriptContent = @'
<#
.SYNOPSIS
    Automated post-hibernation (S4) / sleep resume recovery for Realtek High Definition Audio (6.0.1.8186).
    Forces a clean zero-veto PnP device restart (IRP_MN_START_DEVICE) so RTKVHD64.sys runs full
    HardWareInit and restores speaker amplifier state after S4 power loss.
#>
[CmdletBinding()]
param(
    [switch]$ManualTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$StateDir  = Join-Path $env:ProgramData "RealtekHDA"
$LogFile   = Join-Path $StateDir "Resume-RealtekAudio.log"
$StateFile = Join-Path $StateDir "last-recovery-state.json"

function Write-ResumeLog {
    param([string]$Message, [string]$Level = "INFO")
    try {
        if (Test-Path -LiteralPath $LogFile) {
            $fi = Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue
            if ($null -ne $fi -and $fi.Length -gt 262144) {
                Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force -ErrorAction SilentlyContinue
            }
        }
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        Add-Content -LiteralPath $LogFile -Value "[$ts] [$Level] $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

function Get-WakeEventStatus {
    $queryXml = @"
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and (EventID=1)]]</Select>
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=107)]]</Select>
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=507)]] and *[EventData[Data[@Name='Reason']='25']]</Select>
  </Query>
</QueryList>
"@
    $events = @(Get-WinEvent -FilterXml $queryXml -MaxEvents 6 -ErrorAction SilentlyContinue)
    $maxRecordId    = [int64]0
    $max107RecordId = [int64]0
    $maxCompletionRecordId = [int64]0

    foreach ($ev in $events) {
        $recId = [int64]$ev.RecordId
        if ($recId -gt $maxRecordId) { $maxRecordId = $recId }
        if ($ev.Id -eq 107) {
            if ($recId -gt $max107RecordId) { $max107RecordId = $recId }
        } else {
            # Event ID 1 (Power-Troubleshooter) or Event ID 507 (Reason=25: Resume from Hibernate)
            if ($recId -gt $maxCompletionRecordId) { $maxCompletionRecordId = $recId }
        }
    }

    return [PSCustomObject]@{
        MaxRecordId           = $maxRecordId
        Max107RecordId        = $max107RecordId
        MaxCompletionRecordId = $maxCompletionRecordId
    }
}

$mutex = $null
$hasHandle = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, "Global\RealtekHDA_ResumeRecovery_Mutex")
    try {
        $hasHandle = $mutex.WaitOne(30000)
    } catch [System.Threading.AbandonedMutexException] {
        $hasHandle = $true
    }

    if (-not $hasHandle) {
        Write-ResumeLog "Timed out waiting for recovery mutex; exiting." "WARN"
        exit 0
    }

    $wakeStatus = Get-WakeEventStatus

    # If triggered early by Kernel-Power 107 while DriverInitDuration (D3 -> D0) is still in progress,
    # wait monotonically (immune to RTC clock sync jumps) until Power-Troubleshooter 1 or Kernel-Power 507 is logged.
    if (-not $ManualTest -and $wakeStatus.Max107RecordId -gt $wakeStatus.MaxCompletionRecordId) {
        Write-ResumeLog "Kernel resume (RecordId=$($wakeStatus.Max107RecordId)) detected; waiting for D0 driver initialization to complete..." "INFO"
        $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($waitSw.ElapsedMilliseconds -lt 10000) {
            Start-Sleep -Milliseconds 250
            $wakeStatus = Get-WakeEventStatus
            if ($wakeStatus.MaxCompletionRecordId -gt $wakeStatus.Max107RecordId) {
                Write-ResumeLog "D0 transition complete (RecordId=$($wakeStatus.MaxCompletionRecordId), waited $($waitSw.ElapsedMilliseconds) ms)." "INFO"
                break
            }
        }
    }

    # Check if this wake cycle was already handled by an earlier trigger in the same resume sequence
    if (-not $ManualTest -and $wakeStatus.MaxRecordId -gt 0 -and (Test-Path -LiteralPath $StateFile)) {
        try {
            $saved = Get-Content -LiteralPath $StateFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($null -ne $saved -and $null -ne $saved.PSObject.Properties['LastWakeRecordId']) {
                $lastHandled = [int64]$saved.LastWakeRecordId
                if ($wakeStatus.MaxRecordId -le $lastHandled) {
                    Write-ResumeLog "Wake cycle RecordId=$($wakeStatus.MaxRecordId) already recovered (LastWakeRecordId=$lastHandled); skipping duplicate trigger." "INFO"
                    exit 0
                }
            }
        } catch {}
    }

    if (-not $ManualTest) {
        Start-Sleep -Milliseconds 500
    }

    $rtkDevices = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
        $null -ne $_.PNPDeviceID -and
        $_.PNPDeviceID -match '^(HDAUDIO|INTELAUDIO)\\FUNC_01&VEN_10EC&DEV_' -and
        $_.Service -ieq 'IntcAzAudAddService'
    })

    if ($rtkDevices.Count -eq 0) {
        Write-ResumeLog "No active Realtek HDA (IntcAzAudAddService) codec found; nothing to recover." "INFO"
        exit 0
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-ResumeLog "Starting post-resume hardware re-initialization for $($rtkDevices.Count) Realtek codec(s)..." "INFO"

    # Stop Windows Audio services so open WaveRT handles cannot veto IRP_MN_QUERY_REMOVE_DEVICE
    foreach ($svcName in @("Audiosrv", "AudioEndpointBuilder")) {
        Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name "audiodg" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300

    foreach ($dev in $rtkDevices) {
        $instId = [string]$dev.PNPDeviceID
        Write-ResumeLog "Restarting PnP device node: $instId" "INFO"
        $pnpOut = & "$env:SystemRoot\System32\pnputil.exe" /restart-device "$instId" 2>&1
        $pnpExit = $LASTEXITCODE

        # Verify DevNodeStatus has DN_STARTED (0x08) and not DN_NEED_RESTART (0x100)
        $statProp = Get-PnpDeviceProperty -InstanceId $instId -KeyName "DEVPKEY_Device_DevNodeStatus" -ErrorAction SilentlyContinue
        $devStatusBits = if ($null -ne $statProp -and $null -ne $statProp.PSObject.Properties['Data']) { [uint32]$statProp.Data } else { [uint32]0 }
        $isStarted   = (($devStatusBits -band 0x00000008) -ne 0)
        $needRestart = (($devStatusBits -band 0x00000100) -ne 0) -or (($devStatusBits -band 0x00000800) -ne 0)

        if ($pnpExit -ne 0 -or -not $isStarted -or $needRestart) {
            Write-ResumeLog "pnputil /restart-device returned code $pnpExit (DevNodeStatus=0x$('{0:X8}' -f $devStatusBits)); falling back to Disable/Enable-PnpDevice..." "WARN"
            Disable-PnpDevice -InstanceId $instId -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 400
            Enable-PnpDevice -InstanceId $instId -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 400
        }
    }

    foreach ($svcName in @("AudioEndpointBuilder", "Audiosrv")) {
        Set-Service -Name $svcName -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name $svcName -ErrorAction SilentlyContinue
    }

    $postWakeStatus = Get-WakeEventStatus
    $finalRecordId = [Math]::Max($wakeStatus.MaxRecordId, $postWakeStatus.MaxRecordId)
    if ($finalRecordId -gt 0) {
        @{
            LastWakeRecordId = $finalRecordId
            LastRecoveryUtc  = [DateTime]::UtcNow.ToString("o")
        } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8 -Force
    }

    $sw.Stop()
    Write-ResumeLog "Post-resume Realtek HDA hardware re-initialization completed in $($sw.ElapsedMilliseconds) ms (RecordId=$finalRecordId)." "OK"
} catch {
    Write-ResumeLog "Post-resume recovery error: $($_.Exception.Message)" "ERROR"
    foreach ($svcName in @("AudioEndpointBuilder", "Audiosrv")) {
        Start-Service -Name $svcName -ErrorAction SilentlyContinue
    }
    exit 1
} finally {
    if ($hasHandle -and $null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}
'@

    Set-Content -LiteralPath $recoveryScriptPath -Value $recoveryScriptContent -Encoding UTF8 -Force

    # Initialize state file with current highest wake EventRecordID so historical events do not re-trigger
    try {
        $initXml = @"
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and (EventID=1)]]</Select>
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=107)]]</Select>
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=507)]] and *[EventData[Data[@Name='Reason']='25']]</Select>
  </Query>
</QueryList>
"@
        $latestEv = @(Get-WinEvent -FilterXml $initXml -MaxEvents 1 -ErrorAction SilentlyContinue)
        if ($latestEv.Count -gt 0) {
            $stateFilePath = Join-Path $recoveryDir "last-recovery-state.json"
            @{
                LastWakeRecordId = [int64]$latestEv[0].RecordId
                LastRecoveryUtc  = [DateTime]::UtcNow.ToString("o")
            } | ConvertTo-Json | Set-Content -LiteralPath $stateFilePath -Encoding UTF8 -Force
        }
    } catch {}

    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $taskArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$recoveryScriptPath`""

    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Re-initializes the Realtek High Definition Audio codec (IRP_MN_START_DEVICE) upon resuming from Windows Hibernation (S4) or Sleep so speaker amplifier state is restored after power loss.</Description>
    <URI>\$taskName</URI>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and (EventID=1)]]&lt;/Select&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=107)]]&lt;/Select&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=507)]] and *[EventData[Data[@Name='Reason']='25']]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Priority>4</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$psExe</Command>
      <Arguments>$taskArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    $null = Register-ScheduledTask -TaskName $taskName -TaskPath "\" -Xml $taskXml -Force -ErrorAction Stop
    Write-Log "Configured S4 hibernation resume recovery task (\$taskName -> $recoveryScriptPath)." "OK"
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================

# 0. Relaunch in native 64-bit PowerShell if invoked from a 32-bit WOW64 host
#    (newdev.dll!UpdateDriverForPlugAndPlayDevicesW fails with ERROR_IN_WOW64 in 32-bit processes).
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysNativePs = Join-Path $env:SystemRoot "Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $sysNativePs) {
        $relaunchArgs = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`"",
            "-DriverDir", "`"$DriverDir`"",
            "-LogPath", "`"$LogPath`""
        )
        if ($CheckOnly)              { $relaunchArgs += "-CheckOnly" }
        if ($ForceReinstall)         { $relaunchArgs += "-ForceReinstall" }
        if ($SkipWindowsUpdateLock)  { $relaunchArgs += "-SkipWindowsUpdateLock" }
        if ($NoElevate)              { $relaunchArgs += "-NoElevate" }
        if ($PlayTestSound)          { $relaunchArgs += "-PlayTestSound" }
        if ($Return3010OnRebootFlag) { $relaunchArgs += "-Return3010OnRebootFlag" }
        $p = Start-Process -FilePath $sysNativePs -ArgumentList $relaunchArgs -Wait -PassThru -NoNewWindow
        exit $p.ExitCode
    }
}

Write-Log "=== Realtek HD Audio WHQL Automated Installer ($TargetDriverVersion) ===" "INFO"

# 1. Verify Windows 11 x64 OS and WHQL driver package integrity
try {
    Assert-Windows11x64
    $resolvedDriverDir = (Resolve-Path -LiteralPath $DriverDir -ErrorAction Stop).ProviderPath
    Assert-DriverPackageIntegrity -SourceDir $resolvedDriverDir
} catch {
    Write-Log $_.Exception.Message "ERROR"
    exit 2
}

# 2. CheckOnly mode
$isAdmin = Test-IsAdmin
if ($CheckOnly) {
    $targets = @(Get-RealtekAudioTargets -AllowRescan:$isAdmin)
    $valid = @($targets | Where-Object { $_.IsCodecSupported -and $_.HasBuiltinSpeakers })
    if ($valid.Count -eq 0) {
        if ($targets.Count -eq 0) {
            Write-Log "Compatibility check failed: no onboard Realtek audio codec (VEN_10EC) detected." "ERROR"
        } else {
            foreach ($t in $targets) {
                Write-Log "Codec $($t.InstanceId) found, but eligibility failed (SupportedCodec=$($t.IsCodecSupported), BuiltinSpeakers=$($t.HasBuiltinSpeakers))." "ERROR"
            }
        }
        exit 2
    }
    foreach ($v in $valid) {
        Write-Log "Compatibility check passed: [$($v.Name)] ID=$($v.InstanceId) -> INF=$($v.InfFileName). $($v.SpeakerDetectionReason)." "OK"
    }
    exit 0
}

# 3. Privilege check / automatic UAC elevation for interactive sessions
if (-not $isAdmin) {
    if ($NoElevate -or $InternalElevated -or -not (Test-IsInteractiveSession)) {
        Write-Log "Administrator or SYSTEM privileges are required to install drivers." "ERROR"
        exit 3
    }
    Write-Log "Requesting Administrator privileges (UAC)..." "INFO"
    $elevArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-InternalElevated",
        "-DriverDir", "`"$resolvedDriverDir`"",
        "-LogPath", "`"$LogPath`""
    )
    if ($ForceReinstall)         { $elevArgs += "-ForceReinstall" }
    if ($SkipWindowsUpdateLock)  { $elevArgs += "-SkipWindowsUpdateLock" }
    if ($PlayTestSound)          { $elevArgs += "-PlayTestSound" }
    if ($Return3010OnRebootFlag) { $elevArgs += "-Return3010OnRebootFlag" }

    try {
        $elevProc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList $elevArgs -Verb RunAs -Wait -PassThru
        exit $elevProc.ExitCode
    } catch {
        Write-Log "UAC elevation was canceled or failed: $($_.Exception.Message)" "ERROR"
        exit 3
    }
}

# 4. Pre-install verification of Realtek codec & built-in speakers (with hardware rescan capability)
$targets = @(Get-RealtekAudioTargets -AllowRescan)
$validTargets = @($targets | Where-Object { $_.IsCodecSupported -and $_.HasBuiltinSpeakers })

if ($validTargets.Count -eq 0) {
    if ($targets.Count -eq 0) {
        Write-Log "Installation skipped: no onboard Realtek audio codec (HDAUDIO/INTELAUDIO VEN_10EC) found." "ERROR"
    } else {
        foreach ($t in $targets) {
            if (-not $t.IsCodecSupported) {
                Write-Log "Installation skipped: Realtek codec DEV_$($t.CodecDevId) ($($t.InstanceId)) is not in the R2.83 supported codec list." "ERROR"
            } else {
                Write-Log "Installation skipped: no built-in speakers detected for Realtek codec ($($t.InstanceId))." "ERROR"
            }
        }
    }
    exit 2
}

foreach ($vt in $validTargets) {
    Write-Log "Target device confirmed: $($vt.Name) [$($vt.InstanceId)]" "OK"
    Write-Log "  -> $($vt.SpeakerDetectionReason)" "INFO"
    Write-Log "  -> Selected WHQL INF profile: $($vt.InfFileName)" "INFO"
}

# Idempotency check: skip reinstall if clean 6.0.1.8186 is already bound with no UAD Extension INFs
if (-not $ForceReinstall) {
    $allAlreadyClean = $true
    foreach ($vt in $validTargets) {
        $signedDrv = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object { $_.DeviceID -eq $vt.InstanceId } | Select-Object -First 1
        $pnpState = Get-PnpDevice -InstanceId $vt.InstanceId -ErrorAction SilentlyContinue
        $extProp = Get-PnpDeviceProperty -InstanceId $vt.InstanceId -KeyName "{A8B865DD-2E3D-4094-AD97-E593A70C75D6} 20" -ErrorAction SilentlyContinue
        $hasExtendedInfs = (
            $null -ne $extProp -and
            $null -ne $extProp.PSObject.Properties['Data'] -and
            $null -ne $extProp.Data -and
            @($extProp.Data).Count -gt 0
        )

        if (
            $null -eq $signedDrv -or
            [string]$signedDrv.DriverVersion -ne $TargetDriverVersion -or
            [string]$signedDrv.DriverProviderName -notmatch 'Realtek' -or
            $null -eq $pnpState -or
            [string]$pnpState.Status -ne 'OK' -or
            $hasExtendedInfs
        ) {
            $allAlreadyClean = $false
            break
        }
    }
    if ($allAlreadyClean) {
        Write-Log "Clean Realtek driver v$TargetDriverVersion is already installed and healthy. Use -ForceReinstall to reinstall." "OK"
        Remove-StaleRealtekSoftwareNodes
        Install-RealtekHibernateResumeTask
        if (-not $SkipWindowsUpdateLock) {
            $lockIds = [string[]]@(
                $validTargets | ForEach-Object {
                    $_.HardwareIds
                    ($_.Bus + "\FUNC_01&VEN_10EC&DEV_" + $_.CodecDevId)
                } | Select-Object -Unique
            )
            Set-RealtekWindowsUpdateLock -HardwareIds $lockIds -EnableLock $true
            Write-Log "Windows Update driver overwrite protection verified." "OK"
        }
        exit 0
    }
}

# 5. Compile Win32 P/Invoke bindings (newdev.dll & cfgmgr32.dll)
if (-not ("RealtekInstaller.NativeNewDev" -as [type])) {
    Add-Type -Namespace "RealtekInstaller" -Name "NativeNewDev" -MemberDefinition @'
[DllImport("newdev.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool UpdateDriverForPlugAndPlayDevicesW(
    IntPtr hwndParent,
    string HardwareId,
    string FullInfPath,
    uint InstallFlags,
    out bool bRebootRequired
);

[DllImport("cfgmgr32.dll", SetLastError = true)]
public static extern uint CMP_WaitNoPendingInstallEvents(uint dwTimeout);
'@
}

$tempStageDir = $null
$drvSearchPolKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"
$drvSearchCfgKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"
$hadPolKey = Test-Path -LiteralPath $drvSearchPolKey
$prevDontSearchWu = $null
if ($hadPolKey) {
    $polObj = Get-Item -LiteralPath $drvSearchPolKey -ErrorAction SilentlyContinue
    if ($null -ne $polObj) { $prevDontSearchWu = $polObj.GetValue("DontSearchWindowsUpdate", $null) }
}
$prevSearchOrder = $null
if (Test-Path -LiteralPath $drvSearchCfgKey) {
    $cfgObj = Get-Item -LiteralPath $drvSearchCfgKey -ErrorAction SilentlyContinue
    if ($null -ne $cfgObj) { $prevSearchOrder = $cfgObj.GetValue("SearchOrderConfig", $null) }
}

try {
    # 6. If running from a UNC/SMB share, stage driver files locally so drvinst.exe (SYSTEM) has local read access
    $effectiveDriverDir = $resolvedDriverDir
    $isUncPath = $resolvedDriverDir.StartsWith("\\")
    if ($isUncPath) {
        $tempStageDir = Join-Path $env:SystemRoot ("Temp\RealtekHDA_Stage_" + $PID)
        Write-Log "Network UNC source detected ('$resolvedDriverDir'); staging WHQL binaries locally to '$tempStageDir'..." "INFO"
        New-Item -ItemType Directory -Path $tempStageDir -Force | Out-Null
        Copy-Item -Path (Join-Path $resolvedDriverDir "*") -Destination $tempStageDir -Recurse -Force -ErrorAction Stop
        $effectiveDriverDir = $tempStageDir
    }

    # Temporarily pause online Windows Update PnP driver queries during bus rescan so Windows Update
    # cannot download a broken UAD driver in the middle of the swap
    New-Item -Path $drvSearchPolKey -Force | Out-Null
    Set-ItemProperty -LiteralPath $drvSearchPolKey -Name "DontSearchWindowsUpdate" -Value 1 -Type DWord -Force
    if (Test-Path -LiteralPath $drvSearchCfgKey) {
        Set-ItemProperty -LiteralPath $drvSearchCfgKey -Name "SearchOrderConfig" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    }

    # Lift any existing VEN_10EC installation lock while performing our own driver installation
    Set-RealtekWindowsUpdateLock -HardwareIds @() -EnableLock $false

    # 7. Stop audio stack and purge conflicting UAD / Extension packages from DriverStore
    Stop-AudioStackForLiveSwap
    Remove-StaleRealtekSoftwareNodes

    $conflictingOems = @(Get-ConflictingRealtekOemInfs)
    if ($conflictingOems.Count -gt 0) {
        Write-Log "Found $($conflictingOems.Count) conflicting audio OEM INF package(s) in DriverStore; removing..." "INFO"
        foreach ($oem in $conflictingOems) {
            Write-Log "  Deleting $($oem.OemInf) ($($oem.Provider), $($oem.DriverVer))..." "INFO"
            $null = & "$env:SystemRoot\System32\pnputil.exe" /delete-driver $oem.OemInf /uninstall /force 2>&1
        }
    }

    Remove-StaleRealtekSoftwareNodes

    # Reset the codec devnode and rescan the audio bus to clear any stale UAD ExtendedInfs entries in Enum
    Stop-AudioStackForLiveSwap
    foreach ($vt in $validTargets) {
        Write-Log "Resetting codec device node $($vt.InstanceId) for clean initialization..." "INFO"
        $null = & "$env:SystemRoot\System32\pnputil.exe" /remove-device "$($vt.InstanceId)" 2>&1
    }

    $null = & "$env:SystemRoot\System32\pnputil.exe" /scan-devices 2>&1

    foreach ($vt in $validTargets) {
        for ($waitIdx = 1; $waitIdx -le 20; $waitIdx++) {
            $reFound = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
                $null -ne $_.PNPDeviceID -and $_.PNPDeviceID -match ("^" + $vt.Bus + "\\FUNC_01&VEN_10EC&DEV_" + $vt.CodecDevId)
            })
            if ($reFound.Count -gt 0) {
                $vt.InstanceId = [string]$reFound[0].PNPDeviceID
                break
            }
            $null = & "$env:SystemRoot\System32\pnputil.exe" /scan-devices 2>&1
            Start-Sleep -Milliseconds 500
        }
    }

    $null = [RealtekInstaller.NativeNewDev]::CMP_WaitNoPendingInstallEvents(30000)
    Stop-AudioStackForLiveSwap

    # 8. Force-install WHQL driver 6.0.1.8186 via UpdateDriverForPlugAndPlayDevicesW (INSTALLFLAG_FORCE = 0x1)
    $anyRebootFlag = $false
    foreach ($vt in $validTargets) {
        $infPath = Join-Path $effectiveDriverDir $vt.InfFileName
        if (-not (Test-Path -LiteralPath $infPath -PathType Leaf)) {
            throw "Driver INF file not found: $infPath"
        }

        $pnpDev = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.PNPDeviceID -eq $vt.InstanceId } | Select-Object -First 1
        if ($null -ne $pnpDev -and $null -ne $pnpDev.ConfigManagerErrorCode -and $pnpDev.ConfigManagerErrorCode -eq 22) {
            Enable-PnpDevice -InstanceId $vt.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        }

        Write-Log "Force-binding $($vt.InfFileName) ($TargetDriverVersion) to $($vt.PrimaryHardwareId)..." "INFO"
        $rebootReq = $false
        $INSTALLFLAG_FORCE = [uint32]0x00000001
        $ok = [RealtekInstaller.NativeNewDev]::UpdateDriverForPlugAndPlayDevicesW(
            [IntPtr]::Zero,
            $vt.PrimaryHardwareId,
            $infPath,
            $INSTALLFLAG_FORCE,
            [ref]$rebootReq
        )
        if (-not $ok) {
            $win32Err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $hexErr = "0x{0:X8}" -f $win32Err
            throw "UpdateDriverForPlugAndPlayDevicesW failed with Win32 error $win32Err ($hexErr) for $($vt.PrimaryHardwareId)."
        }

        if ($rebootReq) {
            $anyRebootFlag = $true
        }
        Write-Log "Successfully installed $($vt.InfFileName) on $($vt.InstanceId) (RebootRequired=$rebootReq)." "OK"
    }

    # 9. Configure startup registry settings and disable leftover UAD services
    $runKeyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    if (Test-Path -LiteralPath $runKeyPath) {
        Remove-ItemProperty -LiteralPath $runKeyPath -Name "RtkAudUService" -ErrorAction SilentlyContinue
    }
    $ravCplPath = Join-Path $env:ProgramFiles "Realtek\Audio\HDA\RAVCpl64.exe"
    if (Test-Path -LiteralPath $ravCplPath) {
        Set-ItemProperty -LiteralPath $runKeyPath -Name "RTHDVCPL" -Value "`"$ravCplPath`" -s" -Type String -Force
        Write-Log "Configured HKLM Run autorun entry (RTHDVCPL -> RAVCpl64.exe -s)." "OK"
    }

    foreach ($staleSvcName in @("RtkAudioUniversalService", "FMService64")) {
        $staleSvc = Get-Service -Name $staleSvcName -ErrorAction SilentlyContinue
        if ($null -ne $staleSvc) {
            Stop-Service -Name $staleSvcName -Force -ErrorAction SilentlyContinue
            Set-Service -Name $staleSvcName -StartupType Disabled -ErrorAction SilentlyContinue
        }
    }

    # 10. Restart Windows Audio stack, register S4 hibernate resume recovery, and launch tray agent
    Remove-StaleRealtekSoftwareNodes
    Start-AudioStack
    Install-RealtekHibernateResumeTask
    if (Test-Path -LiteralPath $ravCplPath) {
        if (Test-IsInteractiveSession) {
            Start-Process -FilePath $ravCplPath -ArgumentList "-s" -WindowStyle Hidden -ErrorAction SilentlyContinue
        } else {
            Write-Log "Non-interactive / Session 0 context detected; RAVCpl64.exe will start automatically at user logon." "INFO"
        }
    }

    # 11. Lock codec Hardware IDs against future Windows Update overwrites
    if (-not $SkipWindowsUpdateLock) {
        $lockIds = [string[]]@(
            $validTargets | ForEach-Object {
                $_.HardwareIds
                ($_.Bus + "\FUNC_01&VEN_10EC&DEV_" + $_.CodecDevId)
            } | Select-Object -Unique
        )
        Set-RealtekWindowsUpdateLock -HardwareIds $lockIds -EnableLock $true
        Write-Log "Applied Windows Update driver overwrite lock for: $($lockIds -join ', ')." "OK"
    }

    # 12. Post-install verification of bound driver and live speaker endpoint
    Write-Log "Waiting for Windows Audio built-in speaker endpoint activation..." "INFO"
    $verifiedSpeaker = $null
    for ($attempt = 1; $attempt -le 24; $attempt++) {
        Start-Sleep -Milliseconds 500
        $postCheck = @(Get-RealtekAudioTargets -RequireActiveEndpoint)
        $ready = @($postCheck | Where-Object { $_.HasBuiltinSpeakers })
        if ($ready.Count -gt 0) {
            $verifiedSpeaker = $ready[0]
            break
        }
    }

    foreach ($vt in $validTargets) {
        $drvInfo = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object { $_.DeviceID -eq $vt.InstanceId } | Select-Object -First 1
        $devNode = Get-PnpDevice -InstanceId $vt.InstanceId -ErrorAction SilentlyContinue
        $statusText = if ($null -ne $devNode) { [string]$devNode.Status } else { "Unknown" }
        $drvName    = if ($null -ne $drvInfo) { [string]$drvInfo.DeviceName } else { "Unknown" }
        $drvVer     = if ($null -ne $drvInfo) { [string]$drvInfo.DriverVersion } else { "Unknown" }
        $drvInf     = if ($null -ne $drvInfo) { [string]$drvInfo.InfName } else { "Unknown" }
        Write-Log "Codec status: [$statusText] Bound driver: $drvName v$drvVer ($drvInf)" "OK"
    }

    if ($null -ne $verifiedSpeaker) {
        Write-Log "Audio pipeline verified! $($verifiedSpeaker.SpeakerDetectionReason)." "OK"
    } else {
        Write-Log "Driver installed, but active speaker endpoint registration is still completing." "WARN"
    }

    if ($PlayTestSound -and (Test-IsInteractiveSession)) {
        $wavPath = Join-Path $env:SystemRoot "Media\Windows Notify System Generic.wav"
        if (Test-Path -LiteralPath $wavPath) {
            try {
                Write-Log "Playing verification sound..." "INFO"
                $player = [System.Media.SoundPlayer]::new($wavPath)
                $player.PlaySync()
            } catch {
                Write-Log "Could not play verification sound: $($_.Exception.Message)" "WARN"
            }
        }
    }

    if ($anyRebootFlag) {
        Write-Log "Note: PnP reported a reboot flag for one or more components (audio is already active if endpoint check passed)." "WARN"
        if ($Return3010OnRebootFlag) {
            exit 3010
        }
    } else {
        Write-Log "Installation completed successfully with zero reboots required!" "OK"
    }
    exit 0
} catch {
    Write-Log "Installation failed: $($_.Exception.Message)" "ERROR"
    try { Start-AudioStack } catch {}
    exit 1
} finally {
    # Restore global Windows Update driver search configuration for all other hardware on the machine
    try {
        if ($null -ne $prevSearchOrder -and (Test-Path -LiteralPath $drvSearchCfgKey)) {
            Set-ItemProperty -LiteralPath $drvSearchCfgKey -Name "SearchOrderConfig" -Value ([int]$prevSearchOrder) -Type DWord -Force -ErrorAction SilentlyContinue
        }
        if (-not $hadPolKey) {
            Remove-Item -LiteralPath $drvSearchPolKey -Recurse -Force -ErrorAction SilentlyContinue
        } elseif ($null -eq $prevDontSearchWu) {
            Remove-ItemProperty -LiteralPath $drvSearchPolKey -Name "DontSearchWindowsUpdate" -Force -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty -LiteralPath $drvSearchPolKey -Name "DontSearchWindowsUpdate" -Value ([int]$prevDontSearchWu) -Type DWord -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    if ($null -ne $tempStageDir -and (Test-Path -LiteralPath $tempStageDir)) {
        Remove-Item -LiteralPath $tempStageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
