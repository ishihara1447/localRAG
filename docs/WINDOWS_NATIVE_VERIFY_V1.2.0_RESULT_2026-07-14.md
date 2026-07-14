# OTE-RAG Windows native v1.2.0 build and verification result

Date: 2026-07-14

## Build result

- Windows source tree was synchronized from the WSL fork at commit 8907620d.
- frontend build succeeded with the Windows portable Node.js runtime.
- Windows Prisma query engine generation succeeded.
- favicon.png was regenerated from the Hinomaru SVG at 256x256.
- Final package: C:\LocalRAG\dist\LocalRAG-win64-v1.2.0.zip
- Package size: 8,249,442,125 bytes
- Package files: 100,601
- Bundled models: qwen3:8b and bge-m3:latest
- versions.lock: package_version=1.2.0, node=v22.20.0, ollama=0.31.2
- Customer Windows docs are included; docs\INSTALL_GUIDE.md was verified.
- package.sha256 is included.

## First v1.2.0 Round2 result

Transcript:
C:\Temp\localrag-round2-logs\round2-admin-20260714-015154.transcript.txt

Summary:
C:\Temp\localrag-round2-logs\round2-admin-20260714-015154.summary.json

All automatic checks passed:

- B2-0 administrator=True
- B2-1 tar extraction OK, 00:01:42
- B2-2 install OK, 00:07:32
- API ping OK
- API key generation OK
- Windows PowerShell 5.1 RAG E2E PASS=11 FAIL=0
- GPU OK, size_vram_total=5482154556
- backup OK
- stop/start OK
- ping after restart OK
- uninstall OK
- cleanup OK

B2-6 reboot resilience remains SKIP because the runner does not reboot Windows.

## Manual UI and service-control finding

A temporary v1.2.0 installation was started for manual checks.

Confirmed:

- Three LocalRAG Windows services were Running.
- API ping returned online=true.
- /api/system/local-services returned OTE-RAG labels.
- LocalRAG.lnk targeted C:\LocalRAGProd\LocalRAG.html.
- The launcher title was OTE-RAG and used localhost:3005.
- The shortcut icon target was C:\LocalRAGProd\LocalRAG.ico.

Found:

- Collector and Ollama returned controllable=false, so Web UI start/stop was disabled.
- Root cause: WinSW starts the server with NODE_ENV=production. The Node server loads .env.production, while install.ps1 generated only .env.
- windows-native/install.ps1 was fixed to generate app\server\.env.production as well.
- Shortcut description was fixed from LocalRAG for M System to OTE-RAG.
- windows-native/export-windows.ps1 was fixed to fail when customer docs are missing instead of silently producing an incomplete package.
- The corrected installer and exporter were synchronized to C:\LocalRAG\windows-native and a corrected v1.2.0 package was rebuilt.

## Remaining action

The corrected package still needs a clean elevated installation and a second manual service-control check. The temporary old installation is still present because two UAC elevation prompts were cancelled by the user. The current shell is not administrator. No non-elevated deletion or privilege bypass was attempted.

To continue safely, approve UAC when launching the explicit uninstall of C:\LocalRAGProd, then run the corrected v1.2.0 Round2 verification. Do not delete C:\LocalRAG or unrelated folders.
