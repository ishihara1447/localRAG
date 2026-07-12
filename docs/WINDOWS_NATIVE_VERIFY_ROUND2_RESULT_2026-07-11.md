# Windows Native Round2 Verification Result (2026-07-11)

## Summary

Round2 admin verification was started from `Run-Round2-Verify.cmd` on Windows 11.

The installer path mostly worked: tar extraction, preflight, checksum, install, service registration, and `/api/ping` reached a healthy state on port `3005`.

However, the packaged zip is not acceptable as-is because the bundled Ollama runtime is incomplete. The package includes `runtime/ollama/ollama.exe` only and does not include `lib/ollama/llama-server.exe` or the required DLL tree. As a result, embedding failed until the missing `lib/` directory was manually hotfixed into the installed tree.

## Environment

- Zip: `C:\LocalRAG\dist\LocalRAG-win64-v1.0.0.zip`
- Verify root: `C:\Temp\localrag-verify`
- Install root: `C:\LocalRAGProd`
- Server port: `3005`
- Log root: `C:\Temp\localrag-round2-logs`
- Runner transcript: `C:\Temp\localrag-round2-logs\round2-admin-20260711-234522.transcript.txt`
- Admin user: `TAYUGURO\ms_is`
- GPU VRAM reported by preflight: `16303 MiB`
- Free space on C: `235 GB`

## What Passed

- Admin execution detected correctly.
- Tar extraction completed in `00:01:06.8687150`.
- Extracted tree was about `100513` files / `7.382 GiB`.
- Installer preflight passed: GPU VRAM, free disk space, and ports `3005`, `8888`, `11435` were OK.
- Services were installed and running:
  - `LocalRAG-Server`
  - `LocalRAG-Collector`
  - `LocalRAG-Ollama`
- Ports were listening:
  - `3005`: server
  - `8888`: collector
  - `11435`: Ollama
- API ping passed manually after runner failure:

```text
GET http://localhost:3005/api/ping
{"online":true}
```

- Manual API key generation succeeded. The generated test key was deleted after verification.

## Runner Failure

The admin verification runner stopped during `B2-2 api ping` / API key generation.

Observed transcript symptoms:

```text
curl: (2) no URL specified
STEP[NG] B2-2 api ping
FATAL: API key generation failed
```

This appears to be a bug in the Round2 runner helper, not an installer/product failure, because the same endpoint and API key generation worked manually with `curl`.

The runner also failed to write its summary JSON due to a PowerShell argument type mismatch. Therefore there is no reliable `*.summary.json` from this run.

## PS5.1 E2E Result

Running the installed `rag-e2e-test.ps1` under Windows PowerShell 5.1 failed immediately at workspace creation:

```text
ワークスペース作成に失敗: <!DOCTYPE html>... Bad Request
```

Server logs showed JSON parse failure for the request body. The equivalent manual `curl.exe` request worked, so this is most likely a quoting/body construction bug in `windows-native/rag-e2e-test.ps1` when executed by Windows PowerShell 5.1.

Action needed: make the PowerShell E2E script write JSON bodies to temporary files or stdin instead of passing escaped JSON directly to `curl.exe -d`.

## PowerShell 7 E2E Result Before Hotfix

Running the same E2E script with PowerShell 7 progressed but failed RAG checks:

```text
PASS=7 FAIL=4
```

Failures:

- employment regulation answer did not contain `22`
- source assertion failed
- PDF expense answer did not contain `3,400`
- DOCX core time answer failed

Root cause in logs:

```text
Ollama Failed to embed: error starting llama-server: llama-server binary not found
```

Ollama `/api/ps` showed no loaded models at that point.

## Packaging Defect

Installed tree contained only:

```text
C:\LocalRAGProd\runtime\ollama\ollama.exe
```

Expected but missing:

```text
C:\LocalRAGProd\runtime\ollama\lib\ollama\llama-server.exe
C:\LocalRAGProd\runtime\ollama\lib\ollama\*.dll
C:\LocalRAGProd\runtime\ollama\lib\ollama\cuda_v12\*
C:\LocalRAGProd\runtime\ollama\lib\ollama\cuda_v13\*
```

The distribution zip also contains only `runtime/ollama/ollama.exe`.

The original downloaded official Ollama zip at `C:\LocalRAG\build-deps\ollama-windows-amd64-v0.31.2.zip` does contain the missing `lib/ollama` tree. Therefore the likely defect is in build dependency preparation or export validation: the prepared `OllamaDir` copied only `ollama.exe`.

Action needed:

- Prepare `C:\LocalRAG\build-deps\ollama` by extracting/copying the full official Ollama zip tree, not only `ollama.exe`.
- Added in this session: `windows-native/export-windows.ps1` now asserts that `OllamaDir\lib\ollama\llama-server.exe` exists before generating a customer zip.
- Regenerate the Windows native zip after fixing the dependency tree.

## Manual Hotfix Result

For diagnosis only, the missing `lib/` directory was manually extracted into the installed tree:

```powershell
cd C:\LocalRAGProd\runtime\ollama
tar.exe -xf C:\LocalRAG\build-deps\ollama-windows-amd64-v0.31.2.zip lib
```

After that hotfix, PowerShell 7 E2E passed:

```text
PASS=11 FAIL=0
elapsed=00:01:19.6917211
```

Validated items included answer `22`, sources, PDF `3,400`, DOCX core time, unknown-style response for out-of-document question, external provider rejection, and Swagger disabled.

This proves the installed application can pass the E2E path when Ollama runtime is complete. It does not validate the original zip as shippable.

## GPU Status

GPU service validation remains unresolved.

Ollama service startup logs from the original install showed:

```text
failure during llama-server GPU discovery
llama-server binary not found
inference compute id=cpu
total_vram="0 B"
```

After the manual hotfix, E2E passed but `/api/ps` still reported loaded models with `size_vram: 0`, so this run must be treated as CPU-only.

Because the service started before `llama-server.exe` was hotfixed into place, this run does not answer the main Round2 question: whether the Windows Service / Session 0 path can use CUDA.

Action needed:

- Rebuild the package with the complete Ollama runtime.
- Clean install from the rebuilt package.
- Confirm fresh `LocalRAG-Ollama` startup logs show GPU discovery success.
- Confirm `/api/ps` reports nonzero VRAM usage for the LLM during E2E.

## Cleanup State

The generated API key was deleted after verification.

The installed Windows services and files were intentionally left in place because Codex was not running as Administrator when the runner failed.

Current likely leftovers:

- `C:\LocalRAGProd`
- `C:\ProgramData\LocalRAG`
- `C:\Temp\localrag-verify`
- running services: `LocalRAG-Server`, `LocalRAG-Collector`, `LocalRAG-Ollama`

Administrator cleanup command:

```powershell
cd C:\LocalRAGProd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
Remove-Item -Recurse -Force C:\Temp\localrag-verify -ErrorAction Continue
```

## Verdict

Round2 is a partial pass but not a package release pass.

- Installer/service wiring: mostly OK.
- API basic health: OK.
- RAG E2E: OK only after manual Ollama runtime hotfix.
- Original zip: NG due incomplete Ollama runtime.
- PS5.1 E2E script: NG due JSON quoting issue.
- GPU service validation: unresolved; current evidence is CPU-only.

Next best step is to fix the Ollama runtime packaging, regenerate the Windows native zip, and rerun Round2 from a clean install.
