# Realtek HD Audio WHQL Automated Installer (Windows 11 x64)

![Platform](https://img.shields.io/badge/Platform-Windows%2011%20x64-0078D4)
![Driver](https://img.shields.io/badge/Realtek%20HDA-6.0.1.8186%20WHQL%20(R2.83)-success)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE)
![License](https://img.shields.io/badge/License-MIT-blue)

Automated, zero-reboot PowerShell deployment package for **Realtek High Definition Audio R2.83 (`6.0.1.8186` WHQL)** on Windows 11 (x64) laptops and all-in-one systems equipped with built-in Realtek speakers.

---

## Download Ready-to-Deploy Package

Download the complete portable bundle (**script + 179 Microsoft WHQL-signed driver binaries**) from **[GitHub Releases](../../releases/latest)**:

- **`Realtek-HDA-Win11-Installer-v1.0.0.zip`** — extract anywhere (USB drive, local folder, SMB share, or Intune/SCCM package source) and run `Install-RealtekAudio.ps1`.
- **`SHA256SUMS.txt`** — SHA-256 checksum manifest for release verification.

---

## Why This Exists

On many Windows 11 laptops, OEM UAD / ACP audio driver updates pushed automatically via Windows Update match specific 4-part `SUBSYS` hardware IDs (`Driver Rank 0x00FF0001`), breaking built-in speaker output.

- **Why `pnputil` fails**: Generic WHQL Realtek R2.83 packages (`HDXRT.inf` / `HDXSST.inf`) match 3-part codec IDs (`HDAUDIO\FUNC_01&VEN_10EC&DEV_xxxx`, `Driver Rank 0x00FF2005`). Running `pnputil /add-driver *.inf /install` invokes `DiInstallDriver` without force, so Windows PnP refuses to replace the broken `0x00FF0001` driver (`No better matching drivers found`) while polluting `DriverStore` with over 100 unused OEM INFs.
- **Why manual `Setup.exe` is painful**: The legacy InstallShield wizard requires interactive GUI clicks and **two full system reboots** (during the first reboot, Windows Update often re-downloads the broken UAD driver immediately).

### How `Install-RealtekAudio.ps1` Solves It

1. **OS & WHQL Catalog Validation**: Confirms 64-bit Windows 11 client OS (`Build >= 22000`) and validates the Microsoft WHQL Authenticode signature on `drivers\HDXRT.CAT` before making any changes.
2. **Hardware & Built-in Speaker Pre-Check**: Detects onboard Realtek codecs on `HDAUDIO` (`HDXRT.inf`) or Intel Smart Sound `INTELAUDIO` (`HDXSST.inf`) buses across all 67 supported codec IDs, and confirms built-in speakers via locale-independent `MMDevices\Audio\Render` endpoint properties (with portable/AIO SMBIOS chassis fallback on freshly installed OS instances without an initialized audio driver). Non-matching machines exit cleanly with code `2`.
3. **Surgical Zero-Reboot Swap**: Temporarily pauses online Windows Update PnP queries, stops the Windows Audio stack, removes conflicting Realtek UAD / `VEN_10EC` Extension INF packages (preserving Ethernet, Camera, Bluetooth, and GPU/HDMI audio drivers), and force-binds `6.0.1.8186` via Win32 `newdev.dll!UpdateDriverForPlugAndPlayDevicesW` with `INSTALLFLAG_FORCE (0x1)`.
4. **Windows Update Overwrite Lock**: Configures a device-scoped PnP policy (`DenyDeviceIDs = 1`, `DenyDeviceIDsRetroactive = 0`) strictly for the Realtek audio codec hardware IDs so Windows Update continues updating all other system hardware without overwriting the working audio driver.
5. **Hibernation (S4) & Sleep Resume Recovery**: In `RTKVHD64.sys` (`6.0.1.8186`, June 2017), full generic codec and speaker amplifier initialization (`HardWareInit` + `ResetAudioFgOnStart`) runs on `IRP_MN_START_DEVICE` (cold boot, reboot, or device restart), whereas the `D3 -> D0` power transition path (`IRP_MN_SET_POWER` on wake from S4 Hibernation) gates widget/amplifier unmuting on a 2017 OEM `SUBSYS` lookup table. To prevent silent built-in speakers after resuming from hibernation on newer laptops, the installer deploys a self-contained offline recovery script (`C:\ProgramData\RealtekHDA\Resume-RealtekAudio.ps1`) and a `SYSTEM` Scheduled Task (`\RealtekHDA-ResumeRecovery`) triggered by Windows power resume events (`Power-Troubleshooter` Event ID `1` and `Kernel-Power` Event IDs `107` / `507`) that performs a clean zero-veto PnP device restart upon wake.

---

## Package Layout

```text
Realtek-HDA-Win11-Installer/
├── Install-RealtekAudio.ps1       # Automated zero-reboot installer script
├── README.md                      # Documentation & CLI reference
├── LICENSE                        # MIT License
├── scripts/
│   └── New-ReleasePackage.ps1     # Helper to build Release ZIP & SHA256SUMS.txt
└── drivers/                       # Present in Release ZIP (179 WHQL-signed files)
    ├── HDXRT.inf                  # Standard HDAUDIO bus WHQL INF (v6.0.1.8186)
    ├── HDXSST.inf                 # Intel Smart Sound (INTELAUDIO) WHQL INF (v6.0.1.8186)
    ├── HDXRT.CAT                  # Microsoft WHQL signed security catalog
    └── ...                        # Signed .sys, .dll, .exe, .cpl binaries
```

---

## Usage

### Interactive Deployment (USB / Local Folder)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-RealtekAudio.ps1 -PlayTestSound
```

*(Automatically requests UAC elevation if launched without Administrator privileges.)*

### Pre-Flight Compatibility Check Only (Read-Only)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-RealtekAudio.ps1 -CheckOnly
```

### Centralized Unattended Deployment (Intune / SCCM / GPO / PDQ / RMM)

Runs silently under `NT AUTHORITY\SYSTEM` (`Session 0`) or Administrator, including directly from UNC/SMB network shares (`\\server\share\...` is automatically staged locally so `drvinst.exe` avoids SMB double-hop permission errors):

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "\\fileserver\deploy\Realtek-HDA-Win11-Installer\Install-RealtekAudio.ps1" -NoElevate
```

---

## CLI Parameters

| Parameter | Description |
| :--- | :--- |
| `-DriverDir <path>` | Path to the WHQL driver directory (defaults to `.\drivers`). |
| `-CheckOnly` | Run OS, codec, built-in speaker, and WHQL catalog checks only; makes no changes. |
| `-ForceReinstall` | Reinstall `6.0.1.8186` even if it is already cleanly installed and active. |
| `-SkipWindowsUpdateLock` | Do not create the `DenyDeviceIDs` policy locking the codec against Windows Update overwrites. |
| `-NoElevate` | Exit immediately with code `3` instead of triggering UAC when run without admin rights. |
| `-PlayTestSound` | Play a short Windows notification WAV upon completion (automatically skipped in `Session 0`). |
| `-Return3010OnRebootFlag` | Return exit code `3010` (`ERROR_SUCCESS_REBOOT_REQUIRED`) if PnP sets a reboot flag. |
| `-LogPath <path>` | Custom log file path (defaults to `%TEMP%\Realtek_HDA_Install.log`, or `%WINDIR%\Temp\Realtek_HDA_Install.log` under `SYSTEM`). |

## Exit Codes

| Code | Meaning |
| :--- | :--- |
| `0` | Success (driver installed and active, or already compliant). |
| `1` | Fatal error during installation. |
| `2` | Not applicable (unsupported OS, missing Realtek audio codec, or no built-in speakers). |
| `3` | Insufficient privileges (Administrator / `SYSTEM` required). |
| `3010` | Success with PnP reboot flag (only when `-Return3010OnRebootFlag` is passed). |

---

## Building the Release Archive from Source

If cloning the Git repository directly:

1. Extract the 179 WHQL-signed files required by `HDXRT.inf` and `HDXSST.inf` from the official Realtek High Definition Audio R2.83 (`6.0.1.8186`) x64 package into `.\drivers\`.
2. Build the distributable release `.zip` and `SHA256SUMS.txt`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\New-ReleasePackage.ps1 -Version v1.0.0
```
