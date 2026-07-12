# Windows native Round2 verification result (2026-07-13)

実行日: 2026-07-13
実行者: ユーザー（`Run-Round2-Verify.cmd` を管理者実行）
監視・整理: Codex

## 結論

Round2 ランナーは完走し、v1.1.0 zip に対する主要検証は PASS した。

ただし、Claude Code からの今回依頼は v1.2.0 ビルド・検証だったが、今回実際に検証された zip は `C:\LocalRAG\dist\LocalRAG-win64-v1.1.0.zip` である。`C:\LocalRAG\dist\LocalRAG-win64-v1.2.0.zip` は監視時点で存在しなかった。

そのため、本結果は v1.1.0 の再検証結果であり、v1.2.0 の新規項目（デスクトップショートカット、`LocalRAG.html` ランチャー、Web UI からの Ollama / Collector 起動停止、VRAM 解放）は未検証。

## 実行ログ

- Transcript: `C:\Temp\localrag-round2-logs\round2-admin-20260713-083235.transcript.txt`
- Summary: `C:\Temp\localrag-round2-logs\round2-admin-20260713-083235.summary.json`
- Service logs copy: `C:\Temp\localrag-round2-logs\service-logs-20260713-083235`
- ZipPath: `C:\LocalRAG\dist\LocalRAG-win64-v1.1.0.zip`
- zip size: `8263359254` bytes
- VerifyRoot: `C:\Temp\localrag-verify`
- InstallRoot: `C:\LocalRAGProd`
- ServerPort: `3005`
- Start: `2026-07-13T08:32:35+09:00`
- Finish: `2026-07-13T08:40:50+09:00`

## Step result

| Step | Result | Detail |
|---|---:|---|
| B2-0 admin | OK | `administrator=True` |
| pre-clean existing uninstall | OK | elapsed `00:00:00.2982216` |
| B2-1 tar extract | OK | elapsed `00:01:25.9856026` |
| B2-2 install | OK | elapsed `00:05:35.1948190` |
| B2-2 api ping | OK | `{"online":true}` |
| API key generation | OK | generated id=`1`; secret value omitted from this report; key was deleted during the run |
| B2-4 E2E PS5.1 | OK | elapsed `00:00:25.2023357`; `PASS=11 FAIL=0` |
| B2-3 GPU | OK | `size_vram_total=10537381395` |
| B2-5 backup | OK | elapsed `00:00:03.6667626` |
| B2-5 stop | OK | elapsed `00:00:01.0652645` |
| B2-5 start | OK | elapsed `00:00:02.0342378` |
| B2-5 ping after restart | OK | `{"online":true}` |
| B2-6 reboot resilience | SKIP | runner does not reboot Windows |
| B2-7 uninstall | OK | elapsed `00:00:18.8644443` |
| B2-7 uninstall state | OK | uninstall path reported `C:\ProgramData\LocalRAG\uninstalled-20260713-084017` |
| B2-8 cleanup | OK | `verify removed; ProgramData kept=False` |

## Observations

- Install reached all three Windows services:
  - `LocalRAG-Ollama`: installed and started
  - `LocalRAG-Collector`: installed and started
  - `LocalRAG-Server`: installed and started
- API ping succeeded on `http://localhost:3005` during the runner.
- Windows PowerShell 5.1 E2E passed all 11 checks, including PDF / DOCX ingestion, source attachment, unknown response, external provider rejection, and Swagger disabled check.
- GPU verification succeeded after E2E. Ollama `/api/ps` reported:
  - `bge-m3:latest` `size_vram=618062151`
  - `qwen3:8b` `size_vram=9919319244`
  - total `size_vram_total=10537381395`
- Backup file was created during the run: `localrag-backup-20260713-084002.zip`.
- Stop/start regression passed and ping after restart returned online.
- Uninstall removed all `LocalRAG-*` services. Post-run service query returned no services.
- `C:\ProgramData\LocalRAG` did not remain after cleanup.
- `C:\LocalRAGProd` remained with only `uninstall.ps1`. This matches the previously observed minor leftover behavior and is not a functional failure, but should be documented or cleaned by design if desired.
- `Remove-Item` errors for missing `C:\Temp\localrag-install` / `C:\Temp\localrag-verify` appeared during cleanup/pre-clean. They are harmless missing-path messages and did not stop the runner.
- Transcript still shows the known PS5.1 Japanese glyph duplication issue in E2E output. It did not affect pass/fail.

## Not covered by this run

This run did not validate the v1.2.0-specific Claude Code request because v1.2.0 zip was not present and the runner used v1.1.0 by default.

Remaining v1.2.0 tasks:

1. Build `C:\LocalRAG\dist\LocalRAG-win64-v1.2.0.zip`.
2. Re-run the admin verifier with explicit `-ZipPath C:\LocalRAG\dist\LocalRAG-win64-v1.2.0.zip`.
3. Manually verify the new desktop shortcut `LocalRAG.lnk`.
4. Manually verify `LocalRAG.html` launcher behavior when server is online and offline.
5. Verify Web UI service control for Ollama / Collector start-stop.
6. Verify the UI warning banner while Ollama is stopped.
7. Verify GPU VRAM release after stopping Ollama and recovery after starting it again.
8. Confirm server itself is not exposed as a self-stop target in the service control UI.

## Current state after run

- `LocalRAG-*` services: none remain.
- `C:\Temp\localrag-verify`: removed.
- `C:\ProgramData\LocalRAG`: not present.
- `C:\LocalRAGProd`: remains with `uninstall.ps1` only.
- `C:\LocalRAG\dist\LocalRAG-win64-v1.1.0.zip`: present.
- `C:\LocalRAG\dist\LocalRAG-win64-v1.2.0.zip`: not found.
