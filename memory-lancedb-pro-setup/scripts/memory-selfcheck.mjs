#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import process from "node:process";

const DEFAULT_TIMEOUT_MS = 15000;
const DEFAULT_REPORT = {
  metadata: {},
  overall: { status: "fail", blocking: false },
  embedding: { status: "skip" },
  rerank: { status: "skip" },
  hostModel: {
    recall: { status: "skip" },
    json: { status: "skip" },
  },
  recommendedProfile: "lite-safe",
  messages: [],
};

const DEFAULT_FIXTURES = {
  embeddingQuery: "我喜欢喝什么咖啡",
  embeddingDocuments: [
    "用户喜欢冷萃咖啡，不喜欢太甜。",
    "用户最近在研究量子计算。",
    "用户不喝咖啡，只喝热牛奶。",
  ],
  rerankQuery: "我喜欢喝什么咖啡",
  rerankDocuments: [
    "用户喜欢冷萃咖啡，不喜欢太甜。",
    "用户最近在研究量子计算。",
    "用户不喝咖啡，只喝热牛奶。",
  ],
  memoryPack: [
    "偏好：用户喜欢冷萃咖啡。",
    "忌口：用户不喜欢太甜。",
    "背景：用户最近在研究量子计算。",
  ],
  recallQuestion: "我平时喝什么咖啡？",
  recallExpected: ["冷萃咖啡"],
  jsonExpected: {
    drink: "冷萃咖啡",
    sweetness: "不要太甜",
  },
};

function parseArgs(argv) {
  const args = {
    configPath: "",
    outputPath: "",
    format: "pretty",
    timeoutMs: DEFAULT_TIMEOUT_MS,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--config":
        args.configPath = argv[++index] ?? "";
        break;
      case "--output":
        args.outputPath = argv[++index] ?? "";
        break;
      case "--format":
        args.format = argv[++index] ?? "pretty";
        break;
      case "--timeout-ms":
        args.timeoutMs = Number(argv[++index] ?? DEFAULT_TIMEOUT_MS);
        break;
      case "--help":
      case "-h":
        printHelp();
        process.exit(0);
        break;
      default:
        throw new Error(`未知参数: ${arg}`);
    }
  }

  if (!args.configPath) {
    throw new Error("缺少 --config <path>");
  }
  if (!Number.isFinite(args.timeoutMs) || args.timeoutMs <= 0) {
    throw new Error("--timeout-ms 必须是正整数");
  }
  if (!["pretty", "json"].includes(args.format)) {
    throw new Error("--format 仅支持 pretty 或 json");
  }

  return args;
}

function printHelp() {
  console.log(`用法:
  node scripts/memory-selfcheck.mjs --config selfcheck.json [--output report.json] [--format pretty|json]

配置示例:
{
  "embedding": {
    "apiKey": "...",
    "baseURL": "https://api.jina.ai/v1",
    "model": "jina-embeddings-v5-text-small",
    "dimensions": 1024,
    "queryExtraBody": { "task": "retrieval.query", "normalized": true },
    "passageExtraBody": { "task": "retrieval.passage", "normalized": true }
  },
  "rerank": {
    "apiKey": "...",
    "endpoint": "https://api.jina.ai/v1/rerank",
    "model": "jina-reranker-v3"
  },
  "hostModel": {
    "apiKey": "...",
    "baseURL": "https://api.openai.com/v1",
    "model": "gpt-4.1-mini"
  }
}`);
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(`参数错误: ${error.message}`);
    process.exit(2);
  }

  const report = structuredClone(DEFAULT_REPORT);

  try {
    const rawConfig = await readFile(args.configPath, "utf8");
    const config = JSON.parse(rawConfig);
    const mergedConfig = normalizeConfig(config, args.timeoutMs);

    report.metadata = {
      generatedAt: new Date().toISOString(),
      configPath: args.configPath,
      timeoutMs: mergedConfig.timeoutMs,
      label: mergedConfig.metadata.label ?? null,
    };

    if (!mergedConfig.embedding) {
      throw new Error("至少需要配置 embedding 探测");
    }

    report.embedding = await probeEmbedding(mergedConfig.embedding, mergedConfig.thresholds);

    if (mergedConfig.rerank) {
      report.rerank = await probeRerank(mergedConfig.rerank, mergedConfig.thresholds);
    }

    if (mergedConfig.hostModel) {
      report.hostModel = await probeHostModel(mergedConfig.hostModel, mergedConfig.thresholds);
    }

    finalizeReport(report);
  } catch (error) {
    report.overall = {
      status: "fail",
      blocking: true,
      reason: error.message,
    };
    report.messages.push(`自检执行失败: ${error.message}`);
  }

  const serialized = JSON.stringify(report, null, 2);
  if (args.outputPath) {
    await writeFile(args.outputPath, `${serialized}\n`, "utf8");
  }

  if (args.format === "json") {
    console.log(serialized);
  } else {
    printPrettyReport(report);
  }

  process.exit(report.overall.blocking ? 1 : 0);
}

