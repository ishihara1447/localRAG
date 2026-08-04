#!/usr/bin/env python3
"""コンテナ内の製品コードに TTFT 計測ログだけを差し込むパッチャ。
挙動は変えない（Date.now() の取得と console.log の追加のみ）。
入力: scratchpad/orig/*.js（コンテナから取り出した原本）
出力: scratchpad/patched/*.js
"""
import os, sys

ORIG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "orig")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "patched")
os.makedirs(OUT, exist_ok=True)


def rep(src, old, new, name):
    n = src.count(old)
    if n != 1:
        print(f"!! {name}: 出現 {n} 回 (期待1)\n---\n{old[:200]}\n---")
        sys.exit(1)
    return src.replace(old, new)


# ---------------- lance/index.js ----------------
p = os.path.join(ORIG, "utils_vectorDbProviders_lance_index.js")
s = open(p, encoding="utf-8").read()

# ハイブリッド検索: dense / BM25(FTS) / RRF
s = rep(
    s,
    """    const collection = await client.openTable(namespace);
    const candidateLimit = this.hybridCandidateLimit(topN);
    const denseCandidates = await collection""",
    """    const collection = await client.openTable(namespace);
    const candidateLimit = this.hybridCandidateLimit(topN);
    const __tDense0 = Date.now();
    const denseCandidates = await collection""",
    "lance dense start",
)
s = rep(
    s,
    """    const ftsQuery = tokenizeForFts(query);""",
    """    const __tDense1 = Date.now();
    const ftsQuery = tokenizeForFts(query);""",
    "lance dense end",
)
s = rep(
    s,
    """    const fused = reciprocalRankFusion(denseResults, ftsResults, {
      limit: topN,
    });""",
    """    const __tFts1 = Date.now();
    const fused = reciprocalRankFusion(denseResults, ftsResults, {
      limit: topN,
    });
    const __tRrf1 = Date.now();
    if (global.__TTFT) {
      global.__TTFT.s2_dense_ms = __tDense1 - __tDense0;
      global.__TTFT.s3_bm25_ms = __tFts1 - __tDense1;
      global.__TTFT.s4_rrf_ms = __tRrf1 - __tFts1;
      global.__TTFT.n_dense = denseResults.length;
      global.__TTFT.n_fts = ftsResults.length;
      global.__TTFT.k_candidate = candidateLimit;
    }""",
    "lance rrf",
)

# 埋め込み / 接続 / クッション
s = rep(
    s,
    """    const { client } = await this.connect();
    if (!(await this.namespaceExists(client, namespace))) {
      return {
        contextTexts: [],
        sources: [],
        message: "Invalid query - no documents found for workspace!",
      };
    }

    const queryVector = await LLMConnector.embedTextInput(input);""",
    """    const __tConn0 = Date.now();
    const { client } = await this.connect();
    if (!(await this.namespaceExists(client, namespace))) {
      return {
        contextTexts: [],
        sources: [],
        message: "Invalid query - no documents found for workspace!",
      };
    }
    const __tConn1 = Date.now();
    const queryVector = await LLMConnector.embedTextInput(input);
    const __tEmb1 = Date.now();
    if (global.__TTFT) {
      global.__TTFT.s0_db_connect_ms = __tConn1 - __tConn0;
      global.__TTFT.s1_embed_ms = __tEmb1 - __tConn1;
    }""",
    "lance embed",
)
s = rep(
    s,
    """    result = await applySentenceCushion(input, result, this.logger.bind(this));""",
    """    const __tCu0 = Date.now();
    result = await applySentenceCushion(input, result, this.logger.bind(this));
    if (global.__TTFT)
      global.__TTFT.s5_cushion_ms = (global.__TTFT.s5_cushion_ms || 0) + (Date.now() - __tCu0);""",
    "lance cushion",
)
open(os.path.join(OUT, "lance_index.js"), "w", encoding="utf-8").write(s)

# ---------------- apiChatHandler.js ----------------
p = os.path.join(ORIG, "utils_chats_apiChatHandler.js")
s = open(p, encoding="utf-8").read()

# streamChat の入口（chatSync 側と重複しない一意な文字列を選ぶ必要がある）
anchor = """  let completeText;
  let metrics = {};
  let contextTexts = [];
  let sources = [];
  let pinnedDocIdentifiers = [];
  const { rawHistory, chatHistory } = await recentChatHistory({
    user,
    workspace,
    thread,
    messageLimit,
    apiSessionId: sessionId,
  });"""
cnt = s.count(anchor)
print(f"apiChatHandler 入口アンカー 出現 {cnt} 回")
# chatSync/streamChat 両方にあり得るので、後ろ側(streamChat)だけを置換する
idx = s.rfind(anchor)
if idx < 0:
    print("!! 入口アンカーが無い")
    sys.exit(1)
