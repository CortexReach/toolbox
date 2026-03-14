#!/usr/bin/env bash
# ============================================================
#  memory-lancedb-pro 一键安装脚本（全自动版） v1.1
#
#  用法：
#    bash setup-memory.sh            # 正常安装
#    bash setup-memory.sh --dry-run  # 只展示会做什么，不实际执行
#    bash setup-memory.sh --selfcheck-only  # 只跑能力自检，不改配置
#    bash setup-memory.sh --uninstall # 还原配置并移除插件
#
#  安全机制：
#    - 改 openclaw.json 前自动备份
#    - 用 jq 做深度合并，已有配置不覆盖
#    - 检测到已有 memory 插件时停下来问用户
#    - 没有 jq 则降级为手动模式
#
#  文档：docs/complete-guide-cn.md
# ============================================================

set -euo pipefail

# ── 参数解析 ──
DRY_RUN=false
UNINSTALL=false
SELFCHECK_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=true ;;
    --uninstall) UNINSTALL=true ;;
    --selfcheck-only) SELFCHECK_ONLY=true ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_CHECK_SCRIPT="$SCRIPT_DIR/scripts/memory-selfcheck.mjs"

# ── 颜色输出 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
dry()     { echo -e "${YELLOW}[DRY-RUN]${NC} 将会执行: $1"; }

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  memory-lancedb-pro 一键安装向导${NC}"
echo -e "${BOLD}========================================${NC}"
if $DRY_RUN; then
  echo -e "${YELLOW}  ⚡ DRY-RUN 模式：只展示操作，不实际执行${NC}"
fi
echo ""

# ============================================================
#  卸载流程
# ============================================================
if $UNINSTALL; then
  info "进入卸载模式..."

  OPENCLAW_JSON="$HOME/.openclaw/openclaw.json"
  if [[ ! -f "$OPENCLAW_JSON" ]]; then
    fail "找不到 $OPENCLAW_JSON"
  fi

  # 查找最近的备份
  LATEST_BACKUP=$(ls -t "$OPENCLAW_JSON".backup.* 2>/dev/null | head -1 || echo "")

  if [[ -n "$LATEST_BACKUP" ]]; then
    echo ""
    echo "  找到备份文件：$LATEST_BACKUP"
    echo "  备份时间：$(stat -f '%Sm' "$LATEST_BACKUP" 2>/dev/null || stat -c '%y' "$LATEST_BACKUP" 2>/dev/null || echo '未知')"
    echo ""
    read -p "  要还原这个备份吗？(y/n) [y]: " RESTORE
    RESTORE=${RESTORE:-y}
    if [[ "$RESTORE" == "y" || "$RESTORE" == "Y" ]]; then
      cp "$OPENCLAW_JSON" "$OPENCLAW_JSON.before-uninstall.$(date +%Y%m%d_%H%M%S)"
      cp "$LATEST_BACKUP" "$OPENCLAW_JSON"
      success "openclaw.json 已还原"
    fi
  else
    warn "没有找到备份文件，跳过配置还原。"
    echo "  如果要手动清理，请编辑 $OPENCLAW_JSON 删除 memory-lancedb-pro 相关配置。"
  fi

  # 询问是否删除插件目录
  WORKSPACE=$(openclaw config get agents.defaults.workspace 2>/dev/null | tr -d '"' | tr -d ' ' || echo "")
  PLUGIN_DIR="$WORKSPACE/plugins/memory-lancedb-pro"
  if [[ -d "$PLUGIN_DIR" ]]; then
    echo ""
    read -p "  要删除插件目录 $PLUGIN_DIR 吗？(y/n) [n]: " DEL_PLUGIN
    DEL_PLUGIN=${DEL_PLUGIN:-n}
    if [[ "$DEL_PLUGIN" == "y" || "$DEL_PLUGIN" == "Y" ]]; then
      # 移到 Trash 而不是 rm -rf
      if [[ -d "$HOME/.Trash" ]]; then
        mv "$PLUGIN_DIR" "$HOME/.Trash/memory-lancedb-pro.$(date +%Y%m%d_%H%M%S)"
        success "插件目录已移到废纸篓"
      else
        rm -rf "$PLUGIN_DIR"
        success "插件目录已删除"
      fi
    fi
  fi

  echo ""
  success "卸载完成。运行 openclaw gateway restart 使配置生效。"
  exit 0
fi

# ============================================================
#  安装流程
# ============================================================

# ── 第 1 步：环境检查 ──
info "第 1 步：环境检查..."