function normalizeConfig(config, timeoutMs) {
  return {
    metadata: config.metadata ?? {},
    timeoutMs: config.timeoutMs ?? timeoutMs,
    thresholds: {
      embeddingGap: config.thresholds?.embeddingGap ?? 0.08,
      rerankLatencyMs: config.thresholds?.rerankLatencyMs ?? 2200,
      hostLatencyMs: config.thresholds?.hostLatencyMs ?? 5000,
      jsonRuns: config.thresholds?.jsonRuns ?? 2,
      expectedBestIndex: config.thresholds?.expectedBestIndex ?? 0,
      ...config.thresholds,
    },
    embedding: config.embedding ? normalizeEmbeddingConfig(config.embedding, config.timeoutMs ?? timeoutMs) : null,
    rerank: config.rerank ? normalizeRerankConfig(config.rerank, config.timeoutMs ?? timeoutMs) : null,
    hostModel: config.hostModel ? normalizeHostConfig(config.hostModel, config.timeoutMs ?? timeoutMs) : null,
  };
}

function normalizeEmbeddingConfig(config, timeoutMs) {
  return {
    apiKey: requireString(config.apiKey, "embedding.apiKey"),
    endpoint: config.endpoint ?? resolveApiUrl(config.baseURL, "/embeddings", "embedding.baseURL"),
    model: requireString(config.model, "embedding.model"),
    dimensions: config.dimensions ?? null,
    headers: config.headers ?? {},
    timeoutMs,
    queryInput: config.queryInput ?? DEFAULT_FIXTURES.embeddingQuery,
    passageInputs: config.passageInputs ?? DEFAULT_FIXTURES.embeddingDocuments,
    extraBody: config.extraBody ?? {},
    queryExtraBody: config.queryExtraBody ?? {},
    passageExtraBody: config.passageExtraBody ?? {},
  };
}

function normalizeRerankConfig(config, timeoutMs) {
  return {
    apiKey: requireString(config.apiKey, "rerank.apiKey"),
    endpoint: config.endpoint ?? resolveApiUrl(config.baseURL, "/rerank", "rerank.baseURL"),
    model: requireString(config.model, "rerank.model"),
    headers: config.headers ?? {},
    timeoutMs,
    query: config.query ?? DEFAULT_FIXTURES.rerankQuery,
    documents: config.documents ?? DEFAULT_FIXTURES.rerankDocuments,
    topN: config.topN ?? 2,
    extraBody: config.extraBody ?? {},
  };
}

function normalizeHostConfig(config, timeoutMs) {
  return {
    apiKey: requireString(config.apiKey, "hostModel.apiKey"),
    endpoint: config.endpoint ?? resolveApiUrl(config.baseURL, "/chat/completions", "hostModel.baseURL"),
    model: requireString(config.model, "hostModel.model"),
    headers: config.headers ?? {},
    timeoutMs,
    extraBody: config.extraBody ?? {},
    memoryPack: config.memoryPack ?? DEFAULT_FIXTURES.memoryPack,
    recallQuestion: config.recallQuestion ?? DEFAULT_FIXTURES.recallQuestion,
    recallExpected: config.recallExpected ?? DEFAULT_FIXTURES.recallExpected,
    jsonExpected: config.jsonExpected ?? DEFAULT_FIXTURES.jsonExpected,
  };
}

