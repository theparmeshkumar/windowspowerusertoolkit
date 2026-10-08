# Windows Power User Toolkit

A lightweight Windows desktop toolkit built with PowerShell and Windows Forms. It brings together temporary-file inspection and cleanup, Explorer context-menu management, quick context-menu entries, and common Windows maintenance shortcuts in one GUI.

The toolkit is designed to make potentially disruptive actions visible: temporary-file cleanup requires category selection and confirmation, file-level deletion starts with nothing selected, context-menu removals are backed up, and administrative operations request elevation when needed.

> **Use at your own risk.** This project changes files and Windows registry entries and can start system maintenance commands. Review the safety notes below before using cleanup, registry, or repair features.

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Feature reference](#feature-reference)
- [Temporary-file categories](#temporary-file-categories)
- [Architecture](#architecture)
- [Safety and permissions](#safety-and-permissions)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Temporary Files Cleaner**
  - 13 individually selectable cleanup categories.
  - Background, recursive file scan with per-category byte totals.
  - Separate file-level review window showing file name, size, category, modified time, and full path.
  - File-level deletion is opt-in: no scanned files are checked by default.
  - A separate category cleanup action cleans the selected locations after confirmation.
  - Locked or inaccessible files may be skipped; scan results are best-effort.
- **Scrollable category list**
  - Dedicated, always-visible vertical scrollbar instead of relying on a hidden automatic scrollbar.
  - Mouse-wheel scrolling works over the category panel and its row controls.
  - Resizing the window updates the visible viewport.
- **Context Menu Manager**
  - Scans common image, file, folder, and folder-background registry locations.
  - Displays discovered menu labels, scope, and registry location.
  - Selects one or more entries for removal.
  - Creates a separate `.reg` backup for each selected entry before attempting removal; entries whose backups fail are skipped.
  - Reports entries that could not be removed and refreshes Explorer after a removal attempt.
- **Quick Add / Remove**
  - Add or remove “Open CMD Here”, “Open PowerShell Here”, “Copy Path”, and “Open with Notepad”.
  - Removal creates a registry backup before changing the registration.
- **Maintenance**
  - Opens Disk Cleanup, drive optimization, CHKDSK scan, DNS flush, DISM RestoreHealth, SFC, system diagnostics, Reliability Monitor, System Information, Device Manager, Services, Task Scheduler, and the Microsoft Malicious Software Removal Tool (MRT).
  - Long-running command-line maintenance operations run in separate console processes so they do not block the GUI.
- **Dashboard and quick actions**
  - Shortcuts for Startup Apps, Performance, Explorer, Visual Effects, Storage, and DirectX diagnostics.
  - Quick access to Explorer restart, context-menu management, DNS flush, DISM, SFC, CHKDSK, and MRT.
- **No third-party dependencies**
  - Uses Windows PowerShell, Windows Forms, and built-in Windows utilities.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 (`powershell.exe`), included with supported Windows installations.
- .NET Framework components used by Windows Forms, normally present on Windows.
- An administrator account and User Account Control (UAC) approval for cleanup actions, registry changes, system-wide operations, and elevated maintenance commands.

The application is a Windows desktop GUI and is not intended to run on macOS, Linux, PowerShell 7-only environments, or Windows Server Core without a graphical desktop.

## Installation

### Download from GitHub

1. Open the repository: <https://github.com/theparmeshkumar/windowspowerusertoolkit>.
2. Select **Code > Download ZIP** and extract the archive to a folder you can write to.
3. Keep `WindowsPowerUserToolkit.bat` and `WindowsPowerUserToolkit.ps1` together in the same folder.
4. Double-click `WindowsPowerUserToolkit.bat`.
5. Approve the Windows PowerShell prompt if your organization or local execution policy displays one.

### Clone with Git

```powershell
git clone https://github.com/theparmeshkumar/windowspowerusertoolkit.git
Set-Location .\windowspowerusertoolkit
.\WindowsPowerUserToolkit.bat
```

No installer or package manager is required.

## Usage

1. Launch the batch file. It starts the adjacent PowerShell script with `-NoProfile` and a process-scoped execution-policy bypass.
2. Use the **Dashboard** for common Windows shortcuts, or open a feature tab.
3. For cleanup, review the checked categories and their paths. Uncheck anything you do not want included.
4. Choose **Scan Selected Locations** to inspect approximate sizes and discover individual files, or choose **Clean Checked Categories** to perform category-level cleanup after the confirmation prompt.
5. For file-level control, scan first, open **View Scanned Files**, check only the files you intend to delete, and confirm.
6. Use the **Context Menu** tab to scan entries. Review the registry location before selecting entries and choosing **Remove Selected**.
7. Use **Quick Add / Remove** for the four built-in convenience entries. Use **Maintenance** or Dashboard buttons to start Windows utilities.

Some actions may open a separate console, request UAC elevation, restart Windows Explorer, or require sign-out/restart before changes are fully reflected.

## Feature reference

### Temporary Files Cleaner

The categories are separate checkboxes. They are checked initially for convenience; review the list and uncheck any category you do not want to clean.

**Scan Selected Locations** recursively enumerates files under checked paths and reports per-category size totals. A scan does not delete anything. Inaccessible or locked items may be omitted from the scan.

**View Scanned Files** opens a detailed list after a successful scan. All file checkboxes begin unchecked. Select the precise files to target, confirm the deletion, and approve UAC. The delete worker checks that each path still exists as a file and removes that exact path. Rescan after deletion to refresh the displayed results.

**Clean Checked Categories** is a separate, broader operation. It deletes contents according to each category's cleanup rule; it does not use the file-level checkboxes. It asks for confirmation and starts an elevated background PowerShell process. This action is not a recycle-bin operation.

### Context Menu Manager

The scanner can inspect:

- Image shell commands and image context-menu handlers.
- All-file shell commands and file context-menu handlers.
- Directory shell commands and directory context-menu handlers.
- Folder-background shell commands and background context-menu handlers.

Use the type selector to narrow the scan. The list shows the entry name, scope, and registry path. Removing selected entries backs up each selected registration to the backup folder first. If an individual backup cannot be created, that registration is not included in the removal job. Removal errors are reported after the background worker completes.

### Quick Add / Remove

| Entry | Effect |
|---|---|
| Open CMD Here | Adds a folder-background command prompt entry. |
| Open PowerShell Here | Adds a folder-background Windows PowerShell entry. |
| Copy Path | Adds a file context-menu item that copies the selected path to the clipboard. |
| Open with Notepad | Adds a file context-menu item that opens the selected file in Notepad. |

These entries write under `HKEY_CLASSES_ROOT` and require administrator approval. Explorer is restarted after an add operation; removing an entry backs up its registry key first.

### Maintenance and Dashboard

Maintenance buttons start standard Windows utilities and commands. Administrator-required commands prompt for elevation and run in a separate command window. The toolkit does not determine whether a repair is needed; review each utility's output and Windows guidance.

## Temporary-file categories

The paths below are based on the current Windows installation and current user's environment variables. Paths may not exist on every machine. “Routine” describes the label in the UI, not a guarantee that every file is safe to delete at every moment.

| Category | Scanned location | Category cleanup behavior |
|---|---|---|
| User TEMP | `%TEMP%` | Deletes files and child directories under the selected location. |
| Windows TEMP | `%WINDIR%\Temp` | Deletes files and child directories under the selected location; elevation is required. |
| Prefetch *(Optional)* | `%WINDIR%\Prefetch` | Deletes files in this folder only. This category is marked optional; uncheck it to exclude it. Review before use. |
| Thumbnail Cache | `%LOCALAPPDATA%\Microsoft\Windows\Explorer` | Deletes files matching `thumbcache*.db`; other files and directories are not removed by category cleanup. |
| DirectX Shader Cache | `%LOCALAPPDATA%\D3DSCache` | Deletes files and child directories under the selected location. |
| NVIDIA Shader Cache | `%LOCALAPPDATA%\NVIDIA\DXCache` | Deletes files and child directories under the selected location. |
| NVIDIA GL Cache | `%LOCALAPPDATA%\NVIDIA\GLCache` | Deletes files and child directories under the selected location. |
| AMD Shader Cache | `%LOCALAPPDATA%\AMD\DxCache` | Deletes files and child directories under the selected location. |
| AMD GL Cache | `%LOCALAPPDATA%\AMD\GLCache` | Deletes files and child directories under the selected location. |
| Delivery Optimization Cache | `%WINDIR%\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache` | Deletes files and child directories under the selected location; elevation is required. |
| Windows Error Reports | `%ProgramData%\Microsoft\Windows\WER` | Deletes files and child directories under the selected location; elevation is required. |
| Windows Crash Dumps | `%LOCALAPPDATA%\CrashDumps` | Deletes files and child directories under the selected location. |
| Windows Font Cache | `%LOCALAPPDATA%\Microsoft\Windows\FontCache` | Deletes files and child directories under the selected location. |

File-level scanning shows files recursively under the selected category path. File-level deletion targets checked files, even when a category-level rule (such as Thumbnail Cache) would have a narrower filter. Inspect each full path before confirming.

## Architecture

The repository intentionally keeps the application small:

```text
.
├── WindowsPowerUserToolkit.bat    # Windows launcher
├── WindowsPowerUserToolkit.ps1    # WinForms UI and feature implementation
├── README.md                      # User, feature, safety, and contributor documentation
├── LICENSE                        # MIT License
└── .gitignore                     # Local and generated-file exclusions
```

- The batch launcher resolves the script relative to its own folder, so the two runtime files must stay together.
- The PowerShell script constructs the Windows Forms tabs and controls, manages confirmation dialogs and status messages, and dispatches operating-system operations.
- Temporary-file and context-menu scans use PowerShell background jobs polled by Windows Forms timers. Results are marshalled back to the UI thread for display.
- Selected temporary-file deletion and category cleanup run in separate elevated PowerShell processes. This avoids waiting on file operations in the GUI thread.
- Command-line maintenance tools run in separate `cmd.exe` windows; users can see progress and utility output.
- Registry exports are stored in `Windows_Power_User_Backups` on the current user's Desktop.

## Safety and permissions

- **Review every path.** The category list includes system directories and caches. Do not select categories you do not understand.
- **Prefer scan and file-level review.** Category cleanup is broader; file-level deletion displays exact paths and starts with nothing selected.
- **Prefetch is optional.** Deleting cache files can cause Windows or applications to regenerate them and may temporarily affect startup or application performance.
- **Locked files may be skipped.** Do not force-close system processes simply to remove a file that is in use.
- **Registry changes can affect Explorer and file associations.** Backups are saved before toolkit-managed removals, but a registry backup is not a substitute for a full system backup. Verify that a backup was actually created.
- **Restore backups deliberately.** A `.reg` file imports registry data when opened or imported. Confirm its source and contents before restoring it.
- **Administrative privileges are powerful.** Approve UAC only for an action you initiated and understand.
- **Maintenance commands can take a long time.** DISM, SFC, CHKDSK, and drive optimization run in separate windows. Keep the window open and read the command's final result.
- **Explorer restart interrupts the shell briefly.** Open File Explorer windows/taskbar may close and reappear.
- **The launcher uses `-ExecutionPolicy Bypass` for this process only.** It does not persistently alter the machine's execution policy. Only run scripts you have reviewed and trust.
- **Use an appropriate backup.** The authors provide the software “as is” and cannot guarantee that cleanup or registry operations are reversible.

## Troubleshooting

### The GUI does not open

- Confirm that `WindowsPowerUserToolkit.bat` and `WindowsPowerUserToolkit.ps1` are in the same extracted folder.
- Run the batch file from File Explorer or a command prompt and read any startup error.
- Check that Windows PowerShell 5.1 and the Windows desktop/Forms components are available.
- If organizational policy prevents PowerShell execution, contact the system administrator rather than attempting to bypass organizational controls.

### A scan finds no files or some paths are missing

- A category path may not exist on that Windows version or hardware configuration.
- Files in use or paths without current-user permissions may be skipped. Try a fresh scan after closing the relevant application.
- Some categories require elevation for full access. Approve UAC only when expected.

### Cleanup or selected deletion appears incomplete

- Locked files are skipped by the category worker, and file-level deletion reports individual failures when the worker cannot remove an item.
- Rescan after the operation. Files recreated by Windows or applications may appear again.
- Ensure the selected path is not redirected, synchronized, or controlled by security software.

### Context-menu removal fails or a registration reappears

- Confirm that the corresponding `.reg` backup exists in `Desktop\Windows_Power_User_Backups`.
- Rescan and inspect the displayed registry path. Some applications register entries in locations outside the scopes scanned by this tool or recreate their entries during repair/update.
- Try the specific type filter and verify administrator approval.

### A maintenance command reports errors

- Read the full output in the separate command window; this toolkit launches Windows utilities but does not interpret their repair results.
- Some commands require elevation, an internet connection, or a restart. Follow the instructions printed by the Windows utility.

### The application is unresponsive while Explorer restarts

Explorer is explicitly stopped and restarted by the context-menu workflow. Wait a few seconds for the taskbar and desktop to return. Avoid repeatedly clicking the action while the shell is restarting.

## Roadmap

Ideas for future improvements (not promises or current functionality):

- Add a configurable preview/report export before any category-level cleanup.
- Improve progress and per-item result reporting for all cleanup workers.
- Add automated tests for path selection, registry-path handling, and worker result processing.
- Add optional support for PowerShell 7 on Windows after validating Windows Forms and provider compatibility.
- Improve accessibility, keyboard navigation, and high-DPI layout behavior.
- Add release packaging and versioned changelog documentation.

## Contributing

Contributions are welcome. Before submitting a change:

1. Open an issue describing the problem or proposed behavior, especially for cleanup scopes or registry changes.
2. Keep changes focused and avoid expanding deletion scope without explicit review and user-facing warnings.
3. Preserve the non-destructive scan workflow, confirmation dialogs, exact-path file deletion, and registry backup behavior.
4. Test the application on a supported Windows desktop with standard-user and administrator scenarios as applicable.
5. Include clear reproduction steps, Windows version, PowerShell version, and relevant error text. Do not include personal files, registry exports, or other sensitive data.
6. Submit a pull request with a concise description of the user-visible changes and validation performed.

## License

This project is distributed under the [MIT License](./LICENSE).