# 检查 node
if ! command -v node &>/dev/null; then
  fail "找不到 node。请先安装 Node.js（推荐 v18+）：https://nodejs.org"
fi
NODE_VER=$(node --version)
success "Node.js $NODE_VER"

if $SELFCHECK_ONLY; then
  warn "--selfcheck-only 模式将跳过 OpenClaw / workspace / 插件安装，只做能力探测。"
else
  # 检查 openclaw
  command -v openclaw >/dev/null 2>&1 || fail "找不到 openclaw 命令，请先安装 OpenClaw。"
  success "openclaw CLI 已找到"

  # 检查 npm
  command -v npm &>/dev/null || fail "找不到 npm，请重新安装 Node.js。"
fi

# 检查 jq（关键：决定能否自动改配置）
HAS_JQ=false
if ! $SELFCHECK_ONLY && command -v jq &>/dev/null; then
  HAS_JQ=true
  success "jq 已找到（将自动合并配置）"
elif ! $SELFCHECK_ONLY; then
  warn "未安装 jq — 配置文件需要手动编辑"
  echo "     安装 jq 后可实现全自动：brew install jq（Mac）或 apt install jq（Linux）"
fi

# ── 第 2 步：确认 workspace ──
echo ""
info "第 2 步：确认 workspace 路径..."

if $SELFCHECK_ONLY; then
  WORKSPACE=""
  success "selfcheck-only 模式跳过 workspace 检查"
else
  WORKSPACE=$(openclaw config get agents.defaults.workspace 2>/dev/null | tr -d '"' | tr -d ' ' || echo "")
  if [[ -z "$WORKSPACE" || ! -d "$WORKSPACE" ]]; then
    echo ""
    echo "  无法自动获取 workspace 路径。"
    read -p "  请手动输入你的 OpenClaw workspace 路径: " WORKSPACE
    [[ -d "$WORKSPACE" ]] || fail "路径不存在：$WORKSPACE"
  fi
  success "workspace: $WORKSPACE"
fi

PLUGIN_DIR="$WORKSPACE/plugins/memory-lancedb-pro"
OPENCLAW_JSON="$HOME/.openclaw/openclaw.json"

# ── 第 3 步：安装模式 ──
echo ""
info "第 3 步：安装模式..."
echo ""
echo -e "  ${BOLD}1) auto-probe${NC}        — 自动探测 embedding / rerank 能力并推荐模板 ${GREEN}← 推荐${NC}"
echo -e "  ${BOLD}2) manual${NC}            — 我自己选模板"
echo ""
read -p "输入数字 (1/2)，直接回车选 1: " MODE_CHOICE
MODE_CHOICE=${MODE_CHOICE:-1}

case "$MODE_CHOICE" in
  1) PROFILE_MODE="auto-probe" ;;
  2) PROFILE_MODE="manual" ;;
  *) fail "无效选择，请输入 1 或 2。" ;;
esac
success "安装模式：$PROFILE_MODE"

# ── 第 4 步：获取 Jina API Key ──
echo ""
info "第 4 步：Jina API Key..."
echo ""
echo "  Jina 是记忆检索用的 embedding 服务，免费注册就能用。"
echo "  注册地址：https://jina.ai/"
echo "  如果暂时没有，直接回车跳过（之后手动填）。"
echo ""
read -p "JINA_API_KEY: " JINA_KEY

if [[ -z "$JINA_KEY" ]]; then
  warn "未填写 Key，配置里保留占位符 YOUR_JINA_API_KEY，记得之后替换。"
  JINA_KEY="YOUR_JINA_API_KEY"
else
  if [[ "$JINA_KEY" != jina_* ]]; then
    warn "Key 不是以 jina_ 开头，请确认是否正确。"
    read -p "  继续？(y/n) [y]: " CONFIRM
    [[ "${CONFIRM:-y}" =~ ^[yY]$ ]] || fail "用户取消。"
  fi
  success "API Key 已记录"
fi

# ── 第 5 步：能力自检 / 选模板 ──
echo ""
info "第 5 步：能力自检 / 选模板..."

TEMPLATE=""
SELFCHECK_REPORT=""

run_selfcheck() {
  local INPUT_JSON="$1"
  local REPORT_JSON="$2"

  if [[ ! -f "$SELF_CHECK_SCRIPT" ]]; then
    warn "找不到自检脚本：$SELF_CHECK_SCRIPT"
    return 1
  fi

  node "$SELF_CHECK_SCRIPT" --config "$INPUT_JSON" --output "$REPORT_JSON"
}

