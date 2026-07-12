# Windows Native Round2 Verification Result (v1.1.0, 2026-07-12)

## Verdict

Round2 verification for `LocalRAG-win64-v1.1.0.zip` passed.

The previous v1.0.0 blockers were resolved:

- Full Ollama runtime is bundled, including `lib/ollama/llama-server.exe`, DLLs, and CUDA runtime trees.
- Windows PowerShell 5.1 E2E now passes.
- Round2 runner summary JSON is generated correctly.
- Windows Service / Session 0 GPU execution is confirmed by Ollama logs and `/api/ps` nonzero `size_vram`.

Residual items:

- B2-6 Windows reboot resilience was intentionally skipped by the runner and still needs a manual reboot test.
- `C:\LocalRAGProd\uninstall.ps1` remains after uninstall. This is minor and expected from the current self-uninstall design, but it should be cleaned up or documented.
- Logs show AnythingLLM context-window map sync and Ollama cloud flag defaults. For a strict offline customer environment, run a network-disconnected test and consider hardening those defaults.
- PowerShell 5.1 transcript still displays Japanese text with duplicated glyphs, but the E2E logic and JSON parsing passed.

## Inputs

- Runner: `C:\Temp\localrag-round2\Run-Round2-Verify.cmd`
- Verification script: `C:\Temp\localrag-round2\round2-admin-verify.ps1`
- Zip: `C:\LocalRAG\dist\LocalRAG-win64-v1.1.0.zip`
- Zip size: `8263359254` bytes
- Verify root: `C:\Temp\localrag-verify`
- Install root: `C:\LocalRAGProd`
- Server port: `3005`
- Log root: `C:\Temp\localrag-round2-logs`
- Transcript: `C:\Temp\localrag-round2-logs\round2-admin-20260712-074657.transcript.txt`
- Summary: `C:\Temp\localrag-round2-logs\round2-admin-20260712-074657.summary.json`
- Service log copy: `C:\Temp\localrag-round2-logs\service-logs-20260712-074657`

## Claude Code Changes Reviewed

Latest relevant commits reviewed:

- `e5c04e4` - fixed Round2 runner and PS5.1 E2E bugs.
- `22af16f` - rebuilt v1.1.0 and prepared Round2 verification.

Confirmed fixes from commit messages and diffs:

- `CurlText([string[]]$Args)` was renamed to avoid PS5.1 `$args` automatic-variable collision.
- JSON body posting in `rag-e2e-test.ps1` was moved to temporary UTF-8 files with `--data-binary`, avoiding PS5.1 quote stripping.
- Summary JSON generation now uses `.ToArray()` for PS5.1 compatibility.
- GPU judgement now checks `/api/ps` `size_vram` instead of searching for the string `GPU`.
- PS5.1 curl stdout decoding now sets `[Console]::OutputEncoding = UTF8`.
- Fixture path resolution now uses `.ProviderPath`, avoiding `Microsoft.PowerShell.Core\FileSystem::` paths.
- v1.1.0 zip now targets qwen3:8b + bge-m3 and the full Ollama runtime.

## Step Results

From `round2-admin-20260712-074657.summary.json`:

| Step | Status | Detail |
| --- | --- | --- |
| B2-0 admin | OK | administrator=True |
| B2-1 tar extract | OK | elapsed=00:01:11.5234014 |
| B2-2 install | OK | elapsed=00:06:02.1072900 |
| B2-2 api ping | OK | `{"online":true}` |
| API key generation | OK | id=1 |
| B2-4 E2E PS5.1 | OK | elapsed=00:01:24.6076410 |
| B2-3 GPU | OK | size_vram_total=10537381395 |
| B2-5 backup | OK | elapsed=00:00:03.7515182 |
| B2-5 stop | OK | elapsed=00:00:01.1239395 |
| B2-5 start | OK | elapsed=00:00:02.0879267 |
| B2-5 ping after restart | OK | `{"online":true}` |
| B2-6 reboot resilience | SKIP | Windows reboot not performed by runner |
| B2-7 uninstall | OK | elapsed=00:00:22.5941579 |
| B2-7 uninstall state | OK | preserved path recorded |
| B2-8 cleanup | OK | verify removed; ProgramData kept=False |

