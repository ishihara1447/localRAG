# OTE-RAG Setup bootstrapper

This directory contains the dependency-free Windows GUI bootstrapper.

## Distribution layout

Keep exactly these three files together:

```text
OTE-RAG-Setup.exe
OTE-RAG-win64-vX.Y.Z.zip
OTE-RAG-win64-vX.Y.Z.zip.sha256
```

The GUI self-elevates with UAC, verifies the outer ZIP hash, extracts with the
Windows inbox tar.exe, runs the package install.ps1, and opens the local UI.
It extracts under the short `C:\OTR\<timestamp>` path so deeply nested Node.js
packages remain below the legacy Windows path-length boundary.

## Build

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-setup.ps1 `
  -OutputPath C:\path\to\OTE-RAG-Setup.exe
```

No SDK download is required. The script uses the .NET Framework C# compiler
included with Windows.

## Non-interactive integrity check

```powershell
$p = Start-Process .\OTE-RAG-Setup.exe -ArgumentList --verify-only -Wait -PassThru
$p.ExitCode
Get-Content $env:TEMP\OTE-RAG-Setup-verify.log
```

Exit codes:

- 0: outer ZIP hash matches.
- 1: package discovery or sidecar format error.
- 2: ZIP hash mismatch.

This mode does not elevate, extract, or install.

## Security notes

- Setup requires exactly one OTE-RAG-win64-v*.zip beside the executable.
- The matching .zip.sha256 sidecar is mandatory.
- install.ps1 still verifies the package-internal checksum list.
- Install roots that are empty, UNC, or a drive root are rejected.
- The current executable is unsigned. Add Authenticode signing when an
  organizational code-signing certificate becomes available.