choose_template_manually() {
  echo ""
  echo -e "  ${BOLD}1) lite-safe${NC}        — 第一次装 / 弱模型 / 先存不召回 ${GREEN}← 推荐新手${NC}"
  echo -e "  ${BOLD}2) balanced-default${NC} — 大多数人 / 存+召回 / 不开 rerank"
  echo -e "  ${BOLD}3) pro-rerank${NC}       — GPT-4/Claude / 追求召回质量 / 开 rerank"
  echo ""
  read -p "输入数字 (1/2/3)，直接回车选 1: " TEMPLATE_CHOICE
  TEMPLATE_CHOICE=${TEMPLATE_CHOICE:-1}

  case "$TEMPLATE_CHOICE" in
    1) TEMPLATE="lite-safe" ;;
    2) TEMPLATE="balanced-default" ;;
    3) TEMPLATE="pro-rerank" ;;
    *) fail "无效选择，请输入 1、2 或 3。" ;;
  esac
}

if [[ "$PROFILE_MODE" == "manual" ]]; then
  choose_template_manually
  success "已选模板：$TEMPLATE"
else
  if [[ "$JINA_KEY" == "YOUR_JINA_API_KEY" ]]; then
    warn "没有真实 Jina Key，无法跑能力自检，自动回退到 lite-safe。"
    TEMPLATE="lite-safe"
  else
    SELFCHECK_INPUT="$(mktemp "${TMPDIR:-/tmp}/memory-selfcheck-input-XXXXXX")"
    SELFCHECK_REPORT="$(mktemp "${TMPDIR:-/tmp}/memory-selfcheck-report-XXXXXX")"

    JINA_KEY_ENV="$JINA_KEY" node -e '
      const fs = require("fs");
      const outputPath = process.argv[1];
      const apiKey = process.env.JINA_KEY_ENV;
      const payload = {
        metadata: {
          label: "memory-lancedb-pro beginner installer",
        },
        embedding: {
          apiKey,
          baseURL: "https://api.jina.ai/v1",
          model: "jina-embeddings-v5-text-small",
          dimensions: 1024,
          queryExtraBody: {
            task: "retrieval.query",
            normalized: true,
          },
          passageExtraBody: {
            task: "retrieval.passage",
            normalized: true,
          },
        },
        rerank: {
          apiKey,
          endpoint: "https://api.jina.ai/v1/rerank",
          model: "jina-reranker-v3",
        },
      };
      fs.writeFileSync(outputPath, JSON.stringify(payload, null, 2) + "\n", "utf8");
    ' "$SELFCHECK_INPUT"

    if $DRY_RUN; then
      dry "node $SELF_CHECK_SCRIPT --config $SELFCHECK_INPUT --output $SELFCHECK_REPORT"
      TEMPLATE="balanced-default"
      warn "DRY-RUN 模式不会真实探测，先假定推荐 balanced-default。"
    elif run_selfcheck "$SELFCHECK_INPUT" "$SELFCHECK_REPORT"; then
      TEMPLATE=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).recommendedProfile || 'lite-safe'" "$SELFCHECK_REPORT")
      success "自动推荐模板：$TEMPLATE"
      echo "  自检报告：$SELFCHECK_REPORT"
      if $SELFCHECK_ONLY; then
        success "--selfcheck-only 已完成，不改配置。"
        exit 0
      fi
    else
      if [[ -f "$SELFCHECK_REPORT" ]]; then
        BLOCKING=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).overall?.blocking ? 'true' : 'false'" "$SELFCHECK_REPORT")
        REASON=$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).overall?.reason || '未知错误'" "$SELFCHECK_REPORT")
        if [[ "$BLOCKING" == "true" ]]; then
          fail "能力自检未通过：${REASON}。报告：${SELFCHECK_REPORT}"
        fi
      fi
      warn "能力自检没有拿到稳定结论，保守回退到 lite-safe。"
      TEMPLATE="lite-safe"
      if $SELFCHECK_ONLY; then
        fail "--selfcheck-only 模式下自检失败，请先修复上面的错误。"
      fi
    fi
  fi
fi

if [[ -z "$TEMPLATE" ]]; then
  fail "没有选出有效模板"
fi

success "最终模板：$TEMPLATE"

if $SELFCHECK_ONLY; then
  warn "--selfcheck-only 需要 auto-probe 模式且提供真实 Key。"
  exit 1
fi

# ── 第 6 步：克隆插件 ──
echo ""
info "第 6 步：下载插件..."

if [[ -d "$PLUGIN_DIR" ]]; then
  warn "目录已存在，跳过 clone: $PLUGIN_DIR"