## Install and Services

Install completed successfully:

- API ping: `{"online":true}`
- Services reached Running / Automatic:
  - `LocalRAG-Ollama`
  - `LocalRAG-Collector`
  - `LocalRAG-Server`

WinSW logs confirm install and start for all three services.

During install, `LocalRAG-Server` briefly showed `StartPending` in the register script's immediate status table, but it became `Running` before the runner's post-install check.

## Ollama Runtime and GPU

The installed v1.1.0 tree includes the full Ollama runtime:

- `C:\LocalRAGProd\runtime\ollama\ollama.exe`
- `C:\LocalRAGProd\runtime\ollama\lib\ollama\llama-server.exe`
- `C:\LocalRAGProd\runtime\ollama\lib\ollama\*.dll`
- `C:\LocalRAGProd\runtime\ollama\lib\ollama\cuda_v12\*`
- `C:\LocalRAGProd\runtime\ollama\lib\ollama\cuda_v13\*`

Ollama service log confirms CUDA discovery:

```text
inference compute id=0 library=CUDA compute=12.0 name=CUDA0 description="NVIDIA GeForce RTX 5070 Ti" total="15.9 GiB" available="14.7 GiB"
vram-based default context total_vram="15.9 GiB" default_num_ctx=4096
```

After E2E, `/api/ps` showed nonzero VRAM for both bundled models:

- `bge-m3:latest`: `size_vram=618062151`
- `qwen3:8b`: `size_vram=9919319244`
- Total: `10537381395`

This answers the main Round2 question: LocalRAG's dedicated Ollama instance can use GPU from a Windows Service / Session 0 context on this machine.

## E2E Result

Windows PowerShell 5.1 E2E passed:

```text
PASS=11 FAIL=0
elapsed=00:01:24.6076410
```

Covered assertions:

- Workspace creation succeeded.
- TXT fixture upload and embedding succeeded.
- Policy answer contained `22` and returned sources.
- Japanese CID-font PDF upload and RAG answer contained `3,400`.
- DOCX upload and RAG answer contained core time `10時20分`.
- Out-of-document question returned no-source or unknown-style response.
- External provider `openai` was rejected by API.
- Swagger docs were disabled.

## Backup / Stop / Start / Uninstall

Backup passed:

- Backup file: `localrag-backup-20260712-075537.zip`
- Size: `72888` bytes

Stop/start passed:

- Stop elapsed: `00:00:01.1239395`
- Start elapsed: `00:00:02.0879267`
- Ping after restart: `{"online":true}`

Uninstall passed:

- Services removed: remaining service count = 0
- `C:\ProgramData\LocalRAG` removed by final cleanup
- `C:\Temp\localrag-verify` removed by final cleanup

Final observed state after runner:

- LocalRAG services: none
- `C:\ProgramData\LocalRAG`: missing
- `C:\Temp\localrag-verify`: missing
- `C:\LocalRAGProd`: exists with only `uninstall.ps1` (`2644` bytes)
- `C:\Temp\localrag-round2-logs`: retained with transcript, summary, and copied service logs

## Notes and Follow-ups

1. Run a manual reboot resilience test for B2-6:
   - Install v1.1.0.
   - Reboot Windows.
   - Confirm all `LocalRAG-*` services are Running.
   - Confirm `http://localhost:3005/api/ping` returns online.
   - Confirm `/api/ps` shows nonzero `size_vram` after an E2E query.

2. Decide whether to remove the final `C:\LocalRAGProd\uninstall.ps1` during uninstall cleanup or document it as harmless.

3. Perform a strict offline run with network disabled. Logs during this run included context-window map sync behavior and Ollama cloud defaults, so offline hardening should be verified before customer delivery.

4. The PS5.1 transcript still renders Japanese E2E messages with duplicated glyphs. It did not affect pass/fail, but output readability can be improved later.