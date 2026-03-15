#!/usr/bin/env node
/**
 * probe-endpoint.mjs — 通用 OpenAI-compatible API 端口探测
 *
 * 用法：
 *   node probe-endpoint.mjs --baseURL http://localhost:11434/v1 --apiKey ollama
 *   node probe-endpoint.mjs --baseURL https://api.jina.ai/v1 --apiKey jina_xxx --preset jina
 *   node probe-endpoint.mjs --baseURL https://api.openai.com/v1 --apiKey sk-xxx --output result.json
 *
 * 输出 JSON 到 stdout（或 --output 文件）
 */

import { writeFileSync } from "node:fs";

// ── 预设表 ──
const PRESETS = {
  jina: {
    name: "Jina",
    baseURL: "https://api.jina.ai/v1",
    keyPrefix: "jina_",
    keyHint: "https://jina.ai/",
    defaultEmbeddingModel: "jina-embeddings-v5-text-small",
    defaultDimensions: 1024,
    taskQuery: "retrieval.query",
    taskPassage: "retrieval.passage",
    normalized: true,
    rerankEndpoint: "https://api.jina.ai/v1/rerank",
    rerankModel: "jina-reranker-v3",
    rerankProvider: "jina",
  },
  dashscope: {
    name: "阿里云 DashScope",
    baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
    keyPrefix: "sk-",
    keyHint: "https://dashscope.console.aliyun.com/",
    defaultEmbeddingModel: "text-embedding-v4",
    defaultDimensions: 1024,
    rerankEndpoint:
      "https://dashscope.aliyuncs.com/compatible-api/v1/reranks",
    rerankModel: "qwen3-rerank",
    rerankProvider: "jina", // 响应格式兼容
  },
  siliconflow: {
    name: "SiliconFlow",
    baseURL: "https://api.siliconflow.cn/v1",
    keyPrefix: "sk-",
    keyHint: "https://cloud.siliconflow.cn/",
    defaultEmbeddingModel: "BAAI/bge-m3",
    defaultDimensions: 1024,
    rerankEndpoint: "https://api.siliconflow.cn/v1/rerank",
    rerankModel: "BAAI/bge-reranker-v2-m3",
    rerankProvider: "siliconflow",
  },
  openai: {
    name: "OpenAI",
    baseURL: "https://api.openai.com/v1",
    keyPrefix: "sk-",
    keyHint: "https://platform.openai.com/api-keys",
    defaultEmbeddingModel: "text-embedding-3-small",
    defaultDimensions: 1536,
    rerankEndpoint: null,
    rerankModel: null,
    rerankProvider: null,
  },
  ollama: {
    name: "Ollama (本地)",
    baseURL: "http://localhost:11434/v1",
    keyPrefix: null,
    keyHint: null,
    defaultEmbeddingModel: "nomic-embed-text",
    defaultDimensions: 768,
    rerankEndpoint: null,
    rerankModel: null,
    rerankProvider: null,
  },
};

// ── 参数解析 ──
const args = process.argv.slice(2);
function getArg(name) {
  const idx = args.indexOf(`--${name}`);
  return idx >= 0 && idx + 1 < args.length ? args[idx + 1] : null;
}

const presetId = getArg("preset");
const preset = presetId ? PRESETS[presetId] : null;

const baseURL = getArg("baseURL") || preset?.baseURL;
const apiKey = getArg("apiKey") || (preset?.keyPrefix === null ? "ollama" : "");
const embeddingModel = getArg("model") || preset?.defaultEmbeddingModel || null;
const outputFile = getArg("output");
const timeout = parseInt(getArg("timeout") || "15000", 10);

// rerank 参数（优先命令行，其次预设）
const rerankEndpoint = getArg("rerankEndpoint") || preset?.rerankEndpoint || null;
const rerankApiKey = getArg("rerankApiKey") || apiKey;
const rerankModel = getArg("rerankModel") || preset?.rerankModel || null;
const rerankProvider = getArg("rerankProvider") || preset?.rerankProvider || null;

if (!baseURL) {
  console.error("用法: node probe-endpoint.mjs --baseURL <url> --apiKey <key> [--preset <id>]");
  process.exit(1);
}

// ── 通用 fetch 封装 ──
async function safeFetch(url, options = {}) {
  try {
    if (typeof fetch !== "function") {
      return {
        ok: false,
        status: 0,
        error: "global fetch unavailable; please upgrade Node.js to v18+",
      };
    }

    const controller =
      typeof AbortController === "function" ? new AbortController() : null;
    const timer = controller
      ? setTimeout(() => controller.abort(), timeout)
      : null;
    const res = await fetch(url, {
      ...options,
      ...(controller ? { signal: controller.signal } : {}),
    });
    if (timer) clearTimeout(timer);
    return res;
  } catch (err) {
    if (typeof timer !== "undefined" && timer) clearTimeout(timer);
    if (err.name === "AbortError") {
      return { ok: false, status: 0, error: `超时 (${timeout}ms)` };
    }
    return { ok: false, status: 0, error: err.message };
  }
}