elif $DRY_RUN; then
  dry "git clone https://github.com/CortexReach/memory-lancedb-pro.git $PLUGIN_DIR"
else
  mkdir -p "$WORKSPACE/plugins"
  if ! git clone https://github.com/CortexReach/memory-lancedb-pro.git "$PLUGIN_DIR" 2>&1; then
    warn "GitHub clone 失败，尝试国内镜像..."
    git clone https://ghproxy.com/https://github.com/CortexReach/memory-lancedb-pro.git "$PLUGIN_DIR" \
      || fail "镜像也失败了。请手动下载 zip 解压到 $PLUGIN_DIR 后重新运行脚本。"
  fi
  success "插件下载完成"
fi

# ── 第 7 步：安装依赖 ──
echo ""
info "第 7 步：安装依赖..."

if $DRY_RUN; then
  dry "cd $PLUGIN_DIR && npm install"
elif [[ -d "$PLUGIN_DIR/node_modules" ]]; then
  warn "node_modules 已存在，跳过。"
else
  cd "$PLUGIN_DIR"
  if ! npm install 2>&1; then
    warn "默认源失败，切换国内镜像..."
    npm install --registry https://registry.npmmirror.com 2>&1 \
      || fail "npm install 失败。请手动运行：cd $PLUGIN_DIR && npm install --registry https://registry.npmmirror.com"
  fi
  success "依赖安装完成"
fi

# ── 第 8 步：生成模板配置 JSON ──
info "第 8 步：生成配置..."

gen_config() {
  local KEY="$1"
  local TPL="$2"

  local EMBEDDING='{
    "apiKey": "'"$KEY"'",
    "model": "jina-embeddings-v5-text-small",
    "baseURL": "https://api.jina.ai/v1",
    "dimensions": 1024,
    "taskQuery": "retrieval.query",
    "taskPassage": "retrieval.passage",
    "normalized": true
  }'

  case "$TPL" in
    lite-safe)
      echo '{
  "embedding": '"$EMBEDDING"',
  "autoCapture": true,
  "autoRecall": false,
  "retrieval": {
    "mode": "hybrid",
    "candidatePoolSize": 20,
    "minScore": 0.45,
    "hardMinScore": 0.55,
    "rerank": "none",
    "filterNoise": true
  },
  "sessionStrategy": "systemSessionMemory",
  "mdMirror": { "enabled": true, "dir": "memory-md" }
}'
      ;;
    balanced-default)
      echo '{
  "embedding": '"$EMBEDDING"',
  "autoCapture": true,
  "autoRecall": true,
  "autoRecallMinLength": 8,
  "autoRecallTopK": 3,
  "autoRecallExcludeReflection": true,
  "autoRecallMaxAgeDays": 30,
  "autoRecallMaxEntriesPerKey": 10,
  "retrieval": {
    "mode": "hybrid",
    "candidatePoolSize": 20,
    "minScore": 0.45,
    "hardMinScore": 0.55,
    "rerank": "none",
    "filterNoise": true
  },
  "sessionStrategy": "systemSessionMemory"
}'
      ;;
    pro-rerank)
      echo '{
  "embedding": '"$EMBEDDING"',
  "autoCapture": true,
  "autoRecall": true,
  "autoRecallMinLength": 8,
  "autoRecallTopK": 3,
  "autoRecallExcludeReflection": true,
  "autoRecallMaxAgeDays": 30,
  "autoRecallMaxEntriesPerKey": 10,
  "retrieval": {
    "mode": "hybrid",
    "candidatePoolSize": 20,
    "minScore": 0.45,
    "hardMinScore": 0.35,
    "rerank": "cross-encoder",
    "rerankApiKey": "'"$KEY"'",
    "rerankModel": "jina-reranker-v3",
    "rerankEndpoint": "https://api.jina.ai/v1/rerank",
    "rerankProvider": "jina",
    "recencyHalfLifeDays": 14,
    "recencyWeight": 0.1,
    "filterNoise": true
  },
  "sessionStrategy": "systemSessionMemory"
}'
      ;;
  esac
}

CONFIG_JSON=$(gen_config "$JINA_KEY" "$TEMPLATE")
success "配置已生成（模板：${TEMPLATE}）"

# ── 第 9 步：写入 openclaw.json（核心安全步骤） ──
echo ""
info "第 9 步：写入 openclaw.json..."

# 构造要合并的 JSON 片段
MERGE_JSON=$(cat <<MERGEOF
{
  "plugins": {
    "load": {
      "paths": ["$PLUGIN_DIR"]
    },
    "entries": {
      "memory-lancedb-pro": {
        "enabled": true,
        "config": $CONFIG_JSON
      }
    },
    "slots": {
      "memory": "memory-lancedb-pro"
    }
  }
}
MERGEOF
)

