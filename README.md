# Windows Cleaner

A Windows desktop app for managing installed programs and finding ways to free disk space. The interface is available in English and Russian.

## Download and run

Run **[WindowsCleaner.exe](WindowsCleaner.exe)**. It is a single-file application; no companion files are needed at runtime. The app targets 64-bit Windows and uses the Windows PowerShell and Windows Forms components available on Windows.

The interface has a dark left sidebar for navigation and quick actions, a custom Windows Cleaner mark, subtle transitions, and rounded drive and language selectors at the bottom of the sidebar. Installed apps show their registered Windows or Store icon when available, with a generated monogram as a fallback. Long values stay available in tooltips.

## Features

- Installed-app catalog from Windows uninstall records and Microsoft Store packages for the current user.
- Search by app name, publisher, version, and source; filter by installation scope.
- Publisher, version, install folder, and installer-reported size; if it is missing, the app estimates size from readable install folders in the background. Folder-based or partial estimates are marked with `≈`.
- Select multiple apps and launch their registered uninstallers sequentially after confirmation.
- Open Windows Settings for Store apps or entries without a supported standard uninstall command.
- On startup, estimate cleanup candidates and scan the selected drive for large folders, then calculate missing app-folder sizes in the background. Scanning runs sequentially to keep the interface responsive.
- Show every detected top-level folder in the Large folders list, sorted by size; the previous 100-row display limit is removed.
- Drive selection stays available during scans; requested follow-up scans run after the current scan.
- Clean old files from known temporary folders and empty the Recycle Bin after confirmation.
- Switch the interface between English and Russian in the sidebar.

## Build from source

The main source is `WindowsCleaner.ps1`. Build on 64-bit Windows with Windows PowerShell 5.1 and [PS2EXE](https://github.com/MScholtes/PS2EXE):

```powershell
Install-Module ps2exe -Scope CurrentUser
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1
```

`Build.ps1` writes `WindowsCleaner.exe` to the project folder. It builds a 64-bit GUI executable without a console window.

## Safety and limitations

- Uninstallers are launched from commands registered by the apps themselves. The app does not remove app folders or registry entries manually.
- Forced uninstall and automatic removal of leftovers are not included.
- App size comes from installer metadata when available and otherwise is estimated from the readable install folder. Windows last-access timestamps may be disabled or inaccurate.
- Regular large folders are only reported with guidance; the app does not delete them automatically.
- The app scans local Windows records and folders and does not send scan data to a server.

## Repository topics

`windows`, `windows-cleaner`, `powershell`, `winforms`, `disk-cleanup`, `uninstaller`, `desktop-app`