function authHeaders() {
  return apiKey
    ? { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" }
    : { "Content-Type": "application/json" };
}

// ── 1. 列出可用模型 ──
const EMBED_PATTERNS = /embed|bge|e5-|gte-|nomic|mxbai|jina-embed|text-embedding/i;

async function listModels() {
  const url = `${baseURL.replace(/\/+$/, "")}/models`;
  const res = await safeFetch(url, { headers: authHeaders() });
  if (!res.ok && !res.json) {
    return { success: false, models: [], error: res.error || `HTTP ${res.status}` };
  }
  try {
    const data = await res.json();
    const models = (data.data || data.models || []).map((m) => ({
      id: m.id || m.name || m.model,
      name: m.id || m.name || m.model,
    }));
    const embeddingModels = models.filter((m) => EMBED_PATTERNS.test(m.id));
    return { success: true, models, embeddingModels };
  } catch {
    return { success: false, models: [], error: "无法解析 /models 响应" };
  }
}

// ── 2. 测试 Embedding ──
async function testEmbedding(model) {
  const url = `${baseURL.replace(/\/+$/, "")}/embeddings`;
  const body = { model, input: "hello world" };

  // Jina 特殊字段
  if (preset?.taskQuery) {
    body.task = preset.taskQuery;
    if (preset.normalized) body.normalized = true;
  }

  const start = Date.now();
  const res = await safeFetch(url, {
    method: "POST",
    headers: authHeaders(),
    body: JSON.stringify(body),
  });

  const latencyMs = Date.now() - start;

  if (!res.ok && !res.json) {
    return { available: false, error: res.error || `HTTP ${res.status}`, latencyMs };
  }

  try {
    const data = await res.json();
    if (data.error) {
      return { available: false, error: data.error.message || JSON.stringify(data.error), latencyMs };
    }
    const vec = data.data?.[0]?.embedding;
    if (!vec || !Array.isArray(vec)) {
      return { available: false, error: "响应中没有 embedding 向量", latencyMs };
    }
    return {
      available: true,
      model,
      dimensions: vec.length,
      latencyMs,
    };
  } catch {
    return { available: false, error: "无法解析 embedding 响应", latencyMs };
  }
}

// ── 3. 测试 Rerank ──
async function testRerank() {
  if (!rerankEndpoint || !rerankModel) {
    return { available: false, reason: "no rerank endpoint configured" };
  }

  // 构造请求（按 provider 格式）
  const headers = {};
  if (rerankProvider === "pinecone") {
    headers["Api-Key"] = rerankApiKey;
  } else {
    headers["Authorization"] = `Bearer ${rerankApiKey}`;
  }
  headers["Content-Type"] = "application/json";

  const body = {
    model: rerankModel,
    query: "什么是记忆系统",
    top_n: 2,
  };

  // 文档格式
  if (rerankProvider === "pinecone") {
    body.documents = [{ text: "记忆系统帮助 AI 记住对话" }, { text: "今天天气很好" }];
  } else {
    body.documents = ["记忆系统帮助 AI 记住对话", "今天天气很好"];
  }

  const start = Date.now();
  const res = await safeFetch(rerankEndpoint, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const latencyMs = Date.now() - start;

  if (!res.ok && !res.json) {
    return { available: false, reason: res.error || `HTTP ${res.status}`, latencyMs };
  }

  try {
    const data = await res.json();
    if (data.error) {
      return { available: false, reason: data.error.message || JSON.stringify(data.error), latencyMs };
    }
    // 检查排序是否正确（相关文档应排第一）
    const results = data.results || data.data || [];
    if (results.length === 0) {
      return { available: false, reason: "rerank 响应为空", latencyMs };
    }
    const topIdx = results[0].index ?? 0;
    return {
      available: true,
      model: rerankModel,
      endpoint: rerankEndpoint,
      provider: rerankProvider,
      apiKey: rerankApiKey,
      correctOrder: topIdx === 0,
      latencyMs,
    };
  } catch {
    return { available: false, reason: "无法解析 rerank 响应", latencyMs };
  }
}

// ── 推荐配置等级 ──
function recommendLevel(embedding, rerank) {
  if (!embedding.available) return "lite-safe";
  if (rerank.available) return "pro-rerank";
  return "balanced-default";
}

// ── 主流程 ──
async function main() {
  const result = {
    baseURL,
    preset: presetId || "custom",
    embedding: { available: false },
    rerank: { available: false },
    availableEmbeddingModels: [],
    recommendedLevel: "lite-safe",
  };

  // 1. 列模型
  const modelList = await listModels();
  if (modelList.success) {
    result.availableEmbeddingModels = modelList.embeddingModels;
  }

  // 2. 确定要测试的 embedding 模型
  let modelToTest = embeddingModel;
  if (!modelToTest && modelList.embeddingModels.length > 0) {
    modelToTest = modelList.embeddingModels[0].id;
  }
  if (!modelToTest && preset?.defaultEmbeddingModel) {
    modelToTest = preset.defaultEmbeddingModel;
  }

  // 3. 测试 embedding
  if (modelToTest) {
    const embResult = await testEmbedding(modelToTest);
    result.embedding = {
      ...embResult,
      apiKey,
      baseURL,
      // Jina 专用字段
      taskQuery: preset?.taskQuery || null,
      taskPassage: preset?.taskPassage || null,
      normalized: preset?.normalized || false,
    };
    // 如果探测成功但没拿到 dimensions，用预设
    if (embResult.available && !embResult.dimensions && preset?.defaultDimensions) {
      result.embedding.dimensions = preset.defaultDimensions;
    }
  } else {
    result.embedding = {
      available: false,
      error: "未找到 embedding 模型。请手动指定 --model 参数",
    };
  }

  // 4. 测试 rerank
  result.rerank = await testRerank();

  // 5. 推荐等级
  result.recommendedLevel = recommendLevel(result.embedding, result.rerank);

  // 输出
  const json = JSON.stringify(result, null, 2);
  if (outputFile) {
    writeFileSync(outputFile, json + "\n", "utf8");
  } else {
    console.log(json);
  }
}

main().catch((err) => {
  console.error("探测失败:", err.message);
  process.exit(1);
});