s = (
    s[:idx]
    + """  let completeText;
  let metrics = {};
  let contextTexts = [];
  let sources = [];
  let pinnedDocIdentifiers = [];
  global.__TTFT = { t_start: Date.now(), topN: workspace?.topN };
  const { rawHistory, chatHistory } = await recentChatHistory({
    user,
    workspace,
    thread,
    messageLimit,
    apiSessionId: sessionId,
  });
  if (global.__TTFT) global.__TTFT.s_history_ms = Date.now() - global.__TTFT.t_start;"""
    + s[idx + len(anchor) :]
)

# 検索全体 / P1 / fillSourceWindow / プロンプト構築 / LLM 呼び出し
anchor2 = """  const vectorSearchResults =
    embeddingsCount !== 0
      ? await VectorDb.performSimilaritySearch({"""
idx = s.rfind(anchor2)
s = (
    s[:idx]
    + """  const __tVs0 = Date.now();
"""
    + s[idx:]
)

anchor3 = """  // LocalRAG P1: 検索が弱いときだけ質問を公式語彙へ言い換えて再検索し結果を統合する"""
idx = s.rfind(anchor3)
s = (
    s[:idx]
    + """  if (global.__TTFT) global.__TTFT.s_vsearch_total_ms = Date.now() - __tVs0;
  const __tP10 = Date.now();
"""
    + s[idx:]
)

anchor4 = """  const { fillSourceWindow } = require("../helpers/chat");
  const filledSources = fillSourceWindow({"""
idx = s.rfind(anchor4)
s = (
    s[:idx]
    + """  if (global.__TTFT) global.__TTFT.s_p1_reformulation_ms = Date.now() - __tP10;
  const __tFsw0 = Date.now();
"""
    + s[idx:]
)

anchor5 = """  // Compress & Assemble message to ensure prompt passes token limit with room for response
  // and build system messages based on inputs and history.
  const streamSystemPrompt = await chatPrompt(workspace, user, {"""
idx = s.rfind(anchor5)
s = (
    s[:idx]
    + """  if (global.__TTFT) global.__TTFT.s_fill_source_window_ms = Date.now() - __tFsw0;
  const __tPb0 = Date.now();
"""
    + s[idx:]
)

anchor6 = """    const stream = await LLMConnector.streamGetChatCompletion(messages, {"""
idx = s.rfind(anchor6)
s = (
    s[:idx]
    + """    if (global.__TTFT) {
      global.__TTFT.s6_prompt_build_ms = Date.now() - __tPb0;
      global.__TTFT.prompt_chars = JSON.stringify(messages).length;
      global.__TTFT.n_context = contextTexts.length;
      global.__TTFT.t_llm_call = Date.now();
    }
"""
    + s[idx:]
)
open(os.path.join(OUT, "apiChatHandler.js"), "w", encoding="utf-8").write(s)

# ---------------- ollama/index.js ----------------
p = os.path.join(ORIG, "utils_AiProviders_ollama_index.js")
s = open(p, encoding="utf-8").read()

# done チャンクで Ollama 側の内訳（prompt_eval / eval）を拾う
s = rep(
    s,
    """          if (chunk.done) {
            usage.prompt_tokens = chunk.prompt_eval_count;
            usage.completion_tokens = chunk.eval_count;
            usage.duration = chunk.eval_duration / 1e9;""",
    """          if (chunk.done) {
            usage.prompt_tokens = chunk.prompt_eval_count;
            usage.completion_tokens = chunk.eval_count;
            usage.duration = chunk.eval_duration / 1e9;
            if (global.__TTFT) {
              global.__TTFT.o_prompt_eval_count = chunk.prompt_eval_count;
              global.__TTFT.o_prompt_eval_ms = Math.round(
                (chunk.prompt_eval_duration || 0) / 1e6
              );
              global.__TTFT.o_load_ms = Math.round((chunk.load_duration || 0) / 1e6);
              global.__TTFT.o_eval_count = chunk.eval_count;
              global.__TTFT.o_eval_ms = Math.round((chunk.eval_duration || 0) / 1e6);
              global.__TTFT.o_total_ms = Math.round((chunk.total_duration || 0) / 1e6);
              global.__TTFT.answer_chars = fullText.length;
              global.__TTFT.total_ms = Date.now() - global.__TTFT.t_start;
              console.log("[TTFT_DONE] " + JSON.stringify(global.__TTFT));
            }""",
    "ollama done",
)

# 最初の本文トークンで TTFT を確定させる
s = rep(
    s,
    """            } else if (content.length > 0) {
              // If we have reasoning text, we need to close the reasoning tag and then append the content.""",
    """            } else if (content.length > 0) {
              if (global.__TTFT && !global.__TTFT.s7_first_token_ms) {
                const __now = Date.now();
                global.__TTFT.s7_llm_to_first_token_ms =
                  __now - (global.__TTFT.t_llm_call || __now);
                global.__TTFT.s7_first_token_ms = __now - global.__TTFT.t_start;
                console.log("[TTFT_FIRST] " + JSON.stringify(global.__TTFT));
              }
              // If we have reasoning text, we need to close the reasoning tag and then append the content.""",
    "ollama first token",
)
open(os.path.join(OUT, "ollama_index.js"), "w", encoding="utf-8").write(s)

print("patched OK ->", OUT)
