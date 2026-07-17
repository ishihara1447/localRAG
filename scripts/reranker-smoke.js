#!/usr/bin/env node

const { NativeEmbeddingReranker } = require(
  "../anything-llm/server/utils/EmbeddingRerankers/native"
);

const query = "日本国憲法で戦力の保持と交戦権はどのように定められていますか";
const documents = [
  { id: "weather", text: "明日の東京は晴れで、最高気温は25度の見込みです。" },
  {
    id: "article-nine",
    text: "日本国憲法第九条は、陸海空軍その他の戦力を保持せず、国の交戦権を認めないと定めています。",
  },
  {
    id: "budget",
    text: "防衛関係費は装備品の取得や隊員の処遇改善などに使われます。",
  },
];

async function main() {
  const reranker = new NativeEmbeddingReranker();
  const startedAt = Date.now();
  const results = await reranker.rerank(query, documents, {
    topK: documents.length,
  });

  console.log(
    JSON.stringify(
      {
        model: reranker.model,
        elapsedMs: Date.now() - startedAt,
        results: results.map(({ id, rerank_score }) => ({
          id,
          score: rerank_score,
        })),
      },
      null,
      2
    )
  );

  if (results[0]?.id !== "article-nine") {
    throw new Error(`unexpected top result: ${results[0]?.id}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