if $DRY_RUN; then
  dry "将以下配置合并到 $OPENCLAW_JSON:"
  echo "$MERGE_JSON" | head -20
  echo "  ..."
elif ! $HAS_JQ; then
  # ── 降级模式：没有 jq，打印让用户手动贴 ──
  echo ""
  echo "======================================================"
  echo "  没有 jq，无法自动合并配置。"
  echo "  请手动把以下内容加入 ${OPENCLAW_JSON}："
  echo "======================================================"
  echo ""
  echo "$MERGE_JSON"
  echo ""
  echo "------------------------------------------------------"
  echo "  如果已有 plugins 字段，请合并内容，不要覆盖。"
  echo "  提示：安装 jq 后重新运行脚本可实现全自动。"
  echo "    Mac:   brew install jq"
  echo "    Linux: sudo apt install jq"
  echo "------------------------------------------------------"
  echo ""
  read -p "编辑完成后，按回车继续验证... "
else
  # ── 全自动模式：用 jq 安全合并 ──

  # 8a. 检查 openclaw.json 是否存在
  if [[ ! -f "$OPENCLAW_JSON" ]]; then
    warn "openclaw.json 不存在，将创建新文件。"
    echo '{}' > "$OPENCLAW_JSON"
  fi

  # 8b. 验证 JSON 格式
  if ! jq empty "$OPENCLAW_JSON" 2>/dev/null; then
    fail "openclaw.json 格式错误（不是合法 JSON），请先手动修复。"
  fi

  # 8c. 检查是否已有其他 memory 插件
  EXISTING_MEMORY=$(jq -r '.plugins.slots.memory // empty' "$OPENCLAW_JSON" 2>/dev/null || echo "")
  if [[ -n "$EXISTING_MEMORY" && "$EXISTING_MEMORY" != "memory-lancedb-pro" ]]; then
    echo ""
    warn "检测到已有 memory 插件：$EXISTING_MEMORY"
    echo ""
    echo "  如果继续，memory slot 会被替换为 memory-lancedb-pro。"
    echo "  原来的插件配置会保留，只是不再作为默认 memory 插件。"
    echo ""
    read -p "  要替换吗？(y/n) [n]: " REPLACE
    if [[ "${REPLACE:-n}" != "y" && "${REPLACE:-n}" != "Y" ]]; then
      echo ""
      echo "  已取消。你可以手动编辑 $OPENCLAW_JSON 来配置。"
      echo "  配置内容如下，可手动参考："
      echo ""
      echo "$MERGE_JSON"
      echo ""
      exit 0
    fi
  fi

  # 8d. 备份当前配置
  BACKUP_FILE="$OPENCLAW_JSON.backup.$(date +%Y%m%d_%H%M%S)"
  cp "$OPENCLAW_JSON" "$BACKUP_FILE"
  success "已备份当前配置 → $BACKUP_FILE"

  # 8e. 用 jq 深度合并
  #   - plugins.load.paths：追加新路径（不重复）
  #   - plugins.entries：追加新插件配置
  #   - plugins.slots.memory：设为 memory-lancedb-pro
  #   - 其他所有字段：保持不变
  MERGED=$(jq --argjson new "$MERGE_JSON" '
    # 确保 plugins 结构存在
    .plugins //= {} |
    .plugins.load //= {} |
    .plugins.load.paths //= [] |
    .plugins.entries //= {} |
    .plugins.slots //= {} |

    # 追加 load path（去重）
    .plugins.load.paths = (.plugins.load.paths + $new.plugins.load.paths | unique) |

    # 写入 entries（只覆盖 memory-lancedb-pro，不动其他插件）
    .plugins.entries["memory-lancedb-pro"] = $new.plugins.entries["memory-lancedb-pro"] |

    # 设置 memory slot
    .plugins.slots.memory = $new.plugins.slots.memory
  ' "$OPENCLAW_JSON")

  # 8f. 写回文件前最后验证
  if echo "$MERGED" | jq empty 2>/dev/null; then
    echo "$MERGED" > "$OPENCLAW_JSON"
    success "openclaw.json 已更新（原文件已备份）"
  else
    fail "合并后 JSON 格式异常，已中止。原文件未改动。备份在：$BACKUP_FILE"
  fi
fi

# ── 第 10 步：重启 Gateway ──
echo ""
info "第 10 步：重启 Gateway..."

if $DRY_RUN; then
  dry "openclaw gateway restart"
else
  if openclaw gateway restart 2>&1; then
    success "Gateway 重启完成"
  else
    warn "重启可能失败，请手动运行：openclaw gateway restart"
  fi
fi

# ── 第 11 步：验证 ──
echo ""
info "第 11 步：验证..."

if $DRY_RUN; then
  dry "openclaw plugins info memory-lancedb-pro"
  dry "openclaw config get plugins.slots.memory"
  dry "openclaw memory-pro stats"
  echo ""
  success "DRY-RUN 完成。确认无误后去掉 --dry-run 参数正式运行。"
  exit 0
fi

PASS=0
TOTAL=3

echo ""
echo "--- 检查 1/3：插件是否加载 ---"
if openclaw plugins info memory-lancedb-pro 2>&1; then
  success "插件已加载"
  PASS=$((PASS + 1))
else
  warn "插件加载可能有问题"
fi

echo ""
echo "--- 检查 2/3：memory slot ---"
SLOT=$(openclaw config get plugins.slots.memory 2>/dev/null || echo "")
if [[ "$SLOT" == *"memory-lancedb-pro"* ]]; then
  success "memory slot → memory-lancedb-pro"
  PASS=$((PASS + 1))
else
  warn "memory slot 未正确配置，当前值：$SLOT"
fi

echo ""
echo "--- 检查 3/3：记忆库状态 ---"
if openclaw memory-pro stats 2>&1; then
  success "记忆库正常"
  PASS=$((PASS + 1))
else
  warn "记忆库状态检查失败"
fi

# ── 结果汇报 ──
echo ""
echo "======================================================"
if [[ "$PASS" -eq "$TOTAL" ]]; then
  echo -e "${GREEN}${BOLD}  全部通过（${PASS}/${TOTAL}）！安装完成！${NC}"
  echo ""
  echo "  现在试试对你的 Agent 说："
  echo ""
  echo "    「记住：我喜欢冷萃咖啡，不喜欢太甜。」"
  echo ""
  if [[ "$TEMPLATE" == "lite-safe" ]]; then
    echo "  然后打开 $WORKSPACE/memory-md/ 目录，"
    echo "  看看有没有 .md 文件生成 — 有就说明记忆已存入。"
    echo ""
    echo "  （lite-safe 模式先存不召回，跑稳了再升级到 balanced-default）"
  else
    echo "  然后在新对话里问：「我平时喝什么咖啡？」"
    echo "  Agent 能回答就说明记忆召回正常。"
  fi
else
  echo -e "${YELLOW}${BOLD}  $PASS/$TOTAL 通过${NC}"
  echo ""
  echo "  请检查上方未通过的项目。"
  echo "  常见问题解答：docs/complete-guide-cn.md 第七章"
  echo ""
  if [[ -n "${BACKUP_FILE:-}" ]]; then
    echo "  如需还原配置：cp $BACKUP_FILE $OPENCLAW_JSON"
  fi
fi
echo "======================================================"
echo ""

# ── 第 12 步：功能知情 + 可选升级 ──
# 只在全部通过时展示，避免安装失败时干扰排障
if [[ "$PASS" -eq "$TOTAL" ]] && ! $DRY_RUN; then
  echo ""
  info "第 12 步：功能知情（你的记忆系统长什么样）"
  echo ""
  echo -e "  ${BOLD}当前模板：${TEMPLATE}${NC}"
  echo ""

  # 根据模板展示当前状态（纯文本列表，避免 box-drawing 在不同终端错位）
  show_feature() {
    local status="$1" name="$2" desc="$3"
    if [[ "$status" == "on" ]]; then
      echo -e "    ${GREEN}[ON]${NC}  $name — $desc"
    else
      echo -e "    ${YELLOW}[OFF]${NC} $name — $desc"
    fi
  }

  case "$TEMPLATE" in
    lite-safe)
      show_feature on  "autoCapture" "自动存储 / Auto store conversation info"
      show_feature off "autoRecall"  "自动召回关闭 / Won't search old memories in new chats"
      show_feature off "Reflection"  "智能提炼关闭 / No AI summarization per turn"
      show_feature off "rerank"      "精排关闭 / No second-pass ranking on search"
      show_feature on  "mdMirror"    "可读备份 / Memories also saved as .md files"
      echo ""
      echo "  lite-safe = 先存不召回，跑稳了再升级"
      echo "              Store first, recall later — upgrade when stable"
      ;;
    balanced-default)
      show_feature on  "autoCapture" "自动存储 / Auto store conversation info"
      show_feature on  "autoRecall"  "自动召回 / Auto search relevant old memories"
      show_feature off "Reflection"  "智能提炼关闭 / No AI summarization per turn"
      show_feature off "rerank"      "精排关闭 / No second-pass ranking on search"
      show_feature off "mdMirror"    "可读备份关闭 / Memories only in vector DB"
      echo ""
      echo "  balanced = 存+召回，够用且省 token"
      echo "             Store + recall, good enough and token-efficient"
      ;;
    pro-rerank)
      show_feature on  "autoCapture" "自动存储 / Auto store conversation info"
      show_feature on  "autoRecall"  "自动召回 / Auto search relevant old memories"
      show_feature off "Reflection"  "智能提炼关闭 / No AI summarization per turn"
      show_feature on  "rerank"      "Jina Reranker 精排 / Second-pass reranking enabled"
      show_feature off "mdMirror"    "可读备份关闭 / Memories only in vector DB"
      echo ""
      echo "  pro = 存+召回+精排，检索质量最高"
      echo "        Store + recall + rerank, best search quality"
      ;;
  esac

  echo ""
  echo -e "  ${BOLD}关于「智能提炼 memoryReflection」/ About Smart Extraction:${NC}"
  echo "    开启后，Agent 每轮对话额外调用一次 AI 提炼要点，记忆更精练、召回更准。"
  echo "    When enabled, the Agent makes one extra AI call per turn to distill key points,"
  echo "    resulting in more concise memories and better recall accuracy."
  echo -e "    ${YELLOW}代价 / Cost: ~500-1000 extra tokens per turn.${NC}"
  echo "    当前 / Current: systemSessionMemory = 原样存储，不做提炼 / raw storage, no distillation."
  echo ""

  # 根据模板提供不同的升级选项
  UPGRADE_CHOICES=""
  case "$TEMPLATE" in
    lite-safe)
      echo -e "  ${BOLD}可选升级 / Optional upgrades（多个用空格分隔，回车跳过 / space-separated, Enter to skip）：${NC}"
      echo ""
      echo "    1) 开启自动召回 autoRecall  — Enable auto recall in new chats"
      echo "    2) 开启智能提炼 Reflection  — Enable AI smart extraction (costs extra tokens)"
      echo ""
      read -p "  输入编号 / Enter number (1 2), 回车跳过 / Enter to skip: " UPGRADE_CHOICES
      ;;
    balanced-default)
      echo -e "  ${BOLD}可选升级 / Optional upgrades（回车跳过 / Enter to skip）：${NC}"
      echo ""
      echo "    2) 开启智能提炼 Reflection  — Enable AI smart extraction (costs extra tokens)"
      echo ""
      read -p "  输入编号 / Enter number (2), 回车跳过 / Enter to skip: " UPGRADE_CHOICES
      ;;
    pro-rerank)
      echo -e "  ${BOLD}可选升级 / Optional upgrades（回车跳过 / Enter to skip）：${NC}"
      echo ""
      echo "    2) 开启智能提炼 Reflection  — Enable AI smart extraction (costs extra tokens)"
      echo ""
      read -p "  输入编号 / Enter number (2), 回车跳过 / Enter to skip: " UPGRADE_CHOICES
      ;;
  esac

  # 预处理用户输入：中英文逗号→空格，粘连数字拆开（"12"→"1 2"）
  UPGRADE_CHOICES=$(echo "$UPGRADE_CHOICES" | tr '，,' ' ' | sed 's/\([0-9]\)/\1 /g' | tr -s ' ' | sed 's/^ *//;s/ *$//')

  if [[ -n "$UPGRADE_CHOICES" ]]; then
    NEED_RESTART=false
    MANUAL_EDITS=false

    # 构建当前模板的合法选项集 + 已开启功能集
    VALID_OPTS="2"  # 所有模板都可选 2
    ALREADY_ON=""
    if [[ "$TEMPLATE" == "lite-safe" ]]; then
      VALID_OPTS="1 2"
    else
      ALREADY_ON="1"  # balanced/pro 的 autoRecall 已经开了
    fi

    # jq 安全写入：写 .tmp → 验证 → 替换原文件，失败时清理 .tmp
    jq_safe_write() {
      local filter="$1"
      jq "$filter" "$OPENCLAW_JSON" > "${OPENCLAW_JSON}.tmp" || { rm -f "${OPENCLAW_JSON}.tmp"; return 1; }
      if jq empty "${OPENCLAW_JSON}.tmp" 2>/dev/null; then
        mv "${OPENCLAW_JSON}.tmp" "$OPENCLAW_JSON" || { rm -f "${OPENCLAW_JSON}.tmp"; warn "写入失败，检查文件权限 / Write failed, check permissions: $OPENCLAW_JSON"; return 1; }
      else
        rm -f "${OPENCLAW_JSON}.tmp"
        warn "jq 输出格式异常，已中止 / jq output invalid, aborted"
        return 1
      fi
    }

    for choice in $UPGRADE_CHOICES; do
      # 过滤非数字输入（yes/y/abc 等）
      if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        warn "请输入数字编号（如 1 2）/ Please enter numbers (e.g. 1 2), got: $choice"
        continue
      fi

      # 已经开了的功能，友好提示而非报错
      if echo " $ALREADY_ON " | grep -q " $choice "; then
        case "$choice" in
          1) info "autoRecall 在 $TEMPLATE 模板里已经是开启状态 / autoRecall is already ON in $TEMPLATE." ;;
        esac
        continue
      fi

      # 当前模板不支持的选项
      if ! echo " $VALID_OPTS " | grep -q " $choice "; then
        warn "选项 $choice 不在可选范围内 / Option $choice is not available, skipped."
        continue
      fi

      case "$choice" in
        1)
          if $HAS_JQ; then
            if jq_safe_write '
                .plugins.entries["memory-lancedb-pro"].config.autoRecall = true |
                .plugins.entries["memory-lancedb-pro"].config.autoRecallMinLength = (.plugins.entries["memory-lancedb-pro"].config.autoRecallMinLength // 8) |
                .plugins.entries["memory-lancedb-pro"].config.autoRecallTopK = (.plugins.entries["memory-lancedb-pro"].config.autoRecallTopK // 3) |
                .plugins.entries["memory-lancedb-pro"].config.autoRecallMaxAgeDays = (.plugins.entries["memory-lancedb-pro"].config.autoRecallMaxAgeDays // 30)'; then
              success "autoRecall enabled / 已开启自动召回"
              NEED_RESTART=true
            else
              warn "autoRecall 写入失败 / Failed to enable autoRecall"
            fi
          else
            warn "没有 jq，需要手动修改 / No jq, manual edit needed:"
            echo "    nano $OPENCLAW_JSON"
            echo '    "autoRecall": false  →  "autoRecall": true'
            echo '    add: "autoRecallMinLength": 8, "autoRecallTopK": 3'
            echo "    改完后运行 / After editing: openclaw gateway restart"
            MANUAL_EDITS=true
          fi
          ;;
        2)
          if $HAS_JQ; then
            if jq_safe_write '.plugins.entries["memory-lancedb-pro"].config.sessionStrategy = "memoryReflection"'; then
              success "memoryReflection enabled / 已开启智能提炼"
              echo "    每轮对话多一次 AI 调用 / Extra AI call per turn for distillation."
              echo ""
              echo "    改回来 / To revert:"
              echo "      nano $OPENCLAW_JSON"
              echo "      \"memoryReflection\" → \"systemSessionMemory\""
              echo "      然后运行 / then run: openclaw gateway restart"
              NEED_RESTART=true
            else
              warn "memoryReflection 写入失败 / Failed to enable memoryReflection"
            fi
          else
            warn "没有 jq，需要手动修改 / No jq, manual edit needed:"
            echo "    nano $OPENCLAW_JSON"
            echo '    "sessionStrategy": "systemSessionMemory"  →  "memoryReflection"'
            echo "    改完后运行 / After editing: openclaw gateway restart"
            MANUAL_EDITS=true
          fi
          ;;
        *)
          warn "无效选项 / Invalid option: $choice, skipped."
          ;;
      esac
    done

    if $NEED_RESTART; then
      echo ""
      info "配置已更新，重启 Gateway / Config updated, restarting Gateway..."
      if openclaw gateway restart 2>&1; then
        success "Gateway 重启完成 / Gateway restarted, new config active."
      else
        warn "重启可能失败 / Restart may have failed. Try: openclaw gateway restart"
      fi
    elif $MANUAL_EDITS; then
      echo ""
      warn "以上功能需要手动修改配置文件才能生效 / Manual edits needed — see instructions above."
      echo "    安装 jq 后重跑脚本可自动完成 / Install jq and re-run for auto setup:"
      echo "    Mac: brew install jq  |  Linux: sudo apt install jq"
    fi
  else
    echo ""
    success "保持当前配置 / Keeping current config, no changes made."
    echo "    之后想升级 / To upgrade later:"
    echo "    - 重跑 / Re-run: bash setup-memory.sh"
  fi
fi
