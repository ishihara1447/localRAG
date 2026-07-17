# OTE-RAG Windows native v1.2.0 final build result

Date: 2026-07-17 (JST)

## Result

Current OTE-RAG was built as a Windows-only offline distribution package.
Docker and WSL are not required on the customer machine.

- Package: `C:\LocalRAG\dist\LocalRAG-win64-v1.2.0.zip`
- Zip size: 11,019,463,242 bytes (about 10.26 GiB)
- Zip SHA-256: `4941ce0d8784dd9f0ab86444db92f390d3eae6c3819603f88d03d85f0ee498d7`
- Uncompressed files: 100,635 (including `package.sha256`)
- Uncompressed bytes: 13,231,358,200
- Package checksum verification: **PASS=100,634 / FAIL=0**

The previous qwen3-based v1.2.0 was preserved under
`C:\LocalRAG\dist\archive\20260714-qwen3` and is not the current artifact.

## Final product configuration

| Component | Bundled value |
|---|---|
| Product | OTE-RAG v1.2.0 |
| LLM | `gemma4:12b` |
| Embedding | `bge-m3:latest` |
| Reranker | `onnx-community/bge-reranker-v2-m3-ONNX` dynamic int8 |
| Search | LanceDB dense + Japanese bi-gram BM25 + RRF |
| Sentence cushion | enabled |
| Node.js | v22.20.0 Windows portable |
| Ollama | v0.31.2 Windows complete runtime |
| Services | WinSW, Server/Collector/Ollama |

`versions.lock` records:

```text
package_version=1.2.0
node=v22.20.0
ollama=0.31.2
models=gemma4:12b, bge-m3:latest
reranker=onnx-community/bge-reranker-v2-m3-ONNX (int8)
```

The Windows server environment contains:

```text
OLLAMA_MODEL_PREF=gemma4:12b
EMBEDDING_MODEL_PREF=bge-m3:latest
LANCE_HYBRID_SEARCH=true
LANCE_SENTENCE_CUSHION=true
RERANKER_QUANTIZED=true
```

## Source synchronization

The previous Windows staging tree was based on fork commit `8907620d`.
This build synchronized fork HEAD `ec8d78c1` plus the four staged cushion/reranker files.
There were no deleted source files between the two revisions.

Synchronized changes include:

- Japanese PDF spacing normalization
- Japanese hybrid search and LanceDB sidecar fixes
- localhost-only default binding security fix
- Gemma 4 strict RAG prompt rule 8
- native BGE reranker int8 selection
- sentence extraction cushion

The 11 changed server/collector files were copied individually to
`C:\LocalRAG\src` and their source/destination SHA-256 values matched.

## Offline reranker packaging fix

During the build audit, `export-windows.ps1` was found to delete
`app\server\storage` without restoring the ONNX reranker. Sentence cushion
would therefore attempt a network download on a clean offline installation.

The exporter now requires `-RerankerModelDir`, validates these files, and
copies them to the exact Transformers.js cache path:

```text
app/server/storage/models/onnx-community/bge-reranker-v2-m3-ONNX/
  config.json
  tokenizer.json
  tokenizer_config.json
  special_tokens_map.json
  onnx/model_quantized.onnx
```

The quantized ONNX is 570,727,094 bytes with SHA-256
`912fc1215c2dbff6499700534bd8d31253af01573861abbfc43afd1fab6cce5d`.
The optional fp32 model was intentionally excluded to avoid about 1.1GB of
unused distribution size.

`MODEL_CARDS.md`, `NOTICE`, and `THIRD_PARTY_NOTICES.txt` were updated for
Gemma 4 and BGE reranker. `BGE-RERANKER-V2-M3_LICENSE.txt` is included.

## Model integrity

The Windows Gemma manifest was missing before this build. Its five referenced
objects were copied from the running WSL model store to the Windows model cache.
Every destination object was checked against the digest and size in the manifest.

The final package was independently checked again:

- Gemma 4: 5/5 manifest objects matched SHA-256 and size
- BGE-M3: 3/3 manifest objects matched SHA-256 and size
- BGE reranker int8: SHA-256 matched
- qwen3 manifest: absent
- Japanese candidate reranker (`hotchpotch/...`): absent
- reranker fp32 `model.onnx`: absent
- development LanceDB/SQLite/customer documents: absent

## Archive bug found and fixed

The first build completed, but full zip extraction and checksum verification
failed at `fixtures/local/R07zenpen.pdf?Zone.Identifier` after more than 90,000
successful files. A 25-byte WSL download-attribute sidecar had become a private
Windows filename character; checksum ASCII output rendered it as `?`, while tar
extraction rendered it as `_`.

The invalid build was deleted. The exporter now:

1. excludes `*Zone.Identifier*` during fixture copy;
2. fails before checksum generation if any such sidecar remains anywhere in the package.

The source/staging sidecar was removed, the package was rebuilt, and the complete
zip verification then passed all 100,634 checksum entries.

## Verification performed

- PowerShell parser: `export-windows.ps1` syntax PASS
- Node `--check`: all synchronized runtime JavaScript PASS
- Windows Prisma query engine present
- built OTE-RAG frontend present
- complete Ollama runtime includes `lib\ollama\llama-server.exe`
- critical package source hashes match staging
- zip full extraction PASS (100,635 files)
- extracted `package.sha256` verification PASS=100,634 / FAIL=0
- Windows-native packaged reranker smoke PASS
  - loaded from packaged local cache with packaged Node.js
  - 3 Japanese documents reranked in 36ms
  - first load plus inference 2,219ms
  - correct Constitution Article 9 passage ranked first

The 13GB temporary extraction tree was removed after verification.

## Remaining administrator verification

The build artifact is complete. The following require UAC/admin and remain for
the clean-machine-style Round2 run:

- install and WinSW service registration
- API ping and Windows PowerShell 5.1 E2E 11 checks
- Gemma 4 GPU/VRAM use from Windows service Session 0
- backup, stop/start, and uninstall
- Web UI service control and VRAM release/reload

Current pre-test state is clean:

- `C:\LocalRAGProd`: absent
- `C:\ProgramData\LocalRAG`: absent
- `C:\Temp\localrag-verify`: absent
- `LocalRAG*` Windows services: absent

Run as administrator:

```text
C:\Temp\localrag-round2\Run-Round2-Verify.cmd
```

The runner default is already
`C:\LocalRAG\dist\LocalRAG-win64-v1.2.0.zip`.

## Git state

No commit or push was performed. Existing user/Claude Code changes were preserved.
