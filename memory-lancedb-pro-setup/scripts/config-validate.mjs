#!/usr/bin/env node
/**
 * config-validate.mjs — 校验 openclaw.json 中 memory-lancedb-pro 的配置字段
 *
 * 用法：
 *   node config-validate.mjs                          # 默认读 ~/.openclaw/openclaw.json
 *   node config-validate.mjs --config /path/to/file   # 指定文件
 *   node config-validate.mjs --json '{"embedding":...}'  # 直接传 JSON
 *
 * 退出码：
 *   0 = 全部通过或只有 warn
 *   1 = 有 error 级别问题
 */

import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

// ── 参数解析 ──
const args = process.argv.slice(2);
function getArg(name) {
  const idx = args.indexOf(`--${name}`);
  return idx >= 0 && idx + 1 < args.length ? args[idx + 1] : null;
}

const configPath = getArg("config") || join(process.env.HOME, ".openclaw", "openclaw.json");
const directJson = getArg("json");

// ── 读取配置 ──
let config;
try {
  if (directJson) {
    config = JSON.parse(directJson);
  } else {
    if (!existsSync(configPath)) {
      console.error(`找不到配置文件: ${configPath}`);
      process.exit(1);
    }
    const full = JSON.parse(readFileSync(configPath, "utf8"));
    config = full?.plugins?.entries?.["memory-lancedb-pro"]?.config;
    if (!config) {
      console.error("openclaw.json 中没有 memory-lancedb-pro 配置");
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`读取配置失败: ${err.message}`);
  process.exit(1);
}

// ── 深度取值 ──
function getPath(obj, path) {
  return path.split(".").reduce((o, k) => o?.[k], obj);
}

// ── 校验规则 ──
const results = [];

function check(level, field, message) {
  results.push({ level, field, message });
}

// 必填字段
function requireField(path, label) {
  const val = getPath(config, path);
  if (val === undefined || val === null || val === "") {
    check("error", path, `${label || path} 缺失`);
  } else {
    check("pass", path, `${val}`);
  }
}

// 数值范围
function checkRange(path, min, max, label) {
  const val = getPath(config, path);
  if (val === undefined || val === null) return; // 非必填，不存在就跳过
  if (typeof val !== "number" || !Number.isFinite(val)) {
    check("error", path, `${label || path} 应为数值，当前: ${val}`);
    return;
  }
  if (val < min || val > max) {
    check("warn", path, `${label || path} = ${val}，建议范围 ${min}-${max}`);
  } else {
    check("pass", path, `${val} (范围 ${min}-${max})`);
  }
}

// 整数范围
function checkInt(path, min, max, label) {
  const val = getPath(config, path);
  if (val === undefined || val === null) return;
  if (typeof val !== "number" || !Number.isInteger(val)) {
    check("error", path, `${label || path} 应为整数，当前: ${val}`);
    return;
  }
  if (val < min || val > max) {
    check("warn", path, `${label || path} = ${val}，建议范围 ${min}-${max}`);
  } else {
    check("pass", path, `${val} (范围 ${min}-${max})`);
  }
}

// 枚举值
function checkEnum(path, values, label) {
  const val = getPath(config, path);
  if (val === undefined || val === null) return;
  if (!values.includes(val)) {
    check("error", path, `${label || path} = "${val}"，合法值: ${values.join(", ")}`);
  } else {
    check("pass", path, `${val}`);
  }
}

// ── 执行校验 ──

// 必填
requireField("embedding.model", "embedding 模型");
requireField("embedding.baseURL", "embedding 端点");

// API Key 占位符检查
const apiKeyVal = getPath(config, "embedding.apiKey");
if (apiKeyVal === "YOUR_JINA_API_KEY" || apiKeyVal === "YOUR_API_KEY") {
  check("warn", "embedding.apiKey", `还是占位符 "${apiKeyVal}"，需要替换为真实 Key`);
} else if (!apiKeyVal) {
  check("warn", "embedding.apiKey", "未设置 API Key");
} else {
  check("pass", "embedding.apiKey", "已配置");
}

// 数值范围
checkInt("embedding.dimensions", 64, 4096, "embedding 维度");
checkRange("retrieval.minScore", 0, 1, "最低分数");
checkRange("retrieval.hardMinScore", 0, 1, "硬切分数");
checkInt("retrieval.candidatePoolSize", 5, 200, "候选池大小");
checkRange("retrieval.recencyWeight", 0, 1, "时效权重");
checkInt("autoRecallMinLength", 1, 100, "召回最短长度");
checkInt("autoRecallTopK", 1, 20, "召回 Top K");
checkInt("autoRecallMaxAgeDays", 1, 365, "召回最大天数");

// 枚举
checkEnum("retrieval.mode", ["hybrid", "vector"], "检索模式");
checkEnum("retrieval.rerank", ["cross-encoder", "lightweight", "none"], "精排模式");
checkEnum("sessionStrategy", ["systemSessionMemory", "memoryReflection"], "会话策略");

// 互依赖检查：开了 rerank 必须有 apiKey + endpoint + model
const rerankMode = getPath(config, "retrieval.rerank");
if (rerankMode && rerankMode !== "none") {
  const rerankKey = getPath(config, "retrieval.rerankApiKey");
  const rerankEp = getPath(config, "retrieval.rerankEndpoint");
  const rerankMdl = getPath(config, "retrieval.rerankModel");
  if (!rerankKey) check("error", "retrieval.rerankApiKey", "开了 rerank 但没填 rerankApiKey");
  if (!rerankEp) check("error", "retrieval.rerankEndpoint", "开了 rerank 但没填 rerankEndpoint");
  if (!rerankMdl) check("error", "retrieval.rerankModel", "开了 rerank 但没填 rerankModel");
}

// hardMinScore vs minScore 合理性
const minScore = getPath(config, "retrieval.minScore");
const hardMinScore = getPath(config, "retrieval.hardMinScore");
if (typeof minScore === "number" && typeof hardMinScore === "number") {
  if (hardMinScore > 0.6) {
    check("warn", "retrieval.hardMinScore", `= ${hardMinScore}，太高会过滤掉大部分结果，建议 ≤ 0.55`);
  }
}

// autoRecall 开了但没有 apiKey
const autoRecall = getPath(config, "autoRecall");
if (autoRecall === true && (apiKeyVal === "YOUR_JINA_API_KEY" || apiKeyVal === "YOUR_API_KEY" || !apiKeyVal)) {
  check("warn", "autoRecall", "已开启但 API Key 未配置，召回不会工作");
}

// ── 输出结果 ──
const icons = { pass: "✅", warn: "⚠️ ", error: "❌" };
let hasError = false;

console.log("");
console.log("  配置校验 / Config Validation");
console.log("  ─────────────────────────────");

for (const r of results) {
  console.log(`  ${icons[r.level]} ${r.field} = ${r.message}`);
  if (r.level === "error") hasError = true;
}

const passCount = results.filter((r) => r.level === "pass").length;
const warnCount = results.filter((r) => r.level === "warn").length;
const errCount = results.filter((r) => r.level === "error").length;

console.log("");
if (errCount > 0) {
  console.log(`  结果: ${passCount} 通过, ${warnCount} 警告, ${errCount} 错误`);
} else if (warnCount > 0) {
  console.log(`  结果: ${passCount} 通过, ${warnCount} 警告`);
} else {
  console.log(`  结果: 全部通过 (${passCount}/${passCount})`);
}
console.log("");

// 输出 JSON 供脚本解析
if (args.includes("--json-output")) {
  const output = { results, passCount, warnCount, errCount, hasError };
  console.log(JSON.stringify(output));
}

process.exit(hasError ? 1 : 0);