function requireString(value, fieldName) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${fieldName} 不能为空`);
  }
  return value;
}

function resolveApiUrl(baseURL, suffix, fieldName) {
  const normalizedBase = requireString(baseURL, fieldName).replace(/\/+$/, "");
  return `${normalizedBase}${suffix}`;
}

async function probeEmbedding(config, thresholds) {
  const result = {
    status: "fail",
    endpoint: maskEndpoint(config.endpoint),
    model: config.model,
    dimensions: config.dimensions,
    latencyMs: null,
    topMatchIndex: null,
    similarities: [],
    reason: "",
  };

  try {
    const queryResponse = await requestJson(config.endpoint, {
      method: "POST",
      headers: buildAuthHeaders(config.apiKey, config.headers),
      timeoutMs: config.timeoutMs,
      body: {
        model: config.model,
        input: config.queryInput,
        dimensions: config.dimensions ?? undefined,
        encoding_format: "float",
        ...config.extraBody,
        ...config.queryExtraBody,
      },
    });

    const passageResponse = await requestJson(config.endpoint, {
      method: "POST",
      headers: buildAuthHeaders(config.apiKey, config.headers),
      timeoutMs: config.timeoutMs,
      body: {
        model: config.model,
        input: config.passageInputs,
        dimensions: config.dimensions ?? undefined,
        encoding_format: "float",
        ...config.extraBody,
        ...config.passageExtraBody,
      },
    });

    const queryVector = queryResponse.data?.[0]?.embedding;
    const passageVectors = (passageResponse.data ?? []).map((item) => item.embedding);
    const allVectors = [queryVector, ...passageVectors];

    if (!Array.isArray(queryVector) || !passageVectors.every((vector) => Array.isArray(vector))) {
      throw new Error("embedding 响应里没有拿到合法向量");
    }

    const lengths = allVectors.map((vector) => vector.length);
    result.latencyMs = queryResponse.latencyMs + passageResponse.latencyMs;

    if (config.dimensions && !lengths.every((length) => length === config.dimensions)) {
      throw new Error(`向量维度不匹配，期望 ${config.dimensions}，实际 ${lengths.join(", ")}`);
    }

    const similarities = passageVectors.map((vector, index) => ({
      index,
      score: cosineSimilarity(queryVector, vector),
      document: config.passageInputs[index],
    }));
    similarities.sort((left, right) => right.score - left.score);

    result.topMatchIndex = similarities[0]?.index ?? null;
    result.similarities = similarities.map((item) => ({
      index: item.index,
      score: round(item.score),
    }));

    if (result.topMatchIndex !== thresholds.expectedBestIndex) {
      result.status = "warn";
      result.reason = `最相关文档命中了第 ${result.topMatchIndex ?? "?"} 条，不是预期的第 ${thresholds.expectedBestIndex} 条`;
      return result;
    }

    const gap = (similarities[0]?.score ?? 0) - (similarities[1]?.score ?? 0);
    if (gap < thresholds.embeddingGap) {
      result.status = "warn";
      result.reason = `embedding 区分度偏弱，top1-top2=${round(gap)}`;
      return result;
    }

    result.status = "pass";
    result.reason = `embedding 可用，top1-top2=${round(gap)}`;
    return result;
  } catch (error) {
    result.status = "fail";
    result.reason = error.message;
    return result;
  }
}

async function probeRerank(config, thresholds) {
  const result = {
    status: "fail",
    endpoint: maskEndpoint(config.endpoint),
    model: config.model,
    latencyMs: null,
    topMatchIndex: null,
    results: [],
    reason: "",
  };

  try {
    const response = await requestJson(config.endpoint, {
      method: "POST",
      headers: buildAuthHeaders(config.apiKey, config.headers),
      timeoutMs: config.timeoutMs,
      body: {
        model: config.model,
        query: config.query,
        documents: config.documents,
        top_n: Math.min(config.topN, config.documents.length),
        ...config.extraBody,
      },
    });

    const results = Array.isArray(response.results) ? response.results : [];
    const topIndex = results[0]?.index ?? null;
    result.latencyMs = response.latencyMs;
    result.topMatchIndex = topIndex;
    result.results = results.map((item) => ({
      index: item.index,
      score: round(item.relevance_score ?? item.score ?? 0),
    }));

    if (topIndex !== thresholds.expectedBestIndex) {
      result.status = "warn";
      result.reason = `rerank top1 命中了第 ${topIndex ?? "?"} 条，不是预期的第 ${thresholds.expectedBestIndex} 条`;
      return result;
    }

    if (response.latencyMs > thresholds.rerankLatencyMs) {
      result.status = "warn";
      result.reason = `rerank 可用，但延迟偏高（${response.latencyMs}ms）`;
      return result;
    }

    result.status = "pass";
    result.reason = "rerank 可用且结果稳定";
    return result;
  } catch (error) {
    result.status = "fail";
    result.reason = error.message;
    return result;
  }
}

async function probeHostModel(config, thresholds) {
  const recall = await probeHostRecall(config, thresholds);
  const json = await probeHostJson(config, thresholds);
  return { recall, json };
}

async function probeHostRecall(config, thresholds) {
  const result = {
    status: "fail",
    endpoint: maskEndpoint(config.endpoint),
    model: config.model,
    latencyMs: null,
    reply: "",
    reason: "",
  };

  const messages = [
    {
      role: "system",
      content: "你是一个测试助手。只能依据提供的记忆回答，不要编造，也不要复述无关内容。",
    },
    {
      role: "user",
      content: [
        "下面是系统召回给你的记忆：",
        ...config.memoryPack.map((item) => `- ${item}`),
        "",
        `问题：${config.recallQuestion}`,
        "要求：只用一句中文回答。",
      ].join("\n"),
    },
  ];

  try {
    const response = await requestJson(config.endpoint, {
      method: "POST",
      headers: buildAuthHeaders(config.apiKey, config.headers),
      timeoutMs: config.timeoutMs,
      body: {
        model: config.model,
        messages,
        temperature: 0,
        ...config.extraBody,
      },
    });

    const reply = extractMessageText(response);
    result.latencyMs = response.latencyMs;
    result.reply = reply;

    if (!containsAll(reply, config.recallExpected)) {
      result.status = "warn";
      result.reason = `模型没有稳定命中记忆答案，返回：${reply}`;
      return result;
    }

    if (response.latencyMs > thresholds.hostLatencyMs) {
      result.status = "warn";
      result.reason = `宿主模型能利用记忆，但响应较慢（${response.latencyMs}ms）`;
      return result;
    }

    result.status = "pass";
    result.reason = "宿主模型能正确利用召回记忆";
    return result;
  } catch (error) {
    result.status = "fail";
    result.reason = error.message;
    return result;
  }
}

async function probeHostJson(config, thresholds) {
  const result = {
    status: "fail",
    endpoint: maskEndpoint(config.endpoint),
    model: config.model,
    passedRuns: 0,
    totalRuns: thresholds.jsonRuns,
    reasons: [],
  };

  const prompt = [
    "只输出 JSON，不要输出任何解释。",
    "字段必须是 drink 和 sweetness。",
    '示例值风格：{"drink":"冷萃咖啡","sweetness":"不要太甜"}',
  ].join("\n");

  for (let run = 0; run < thresholds.jsonRuns; run += 1) {
    try {
      const response = await requestJson(config.endpoint, {
        method: "POST",
        headers: buildAuthHeaders(config.apiKey, config.headers),
        timeoutMs: config.timeoutMs,
        body: {
          model: config.model,
          messages: [{ role: "user", content: prompt }],
          temperature: 0,
          ...config.extraBody,
        },
      });

      const reply = extractMessageText(response);
      const parsed = extractJsonObject(reply);
      const drinkOk = parsed?.drink === config.jsonExpected.drink;
      const sweetnessOk = parsed?.sweetness === config.jsonExpected.sweetness;

      if (drinkOk && sweetnessOk) {
        result.passedRuns += 1;
      } else {
        result.reasons.push(`第 ${run + 1} 次 JSON 不符合预期: ${reply}`);
      }
    } catch (error) {
      result.reasons.push(`第 ${run + 1} 次 JSON 探测失败: ${error.message}`);
    }
  }

  if (result.passedRuns === thresholds.jsonRuns) {
    result.status = "pass";
  } else if (result.passedRuns >= 1) {
    result.status = "warn";
  } else {
    result.status = "fail";
  }

  return result;
}

async function requestJson(url, options) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs);
  const startedAt = Date.now();

  try {
    const response = await fetch(url, {
      method: options.method,
      headers: {
        "Content-Type": "application/json",
        ...options.headers,
      },
      body: JSON.stringify(options.body),
      signal: controller.signal,
    });

    const text = await response.text();
    const latencyMs = Date.now() - startedAt;

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${truncate(text, 220)}`);
    }

    let json;
    try {
      json = JSON.parse(text);
    } catch (error) {
      throw new Error(`响应不是合法 JSON: ${truncate(text, 220)}`);
    }

    return { ...json, latencyMs };
  } catch (error) {
    if (error.name === "AbortError") {
      throw new Error(`请求超时（>${options.timeoutMs}ms）`);
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function buildAuthHeaders(apiKey, headers) {
  return {
    Authorization: `Bearer ${apiKey}`,
    ...headers,
  };
}

function extractMessageText(response) {
  const content = response.choices?.[0]?.message?.content;
  if (typeof content === "string") {
    return content.trim();
  }
  if (Array.isArray(content)) {
    return content
      .map((item) => {
        if (typeof item === "string") {
          return item;
        }
        if (item?.type === "text" && typeof item.text === "string") {
          return item.text;
        }
        return "";
      })
      .join("")
      .trim();
  }
  throw new Error("chat 响应里没有拿到文本内容");
}

function extractJsonObject(reply) {
  const candidate = reply.match(/\{[\s\S]*\}/)?.[0] ?? reply;
  try {
    return JSON.parse(candidate);
  } catch {
    return null;
  }
}

function cosineSimilarity(left, right) {
  let dot = 0;
  let leftNorm = 0;
  let rightNorm = 0;
  const length = Math.min(left.length, right.length);

  for (let index = 0; index < length; index += 1) {
    dot += left[index] * right[index];
    leftNorm += left[index] * left[index];
    rightNorm += right[index] * right[index];
  }

  if (leftNorm === 0 || rightNorm === 0) {
    return 0;
  }
  return dot / (Math.sqrt(leftNorm) * Math.sqrt(rightNorm));
}

function containsAll(text, expectedParts) {
  return expectedParts.every((part) => text.includes(part));
}

function truncate(text, maxLength) {
  if (!text || text.length <= maxLength) {
    return text;
  }
  return `${text.slice(0, maxLength - 1)}…`;
}

function maskEndpoint(endpoint) {
  try {
    const url = new URL(endpoint);
    return `${url.origin}${url.pathname}`;
  } catch {
    return endpoint;
  }
}

function round(value) {
  return Math.round(value * 10000) / 10000;
}

function finalizeReport(report) {
  const messages = [];

  if (report.embedding.status === "fail") {
    report.recommendedProfile = "lite-safe";
    report.overall = {
      status: "fail",
      blocking: true,
      reason: report.embedding.reason,
    };
    messages.push(`Embedding 不可用，安装应中止：${report.embedding.reason}`);
    report.messages = messages;
    return;
  }

  if (report.embedding.status === "warn") {
    report.recommendedProfile = "lite-safe";
    messages.push(`Embedding 可用但质量偏弱，建议先用 lite-safe：${report.embedding.reason}`);
  } else {
    messages.push(`Embedding 通过：${report.embedding.reason}`);
  }

  if (report.rerank.status === "pass") {
    messages.push("Rerank 通过，可以考虑开启 pro-rerank。");
  } else if (report.rerank.status === "warn") {
    messages.push(`Rerank 可用但不建议默认开启：${report.rerank.reason}`);
  } else if (report.rerank.status === "fail") {
    messages.push(`Rerank 不可用，建议关闭：${report.rerank.reason}`);
  }

  if (report.hostModel.recall.status === "pass") {
    messages.push("宿主模型能利用召回记忆。");
  } else if (report.hostModel.recall.status === "warn") {
    messages.push(`宿主模型利用召回记忆不稳定：${report.hostModel.recall.reason}`);
  } else if (report.hostModel.recall.status === "fail") {
    messages.push(`宿主模型不适合 aggressive recall：${report.hostModel.recall.reason}`);
  }

  if (report.hostModel.json.status === "warn") {
    messages.push("宿主模型结构化输出不稳定，复杂自动化场景建议保守配置。");
  } else if (report.hostModel.json.status === "fail") {
    messages.push("宿主模型结构化输出较弱，避免依赖严格 JSON 流程。");
  }

  const hostRecallIsWeak = ["warn", "fail"].includes(report.hostModel.recall.status);
  const hostRecallMissing = report.hostModel.recall.status === "skip";
  const rerankStrong = report.rerank.status === "pass";
  const embeddingStrong = report.embedding.status === "pass";

  if (!embeddingStrong) {
    report.recommendedProfile = "lite-safe";
  } else if (hostRecallIsWeak) {
    report.recommendedProfile = "lite-safe";
  } else if (rerankStrong && !hostRecallMissing) {
    report.recommendedProfile = "pro-rerank";
  } else if (rerankStrong && hostRecallMissing) {
    report.recommendedProfile = "pro-rerank";
    messages.push("未提供宿主模型探测，pro-rerank 仅基于检索栈能力推荐。");
  } else {
    report.recommendedProfile = "balanced-default";
  }

  report.overall = {
    status: messages.some((message) => message.includes("建议")) ? "warn" : "pass",
    blocking: false,
  };
  report.messages = messages;
}

function printPrettyReport(report) {
  const lines = [
    "================ Memory Self-Check ================",
    `overall: ${report.overall.status}${report.overall.blocking ? " (blocking)" : ""}`,
    `recommendedProfile: ${report.recommendedProfile}`,
    "",
    `embedding: ${report.embedding.status}`,
    `  model: ${report.embedding.model ?? "-"}`,
    `  reason: ${report.embedding.reason ?? "-"}`,
  ];

  if (report.embedding.latencyMs != null) {
    lines.push(`  latencyMs: ${report.embedding.latencyMs}`);
  }
  if (report.embedding.similarities?.length) {
    lines.push(`  similarities: ${report.embedding.similarities.map((item) => `${item.index}:${item.score}`).join(", ")}`);
  }

  lines.push("");
  lines.push(`rerank: ${report.rerank.status}`);
  lines.push(`  model: ${report.rerank.model ?? "-"}`);
  lines.push(`  reason: ${report.rerank.reason ?? "-"}`);

  if (report.rerank.latencyMs != null) {
    lines.push(`  latencyMs: ${report.rerank.latencyMs}`);
  }

  lines.push("");
  lines.push(`host.recall: ${report.hostModel.recall.status}`);
  lines.push(`  reason: ${report.hostModel.recall.reason ?? "-"}`);
  lines.push(`host.json: ${report.hostModel.json.status}`);
  lines.push(`  passedRuns: ${report.hostModel.json.passedRuns ?? 0}/${report.hostModel.json.totalRuns ?? 0}`);

  if (report.messages.length) {
    lines.push("");
    lines.push("messages:");
    for (const message of report.messages) {
      lines.push(`- ${message}`);
    }
  }

  lines.push("===================================================");
  console.log(lines.join("\n"));
}

await main();
