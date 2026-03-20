#!/usr/bin/env bash
# ============================================================
#  memory-lancedb-pro 一键安装 / 升级脚本 v3.6
#
#  用法：
#    bash setup-memory.sh            # 安装（已安装则进入升级模式）
#    bash setup-memory.sh --beta     # 允许升级到 beta 版本
#    bash setup-memory.sh --dry-run  # 只展示会做什么，不实际执行
#    bash setup-memory.sh --selfcheck-only  # 只跑能力自检，不改配置
#    bash setup-memory.sh --uninstall # 还原配置并移除插件
#    bash setup-memory.sh --ref v1.2.0  # 锁定到指定 tag/branch/commit
#
#  v3.6 变化（合并 PR #3 by robinspt + 安全加固）：
#    - 单文件运行时自动下载缺失的 helper scripts（probe/selfcheck/validate）
#    - uninstall 改为精确删除配置字段，不再依赖备份恢复
#    - probe_result_is_valid() 校验文件非空 + JSON 合法
#    - provider 补齐默认 embedding 模型（Jina/DashScope/SiliconFlow/OpenAI/Ollama）
#    - rerank 兜底：预设 provider 有配置时即使 probe 未验证也允许写入
#    - Node.js >= 18 版本校验、probe stderr 不再吞掉
#    - gen_config_from_probe 全面改用环境变量（对齐 v3.4 安全修复）
#
#  v3.5 变化：
#    - 修复 Ollama 等 probe 失败时 config 丢失 embedding 字段的 bug（#2）
#    - probe 失败后立即用已收集变量生成兜底探测结果，不再留空文件给下游
#    - -f 改 -s 检测探测结果文件非空，双重保险
#    - gen_config_from_probe 里 node -e 改用环境变量（对齐 v3.4 安全修复）
#
#  v3.4 变化：
#    - 新增 plugins.allow 白名单（修复 git-clone 插件 "plugin not found"）
#    - 修复 eval 命令注入（tilde 展开改用纯参数替换）
#    - 修复 node -e 路径注入（改用环境变量传入）
#    - 修复 rerank API key 含特殊字符时 jq 注入（改用 --arg）
#    - DashScope embedding 用户自动检测 rerank 端点（qwen3-rerank）
#    - 分支检测优化：fetch --prune 清理残留远程分支，fallback 硬编码 master
#
#  v3.3 变化：
#    - 可选功能写入后、Gateway 重启前再跑一次 schema 过滤（修复 additional properties 崩溃）
#    - Ollama/本地模型用户选 rerank 时提示需要在线 API Key
#
#  v3.2 变化：
#    - 已有 git clone 的插件目录自动 fetch + checkout 到目标 ref
#    - npm 安装的用户不受影响（npm update 是用户自己管的）
#
#  v3.1 变化：
#    - --ref 参数：锁定 clone 版本（tag/branch/commit），默认 master
#    - Schema 动态过滤：写入配置前按插件 configSchema 自动裁剪非法字段
#    - 写入前双重校验：过滤前后各验一次 JSON 合法性
#
#  v3.0 变化：
#    - 通用端口探测：支持任意 OpenAI 兼容 API
#    - 快捷入口：Jina / DashScope / SiliconFlow / OpenAI / Ollama
#    - config validate：安装/升级后自动校验配置字段
#    - gen_config 从硬编码模板改为动态生成
#
#  安全机制：
#    - 改 openclaw.json 前自动备份
#    - 用 jq 做深度合并，已有配置不覆盖
#    - 检测到已有 memory 插件时停下来问用户
#    - 没有 jq 则降级为手动模式
#    - 升级失败自动回滚到旧版本
#
#  文档：https://github.com/CortexReach/toolbox/tree/main/memory-lancedb-pro-setup
# ============================================================

set -euo pipefail

# ── 临时文件清理（含 API Key，必须清理） ──
_TMPFILES=()
cleanup_tmp() { for f in "${_TMPFILES[@]+"${_TMPFILES[@]}"}"; do rm -f "$f" 2>/dev/null; done; }
trap cleanup_tmp EXIT

# ── 参数解析 ──
DRY_RUN=false
UNINSTALL=false
SELFCHECK_ONLY=false
INCLUDE_BETA=false
PLUGIN_REF=""  # 空表示"跟随远程默认分支"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true ;;
    --uninstall) UNINSTALL=true ;;
    --selfcheck-only) SELFCHECK_ONLY=true ;;
    --beta)      INCLUDE_BETA=true ;;
    --ref)
      shift
      if [[ $# -le 0 ]]; then
        echo "[ERR]  --ref 需要一个参数 / --ref requires a tag/branch/commit argument" >&2
        exit 1
      fi
      PLUGIN_REF="$1"
      ;;
    --ref=*) PLUGIN_REF="${1#*=}" ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_CHECK_SCRIPT="$SCRIPT_DIR/scripts/memory-selfcheck.mjs"
PROBE_SCRIPT="$SCRIPT_DIR/scripts/probe-endpoint.mjs"
VALIDATE_SCRIPT="$SCRIPT_DIR/scripts/config-validate.mjs"
GITHUB_REPO="CortexReach/memory-lancedb-pro"
GITHUB_URL="https://github.com/$GITHUB_REPO.git"

# ── 颜色输出 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
dry()     { echo -e "${YELLOW}[DRY-RUN]${NC} 将会执行 / Would run: $1"; }

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  memory-lancedb-pro 安装/升级向导 / Setup Wizard v3.6${NC}"
echo -e "${BOLD}========================================${NC}"
if $DRY_RUN; then
  echo -e "${YELLOW}  ⚡ DRY-RUN 模式：只展示操作，不实际执行 / Show actions only, no changes${NC}"
fi
if $INCLUDE_BETA; then
  echo -e "${CYAN}  🧪 BETA 模式：包含预发布版本 / Including pre-release versions${NC}"
fi
echo ""

# ============================================================
#  公共函数
# ============================================================

# semver 比较：$1 < $2 返回 0（需要更新），否则返回 1
needs_update() {
  node -e "
    const parse = v => {
      const [core, pre] = v.split('-');
      const nums = core.split('.').map(Number);
      return { nums, pre: pre || '' };
    };
    const l = parse('$1'), r = parse('$2');
    for (let i = 0; i < 3; i++) {
      if ((l.nums[i]||0) < (r.nums[i]||0)) process.exit(0);
      if ((l.nums[i]||0) > (r.nums[i]||0)) process.exit(1);
    }
    if (l.pre && !r.pre) process.exit(0);
    if (!l.pre && r.pre) process.exit(1);
    const lNum = parseInt((l.pre.match(/\d+$/) || ['0'])[0]);
    const rNum = parseInt((r.pre.match(/\d+$/) || ['0'])[0]);
    process.exit(lNum < rNum ? 0 : 1);
  " 2>/dev/null
}

# 获取远程最新版本号
get_remote_version() {
  local ver=""

  # 统一用 tags API 获取最新版本（releases/latest 可能滞后于 master HEAD）
  local include_pre="$INCLUDE_BETA"
  ver=$(INCLUDE_PRE="$include_pre" node -e "
    const includePre = process.env.INCLUDE_PRE === 'true';
    fetch('https://api.github.com/repos/$GITHUB_REPO/tags?per_page=30')
      .then(r => r.json())
      .then(tags => {
        if (!Array.isArray(tags) || tags.length === 0) { console.log(''); return; }
        const parsed = tags.map(t => {
          const v = (t.name || '').replace(/^v/, '');
          const [core, pre] = v.split('-');
          const nums = (core || '').split('.').map(Number);
          const preNum = pre ? parseInt((pre.match(/\d+\$/) || ['0'])[0]) : Infinity;
          return { v, nums, preNum, hasPre: !!pre };
        });
        // 不含 beta 时优先找正式版，全是 beta 则退而取最新 beta
        let candidates = includePre ? parsed : parsed.filter(p => !p.hasPre);
        if (candidates.length === 0) candidates = parsed;
        candidates.sort((a, b) => {
          for (let i = 0; i < 3; i++) {
            if ((a.nums[i]||0) !== (b.nums[i]||0)) return (b.nums[i]||0) - (a.nums[i]||0);
          }
          if (!a.hasPre && b.hasPre) return -1;
          if (a.hasPre && !b.hasPre) return 1;
          return b.preNum - a.preNum;
        });
        console.log(candidates[0]?.v || '');
      })
      .catch(() => console.log(''));
  " 2>/dev/null)

  # fallback：git ls-remote
  if [[ -z "$ver" ]]; then
    if $INCLUDE_BETA; then
      ver=$(git ls-remote --tags "$GITHUB_URL" 2>/dev/null \
        | awk '{print $2}' | sed 's|refs/tags/||;s|\^{}||' | sed 's/^v//' \
        | sort -V | tail -1)
    else
      ver=$(git ls-remote --tags "$GITHUB_URL" 2>/dev/null \
        | awk '{print $2}' | sed 's|refs/tags/||;s|\^{}||' | sed 's/^v//' \
        | grep -v '-' | sort -V | tail -1)
    fi
  fi

  echo "$ver"
}

# 展示 changelog
show_changelog() {
  local local_ver="$1"
  local include_beta="$2"

  echo ""
  echo -e "  ${BOLD}更新日志 / Changelog:${NC}"
  echo ""

  node -e "
    const localVer = '$local_ver';
    const includeBeta = $include_beta;

    function isNewer(a, b) {
      const pa = (a.split('-')[0] || '').split('.').map(Number);
      const pb = (b.split('-')[0] || '').split('.').map(Number);
      for (let i = 0; i < 3; i++) {
        if ((pa[i]||0) > (pb[i]||0)) return true;
        if ((pa[i]||0) < (pb[i]||0)) return false;
      }
      const preA = a.includes('-') ? a.split('-').slice(1).join('-') : '';
      const preB = b.includes('-') ? b.split('-').slice(1).join('-') : '';
      if (!preA && preB) return true;
      if (preA && !preB) return false;
      const numA = parseInt((preA.match(/\d+$/) || ['0'])[0]);
      const numB = parseInt((preB.match(/\d+$/) || ['0'])[0]);
      return numA > numB;
    }

    fetch('https://api.github.com/repos/$GITHUB_REPO/releases?per_page=30')
      .then(r => r.json())
      .then(releases => {
        if (!Array.isArray(releases)) { console.log('    （无法获取 changelog）'); return; }
        const newer = releases.filter(r => {
          const ver = (r.tag_name || '').replace(/^v/, '');
          // 不含 beta 时，同时检查 prerelease 标记和 tag 名含 '-'（防止未勾 pre-release）
          if (!includeBeta && (r.prerelease || ver.includes('-'))) return false;
          return isNewer(ver, localVer);
        });
        if (newer.length === 0) { console.log('    （无 release notes）'); return; }
        const show = newer.slice(0, 8);
        show.forEach(r => {
          const ver = (r.tag_name || '').padEnd(22);
          const name = (r.name || '(no title)').substring(0, 55);
          const pre = r.prerelease ? ' [beta]' : '';
          console.log('    ' + ver + name + pre);
        });
        if (newer.length > 8) console.log('    ...还有 ' + (newer.length - 8) + ' 个版本');
      })
      .catch(() => console.log('    （无法获取 changelog）'));
  " 2>/dev/null
  echo ""
}

# Schema 动态过滤：按插件 configSchema 递归裁剪不合法字段
filter_config_by_schema() {
  local CONFIG_JSON_INPUT="$1"
  local MANIFEST_PATH="$2"

  [[ -f "$MANIFEST_PATH" ]] || { warn "找不到插件 manifest / Plugin manifest not found: $MANIFEST_PATH"; return 1; }

  CONFIG_JSON_ENV="$CONFIG_JSON_INPUT" MANIFEST_PATH_ENV="$MANIFEST_PATH" node - <<'NODE'
const fs = require('fs');
const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST_PATH_ENV, 'utf8'));
const config = JSON.parse(process.env.CONFIG_JSON_ENV);
const removed = [];

function walk(obj, schema, path) {
  if (!schema || typeof schema !== 'object') return obj;
  if (obj === null || obj === undefined) return obj;
  if (Array.isArray(obj)) return obj;
  if (typeof obj !== 'object') return obj;

  const props = schema.properties || {};
  const allowAdditional = schema.additionalProperties !== false;
  const out = {};

  for (const [key, value] of Object.entries(obj)) {
    if (Object.prototype.hasOwnProperty.call(props, key)) {
      out[key] = walk(value, props[key], path ? `${path}.${key}` : key);
    } else if (allowAdditional) {
      out[key] = value;
    } else {
      removed.push(path ? `${path}.${key}` : key);
    }
  }
  return out;
}

const filtered = walk(config, manifest.configSchema || {}, 'config');
process.stdout.write(JSON.stringify({ filtered, removed }, null, 2));
NODE
}

# 升级插件（备份 swap + 回滚）
upgrade_plugin() {
  local install_dir="$1"
  local old_ver="$2"
  local backup_dir="${install_dir}.backup.$(date +%Y%m%d_%H%M%S)"
  local tmp_dir
  tmp_dir=$(mktemp -d)

  info "开始升级 / Starting upgrade..."

  info "正在下载新版本，请稍候 / Downloading new version..."
  if ! git clone --depth 1 --quiet "$GITHUB_URL" "$tmp_dir/plugin" 2>&1; then
    warn "GitHub clone 失败，尝试镜像 / GitHub failed, trying mirror..."
    if ! git clone --depth 1 --quiet "https://ghproxy.com/$GITHUB_URL" "$tmp_dir/plugin" 2>&1; then
      rm -rf "$tmp_dir"
      warn "下载失败，保持当前版本 / Download failed, keeping v$old_ver"
      return 1
    fi
  fi

  if ! (cd "$tmp_dir/plugin" && npm install --loglevel=warn 2>&1); then
    warn "npm install 失败，尝试镜像 / npm install failed, trying mirror..."
    if ! (cd "$tmp_dir/plugin" && npm install --loglevel=warn --registry https://registry.npmmirror.com 2>&1); then
      rm -rf "$tmp_dir"
      warn "依赖安装失败，保持当前版本 / Deps install failed, keeping v$old_ver"
      return 1
    fi
  fi

  local new_ver
  new_ver=$(P_DIR="$tmp_dir/plugin" node -e "console.log(require(process.env.P_DIR+'/package.json').version)" 2>/dev/null || echo "")
  if [[ -z "$new_ver" ]]; then
    rm -rf "$tmp_dir"
    warn "新版本健康检查失败，保持当前版本 $old_ver / Health check failed, keeping v$old_ver"
    return 1
  fi

  mv "$install_dir" "$backup_dir"
  success "旧版本已备份 / Old version backed up → $backup_dir"

  mv "$tmp_dir/plugin" "$install_dir"
  rm -rf "$tmp_dir"

  if P_DIR="$install_dir" node -e "require(process.env.P_DIR+'/package.json')" 2>/dev/null; then
    success "升级完成 / Upgrade complete: $old_ver → $new_ver"
    if [[ -d "$HOME/.Trash" ]]; then
      mv "$backup_dir" "$HOME/.Trash/" 2>/dev/null || true
    fi
    return 0
  else
    warn "升级后验证失败，正在回滚 / Post-upgrade check failed, rolling back..."
    rm -rf "$install_dir"
    mv "$backup_dir" "$install_dir"
    warn "已回滚到 $old_ver / Rolled back to v$old_ver"
    return 1
  fi
}

# jq 安全写入（支持 --arg 等额外 jq 参数）
# 用法：jq_safe_write [--arg name val ...] "filter" "target_file"
jq_safe_write() {
  local args=()
  while [[ "$1" == --* ]]; do args+=("$1" "$2" "$3"); shift 3; done
  local filter="$1"
  local target="$2"
  jq "${args[@]+"${args[@]}"}" "$filter" "$target" > "${target}.tmp" || { rm -f "${target}.tmp"; return 1; }
  if jq empty "${target}.tmp" 2>/dev/null; then
    mv "${target}.tmp" "$target" || { rm -f "${target}.tmp"; warn "写入失败 / Write failed: $target"; return 1; }
  else
    rm -f "${target}.tmp"
    warn "jq 输出格式异常，已中止 / jq output invalid, aborted"
    return 1
  fi
}

# 展示单个功能状态
show_feature() {
  local status="$1" name="$2" desc="$3" extra="${4:-}"
  if [[ "$status" == "on" ]]; then
    if [[ -n "$extra" ]]; then
      echo -e "    ${GREEN}[ON]${NC}  $name — $desc ($extra)"
    else
      echo -e "    ${GREEN}[ON]${NC}  $name — $desc"
    fi
  else
    if [[ -n "$extra" ]]; then
      echo -e "    ${YELLOW}[OFF]${NC} $name — $desc $extra"
    else
      echo -e "    ${YELLOW}[OFF]${NC} $name — $desc"
    fi
  fi
}

# 探测插件实际安装路径（兼容 extensions/ / plugins/ / 任意自定义路径）
# 优先级：openclaw.json load.paths → workspace 下搜索 → 默认 plugins/
detect_plugin_dir() {
  local ws="$1"
  local oc_json="${2:-$HOME/.openclaw/openclaw.json}"

  # 1. 从 openclaw.json 的 plugins.load.paths 里找已注册路径
  if command -v jq &>/dev/null && [[ -f "$oc_json" ]]; then
    local registered
    registered=$(jq -r '.plugins.load.paths[]? // empty' "$oc_json" 2>/dev/null \
      | while IFS= read -r p; do
          # 展开 ~ 开头的路径（不用 eval，避免命令注入 / tilde-expand only, no eval to avoid injection）
          p="${p/#\~/$HOME}"
          if [[ -f "$p/package.json" ]] && grep -q '"memory-lancedb-pro"' "$p/package.json" 2>/dev/null; then
            echo "$p"
            break
          fi
        done)
    if [[ -n "$registered" ]]; then
      echo "$registered"
      return 0
    fi
  fi

  # 2. 在 workspace 下搜索（兼容 extensions/ / plugins/ / 其他子目录）
  if [[ -n "$ws" && -d "$ws" ]]; then
    local found
    found=$(find "$ws" -maxdepth 3 -name package.json -path "*/memory-lancedb-pro/*" -print -quit 2>/dev/null)
    if [[ -n "$found" ]]; then
      echo "$(dirname "$found")"
      return 0
    fi
  fi

  # 3. 没找到 → 返回默认路径（新安装用）
  echo "$ws/plugins/memory-lancedb-pro"
  return 0  # 默认路径，后续由 FRESH_INSTALL 逻辑判断是否需要全新安装
}

# ============================================================
#  卸载流程
# ============================================================
if $UNINSTALL; then
  info "进入卸载模式 / Entering uninstall mode..."

  OPENCLAW_JSON="$HOME/.openclaw/openclaw.json"
  if [[ ! -f "$OPENCLAW_JSON" ]]; then
    fail "找不到 / Not found: $OPENCLAW_JSON"
  fi

  LATEST_BACKUP=$(ls -t "$OPENCLAW_JSON".backup.* 2>/dev/null | head -1 || echo "")

  if [[ -n "$LATEST_BACKUP" ]]; then
    echo ""
    echo "  找到备份文件 / Found backup: $LATEST_BACKUP"
    echo "  备份时间 / Backup time: $(stat -f '%Sm' "$LATEST_BACKUP" 2>/dev/null || stat -c '%y' "$LATEST_BACKUP" 2>/dev/null || echo '未知 / unknown')"
    echo ""
    read -p "  要还原这个备份吗？/ Restore this backup? (y/n) [y]: " RESTORE
    RESTORE=${RESTORE:-y}
    if [[ "$RESTORE" == "y" || "$RESTORE" == "Y" ]]; then
      cp "$OPENCLAW_JSON" "$OPENCLAW_JSON.before-uninstall.$(date +%Y%m%d_%H%M%S)"
      cp "$LATEST_BACKUP" "$OPENCLAW_JSON"
      success "openclaw.json 已还原 / openclaw.json restored"
    fi
  else
    warn "没有找到备份文件，跳过配置还原 / No backup found, skipping config restore."
    echo "  如果要手动清理，请编辑 / To clean up manually, edit $OPENCLAW_JSON"
  fi

  WORKSPACE=$(openclaw config get agents.defaults.workspace 2>/dev/null | tr -d '"' | tr -d ' ' || echo "")
  if [[ -z "$WORKSPACE" || ! -d "$WORKSPACE" ]] && [[ -f "$OPENCLAW_JSON" ]]; then
    WORKSPACE=$(node -e "
      try {
        const d = JSON.parse(require('fs').readFileSync('$OPENCLAW_JSON','utf8'));
        const w = d?.agents?.defaults?.workspace || '';
        process.stdout.write(w.replace(/^~/, process.env.HOME || ''));
      } catch(e) { process.stdout.write(''); }
    " 2>/dev/null)
  fi
  [[ -z "$WORKSPACE" || ! -d "$WORKSPACE" ]] && for g in "$HOME/.openclaw/workspace" "$HOME/.openclaw-workspace"; do [[ -d "$g" ]] && WORKSPACE="$g" && break; done
  PLUGIN_DIR=$(detect_plugin_dir "$WORKSPACE" "$OPENCLAW_JSON")
  if [[ -d "$PLUGIN_DIR" ]]; then
    echo ""
    read -p "  要删除插件目录吗？/ Delete plugin dir $PLUGIN_DIR? (y/n) [n]: " DEL_PLUGIN
    DEL_PLUGIN=${DEL_PLUGIN:-n}
    if [[ "$DEL_PLUGIN" == "y" || "$DEL_PLUGIN" == "Y" ]]; then
      if [[ -d "$HOME/.Trash" ]]; then
        mv "$PLUGIN_DIR" "$HOME/.Trash/memory-lancedb-pro.$(date +%Y%m%d_%H%M%S)"
        success "插件目录已移到废纸篓 / Plugin dir moved to Trash"
      else
        rm -rf "$PLUGIN_DIR"
        success "插件目录已删除 / Plugin dir deleted"
      fi
    fi
  fi

  echo ""
  success "卸载完成 / Uninstall complete. Run: openclaw gateway restart"
  exit 0
fi

# ============================================================
#  安装 / 升级流程
# ============================================================

# ── 第 1 步：环境检查 ──
info "第 1 步：环境检查 / Environment check..."

if ! command -v node &>/dev/null; then
  fail "找不到 node / Node.js not found. Please install Node.js (v18+): https://nodejs.org"
fi
NODE_VER=$(node --version)
success "Node.js $NODE_VER"

if $SELFCHECK_ONLY; then
  warn "--selfcheck-only 模式：跳过安装，只做能力探测 / Skipping install, probe only."
else
  command -v openclaw >/dev/null 2>&1 || fail "找不到 openclaw 命令 / openclaw not found. Please install OpenClaw first."
  success "openclaw CLI 已找到 / openclaw CLI found"

  command -v npm &>/dev/null || fail "找不到 npm / npm not found. Please reinstall Node.js."
fi

# 检查 jq
HAS_JQ=false
if ! $SELFCHECK_ONLY && command -v jq &>/dev/null; then
  HAS_JQ=true
  success "jq 已找到（将自动合并配置）/ jq found (auto-merge enabled)"
elif ! $SELFCHECK_ONLY; then
  echo ""
  warn "═══ 强烈建议先装 jq 再跑本脚本 / Strongly recommend installing jq first ═══"
  echo ""
  echo "    没有 jq 的影响 / Without jq:"
  echo "    ✗ 配置需要手动编辑（容易写错）/ Config must be edited manually (error-prone)"
  echo "    ✗ 看不到配置全景 / Cannot display config overview"
  echo "    ✗ 可选功能无法自动开启 / Optional features cannot be toggled automatically"
  echo ""
  echo "    安装一行命令 / Install with one command:"
  echo "    Mac:   brew install jq"
  echo "    Linux: sudo apt install jq"
  echo ""
  read -p "    继续无 jq 模式？/ Continue without jq? (y/n) [n]: " CONTINUE_NO_JQ
  CONTINUE_NO_JQ=${CONTINUE_NO_JQ:-n}
  if [[ ! "$CONTINUE_NO_JQ" =~ ^[yY]$ ]]; then
    info "请安装 jq 后重跑 / Install jq and re-run. Exiting."
    exit 0
  fi
fi

# ── 第 2 步：确认 workspace ──
echo ""
info "第 2 步：确认 workspace 路径 / Confirm workspace..."

if $SELFCHECK_ONLY; then
  WORKSPACE=""
  success "selfcheck-only 模式跳过 workspace 检查 / Skipping workspace check"
else
  WORKSPACE=$(openclaw config get agents.defaults.workspace 2>/dev/null | tr -d '"' | tr -d ' ' || echo "")
  # fallback：openclaw config get 可能因 invalid config 失败，直接从 JSON 文件读
  if [[ -z "$WORKSPACE" || ! -d "$WORKSPACE" ]]; then
    OC_JSON="$HOME/.openclaw/openclaw.json"
    if [[ -f "$OC_JSON" ]]; then
      WORKSPACE=$(node -e "
        try {
          const d = JSON.parse(require('fs').readFileSync('$OC_JSON','utf8'));
          const w = d?.agents?.defaults?.workspace || '';
          process.stdout.write(w.replace(/^~/, process.env.HOME || ''));
        } catch(e) { process.stdout.write(''); }
      " 2>/dev/null)
      if [[ -n "$WORKSPACE" && -d "$WORKSPACE" ]]; then
        info "从 openclaw.json 直接读取 workspace / Read workspace from openclaw.json directly (CLI may be unavailable)"
      fi
    fi
  fi
  if [[ -z "$WORKSPACE" || ! -d "$WORKSPACE" ]]; then
    # 最后兜底：常见默认路径
    for guess in "$HOME/.openclaw/workspace" "$HOME/.openclaw-workspace"; do
      if [[ -d "$guess" ]]; then
        WORKSPACE="$guess"
        info "自动探测到 workspace / Auto-detected workspace: $WORKSPACE"
        break
      fi
    done
  fi
  if [[ -z "$WORKSPACE" || ! -d "$WORKSPACE" ]]; then
    echo ""
    echo "  无法自动获取 workspace 路径 / Cannot auto-detect workspace path."
    read -p "  请手动输入 OpenClaw workspace 路径 / Enter your OpenClaw workspace path: " WORKSPACE
    [[ -d "$WORKSPACE" ]] || fail "路径不存在 / Path not found: $WORKSPACE"
  fi
  success "workspace: $WORKSPACE"
fi

OPENCLAW_JSON="$HOME/.openclaw/openclaw.json"
PLUGIN_DIR=$(detect_plugin_dir "$WORKSPACE" "$OPENCLAW_JSON")
PLUGIN_MANIFEST="$PLUGIN_DIR/openclaw.plugin.json"

# ── 第 1.5 步：自动修复 additional properties（防止重启循环） ──
if $HAS_JQ && [[ -f "$OPENCLAW_JSON" ]] && [[ -f "$PLUGIN_MANIFEST" ]]; then
  CFG_CHECK_PATH='.plugins.entries["memory-lancedb-pro"].config'
  CURRENT_CFG_CHECK=$(jq -r "$CFG_CHECK_PATH // empty" "$OPENCLAW_JSON" 2>/dev/null)
  if [[ -n "$CURRENT_CFG_CHECK" && "$CURRENT_CFG_CHECK" != "null" ]]; then
    REPAIR_RESULT=$(filter_config_by_schema "$CURRENT_CFG_CHECK" "$PLUGIN_MANIFEST") || true
    if [[ -n "$REPAIR_RESULT" ]]; then
      REPAIR_REMOVED=$(echo "$REPAIR_RESULT" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));const r=d.removed||[];if(r.length)console.log(r.join(', '));" 2>/dev/null || echo "")
      if [[ -n "$REPAIR_REMOVED" ]]; then
        warn "检测到非法字段，自动修复 / Invalid fields detected, auto-repairing: $REPAIR_REMOVED"
        REPAIR_CFG=$(echo "$REPAIR_RESULT" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));process.stdout.write(JSON.stringify(d.filtered,null,2));" 2>/dev/null)
        if [[ -n "$REPAIR_CFG" ]]; then
          jq_safe_write "$CFG_CHECK_PATH = $REPAIR_CFG" "$OPENCLAW_JSON" \
            && success "已自动清理非法字段 / Auto-repaired invalid config fields" \
            || warn "自动修复写回失败 / Auto-repair write-back failed"
        fi
      fi
    fi
  fi
fi

# ── 第 2.5 步：已有 git 仓库自动更新到目标 ref ──
# 不管是升级路径还是全新安装，只要插件目录是 git 仓库就先拉到最新
OLD_HEAD=""
if ! $SELFCHECK_ONLY && [[ -d "$PLUGIN_DIR/.git" ]]; then
  echo ""
  info "检测到已有 git 仓库，自动更新 / Git repo detected, updating..."
  # 同步远程分支状态，清理已删除的远程分支（如 main → main-legacy）
  git -C "$PLUGIN_DIR" fetch --prune --quiet 2>/dev/null || true
  # 如果没指定 --ref，自动检测远程默认分支
  if [[ -z "$PLUGIN_REF" ]]; then
    PLUGIN_REF=$(git -C "$PLUGIN_DIR" remote show origin 2>/dev/null \
      | awk '/HEAD branch/{print $NF}')
    PLUGIN_REF="${PLUGIN_REF:-master}"
    info "自动检测到默认分支 / Default branch: $PLUGIN_REF"
  fi
  OLD_HEAD=$(git -C "$PLUGIN_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  info "当前 / Current HEAD: $OLD_HEAD → 目标 / Target ref: $PLUGIN_REF"
  if $DRY_RUN; then
    dry "cd $PLUGIN_DIR && git fetch origin && git checkout $PLUGIN_REF && git pull origin $PLUGIN_REF"
  else
    if git -C "$PLUGIN_DIR" fetch origin 2>&1; then
      # 清理 npm 生成的本地改动（package-lock.json 等），防止 checkout 被挡
      git -C "$PLUGIN_DIR" checkout -- package-lock.json 2>/dev/null || true
      git -C "$PLUGIN_DIR" stash --quiet 2>/dev/null || true
      if git -C "$PLUGIN_DIR" checkout "$PLUGIN_REF" 2>&1; then
        # 分支才 pull，tag 不需要
        if git -C "$PLUGIN_DIR" symbolic-ref HEAD >/dev/null 2>&1; then
          git -C "$PLUGIN_DIR" pull origin "$PLUGIN_REF" 2>&1 || warn "git pull 失败，但 checkout 成功 / git pull failed, but checkout succeeded"
        fi
        INSTALLED_REF=$(git -C "$PLUGIN_DIR" rev-parse --short HEAD 2>/dev/null || echo "$PLUGIN_REF")
        if [[ "$OLD_HEAD" != "$INSTALLED_REF" ]]; then
          success "已更新 / Updated: $OLD_HEAD → $INSTALLED_REF"
          # 版本变了，依赖可能变了，后面需要重新 npm install
        else
          success "已是最新 / Already up to date: $INSTALLED_REF"
        fi
      else
        warn "git checkout $PLUGIN_REF 失败，保持当前版本 $OLD_HEAD / checkout failed, keeping $OLD_HEAD"
      fi
    else
      warn "git fetch 失败（网络问题？），保持当前版本 $OLD_HEAD / fetch failed, keeping $OLD_HEAD"
    fi
  fi
fi

# ── 第 3 步：检测已安装版本 ──
echo ""
info "第 3 步：检测已安装版本 / Detecting installed version..."

FRESH_INSTALL=true
LOCAL_VER="0.0.0"
UPGRADE_DONE=false

if [[ -d "$PLUGIN_DIR" && -f "$PLUGIN_DIR/package.json" ]]; then
  FRESH_INSTALL=false
  LOCAL_VER=$(PLUGIN_DIR_ENV="$PLUGIN_DIR" node -e "console.log(require(process.env.PLUGIN_DIR_ENV+'/package.json').version)" 2>/dev/null || echo "unknown")
  success "检测到已安装版本 / Installed version: v$LOCAL_VER"
  info "插件路径 / Plugin path: $PLUGIN_DIR"

  # 检查配置是否完整（插件目录在但 openclaw.json 里没注册）
  CONFIG_MISSING=false
  if [[ -f "$OPENCLAW_JSON" ]]; then
    HAS_ENTRY=$(OC_JSON_ENV="$OPENCLAW_JSON" node -e "
      try {
        const d = JSON.parse(require('fs').readFileSync(process.env.OC_JSON_ENV,'utf8'));
        const e = d?.plugins?.entries?.['memory-lancedb-pro'];
        process.stdout.write(e ? 'yes' : 'no');
      } catch(e) { process.stdout.write('no'); }
    " 2>/dev/null)
    if [[ "$HAS_ENTRY" != "yes" ]]; then
      CONFIG_MISSING=true
      warn "插件目录存在但配置缺失，将补写配置 / Plugin dir exists but config missing, will re-register."
    fi
  fi
else
  info "未检测到已安装版本，将执行全新安装 / No existing installation, will do fresh install."
  info "新安装路径 / Install path: $PLUGIN_DIR"
fi

# ── 第 4 步：版本对比 + 升级（仅已安装时） ──
if ! $FRESH_INSTALL && ! $SELFCHECK_ONLY; then
  echo ""
  info "第 4 步：检查新版本 / Checking for updates..."

  if $INCLUDE_BETA; then
    info "BETA 模式：包含预发布版本 / Including pre-release versions"
  fi

  # 优先从 git 远程分支读真实版本（和实际安装目标一致），fallback 到 tags API
  REMOTE_VER=""
  if [[ -d "$PLUGIN_DIR/.git" && -n "${PLUGIN_REF:-}" ]]; then
    REMOTE_VER=$(git -C "$PLUGIN_DIR" show "origin/$PLUGIN_REF:package.json" 2>/dev/null \
      | P_JSON=/dev/stdin node -e "
        const fs = require('fs');
        try { console.log(JSON.parse(fs.readFileSync('/dev/stdin','utf8')).version); }
        catch(e) { console.log(''); }
      " 2>/dev/null || echo "")
  fi
  if [[ -z "$REMOTE_VER" ]]; then
    REMOTE_VER=$(get_remote_version)
  fi

  if [[ -z "$REMOTE_VER" ]]; then
    warn "无法获取远程版本信息，跳过升级检测 / Cannot fetch remote version, skipping upgrade check."
  elif [[ "$LOCAL_VER" == "$REMOTE_VER" ]]; then
    success "已是最新版本 / Already up to date: v$LOCAL_VER"
  elif needs_update "$LOCAL_VER" "$REMOTE_VER"; then
    echo ""
    echo -e "  ${BOLD}发现新版本 / New version available:${NC}"
    echo -e "    当前 / Current: ${YELLOW}v$LOCAL_VER${NC}"
    echo -e "    最新 / Latest:  ${GREEN}v$REMOTE_VER${NC}"

    # 如果目标版本本身就是 beta，changelog 也要展示 beta
    BETA_FLAG="false"
    if $INCLUDE_BETA || [[ "$REMOTE_VER" == *-* ]]; then BETA_FLAG="true"; fi
    show_changelog "$LOCAL_VER" "$BETA_FLAG"

    read -p "  是否升级？/ Upgrade now? (y/n) [y]: " DO_UPGRADE
    DO_UPGRADE=${DO_UPGRADE:-y}

    if [[ "$DO_UPGRADE" =~ ^[yY]$ ]]; then
      if $DRY_RUN; then
        dry "备份 / Backup $PLUGIN_DIR → ${PLUGIN_DIR}.backup.TIMESTAMP"
        dry "git clone --depth 1 $GITHUB_URL → 临时目录 / temp dir"
        dry "npm install"
        dry "替换插件目录 / Swap plugin directory"
        success "DRY-RUN: 升级步骤展示完毕 / Upgrade steps displayed"
      else
        if upgrade_plugin "$PLUGIN_DIR" "$LOCAL_VER"; then
          UPGRADE_DONE=true
          LOCAL_VER=$(P_DIR="$PLUGIN_DIR" node -e "console.log(require(process.env.P_DIR+'/package.json').version)" 2>/dev/null || echo "$REMOTE_VER")
        else
          echo ""
          echo "======================================================"
          warn "升级未成功，仍在 v$LOCAL_VER / Upgrade unsuccessful, still on v$LOCAL_VER"
          info "旧版本可正常使用 / Old version works fine, no impact."
          echo "======================================================"
        fi
      fi
    else
      info "跳过升级，保持 v$LOCAL_VER / Skipping upgrade, keeping v$LOCAL_VER"
    fi
  else
    success "本地版本 v$LOCAL_VER 已是最新（或比远程更新）/ Local version is up to date."
  fi
fi

# ── 已安装用户：git 更新后重新安装依赖 ──
if ! $FRESH_INSTALL && [[ -n "${OLD_HEAD:-}" ]] && [[ "$OLD_HEAD" != "$(git -C "$PLUGIN_DIR" rev-parse --short HEAD 2>/dev/null || echo "$OLD_HEAD")" ]]; then
  echo ""
  info "插件代码已更新，重新安装依赖 / Code updated, reinstalling dependencies..."
  if $DRY_RUN; then
    dry "cd $PLUGIN_DIR && npm install"
  else
    if ! (cd "$PLUGIN_DIR" && npm install --loglevel=warn 2>&1); then
      warn "默认源失败，切换镜像 / Default registry failed, trying mirror..."
      (cd "$PLUGIN_DIR" && npm install --loglevel=warn --registry https://registry.npmmirror.com 2>&1) \
        || warn "npm install 失败 / npm install failed. Run manually: cd $PLUGIN_DIR && npm install"
    fi
    success "依赖更新完成 / Dependencies updated"
  fi
fi

# ── 以下步骤：全新安装 或 配置缺失时需要 ──
if $FRESH_INSTALL || ${CONFIG_MISSING:-false}; then

  # selfcheck-only 提前退出
  if $SELFCHECK_ONLY && [[ ! -f "$SELF_CHECK_SCRIPT" ]]; then
    warn "selfcheck 需要先安装插件 / Plugin must be installed first for selfcheck."
    echo "  → 请先运行 / Please run: bash setup-memory.sh"
    exit 1
  fi

  # ============================================================
  #  第 4 步：选择 API 来源（v3.0 核心改动）
  # ============================================================
  echo ""
  info "第 4 步：选择 API 来源 / Choose API provider..."
  echo ""
  echo -e "  ${BOLD}你的 embedding 服务是？/ Which embedding service?${NC}"
  echo ""
  echo -e "  ── 快捷选择（自动填 URL）/ Quick picks (auto-fill URL) ──"
  echo -e "  ${BOLD}1) Jina${NC}              — 免费注册 / Free signup, embedding + rerank ${GREEN}← 推荐 / Recommended${NC}"
  echo -e "  ${BOLD}2) 阿里云 DashScope${NC}  — 通义系列，国内快 / Tongyi, fast in China"
  echo -e "  ${BOLD}3) SiliconFlow${NC}       — 国内加速，免费额度大 / China accelerated, generous free tier"
  echo -e "  ${BOLD}4) OpenAI${NC}            — 最省心但最贵 / Easiest but priciest"
  echo ""
  echo -e "  ── 通用入口 / General ──"
  echo -e "  ${BOLD}5) Ollama / 本地模型${NC}  — 零成本，自动探测 / Zero cost, auto-detect local models"
  echo -e "  ${BOLD}6) 其他 OpenAI 兼容服务${NC} — 填 baseURL，自动探测 / Other OpenAI-compatible, auto-detect"
  echo ""

  PROVIDER=""
  PROVIDER_PRESET=""
  API_BASE_URL=""
  API_KEY=""
  EMBEDDING_MODEL=""
  RERANK_ENDPOINT=""
  RERANK_API_KEY=""
  RERANK_MODEL=""
  RERANK_PROVIDER=""

  while true; do
    read -p "  输入数字 / Enter number (1-6), Enter for 1: " PROVIDER_CHOICE
    PROVIDER_CHOICE=${PROVIDER_CHOICE:-1}
    case "$PROVIDER_CHOICE" in
      1) PROVIDER="jina";       PROVIDER_PRESET="jina"; break ;;
      2) PROVIDER="dashscope";  PROVIDER_PRESET="dashscope"; break ;;
      3) PROVIDER="siliconflow"; PROVIDER_PRESET="siliconflow"; break ;;
      4) PROVIDER="openai";     PROVIDER_PRESET="openai"; break ;;
      5) PROVIDER="ollama";     PROVIDER_PRESET="ollama"; break ;;
      6) PROVIDER="custom";     PROVIDER_PRESET=""; break ;;
      *) warn "无效选择，请输入 1-6 / Invalid, enter 1-6." ;;
    esac
  done

  # ── 按来源获取 baseURL + apiKey ──

  case "$PROVIDER" in
    jina)
      API_BASE_URL="https://api.jina.ai/v1"
      echo ""
      echo "  Jina 免费注册就能用 / Free signup: https://jina.ai/"
      echo ""
      read -p "  请粘贴 Jina API Key（直接回车跳过）/ Paste your Jina API Key (Enter to skip): " API_KEY
      if [[ -z "$API_KEY" ]]; then
        warn "未填写 Key，保留占位符 / No key entered, placeholder saved. Replace it later."
        API_KEY="YOUR_JINA_API_KEY"
      elif [[ "$API_KEY" != jina_* ]]; then
        warn "Key 不以 jina_ 开头 / Key doesn't start with jina_, please verify."
        read -p "  继续？/ Continue? (y/n) [y]: " CONFIRM
        [[ "${CONFIRM:-y}" =~ ^[yY]$ ]] || fail "用户取消 / Cancelled by user."
      fi
      RERANK_ENDPOINT="https://api.jina.ai/v1/rerank"
      RERANK_API_KEY="$API_KEY"
      RERANK_MODEL="jina-reranker-v3"
      RERANK_PROVIDER="jina"
      ;;

    dashscope)
      API_BASE_URL="https://dashscope.aliyuncs.com/compatible-mode/v1"
      echo ""
      echo "  DashScope 控制台 / Console: https://dashscope.console.aliyun.com/"
      echo ""
      read -p "  请粘贴 DashScope API Key / Paste DashScope API Key: " API_KEY
      if [[ -z "$API_KEY" ]]; then
        warn "未填写 Key，保留占位符 / No key entered, placeholder saved."
        API_KEY="YOUR_API_KEY"
      fi
      RERANK_ENDPOINT="https://dashscope.aliyuncs.com/compatible-api/v1/reranks"
      RERANK_API_KEY="$API_KEY"
      RERANK_MODEL="qwen3-rerank"
      RERANK_PROVIDER="jina"
      ;;

    siliconflow)
      API_BASE_URL="https://api.siliconflow.cn/v1"
      echo ""
      echo "  SiliconFlow 控制台 / Console: https://cloud.siliconflow.cn/"
      echo ""
      read -p "  请粘贴 SiliconFlow API Key / Paste SiliconFlow API Key: " API_KEY
      if [[ -z "$API_KEY" ]]; then
        warn "未填写 Key，保留占位符 / No key entered, placeholder saved."
        API_KEY="YOUR_API_KEY"
      fi
      RERANK_ENDPOINT="https://api.siliconflow.cn/v1/rerank"
      RERANK_API_KEY="$API_KEY"
      RERANK_MODEL="BAAI/bge-reranker-v2-m3"
      RERANK_PROVIDER="siliconflow"
      ;;

    openai)
      API_BASE_URL="https://api.openai.com/v1"
      echo ""
      echo "  OpenAI 控制台 / Console: https://platform.openai.com/api-keys"
      echo ""
      read -p "  请粘贴 OpenAI API Key / Paste OpenAI API Key: " API_KEY
      if [[ -z "$API_KEY" ]]; then
        warn "未填写 Key，保留占位符 / No key entered, placeholder saved."
        API_KEY="YOUR_API_KEY"
      fi
      # OpenAI 没有 rerank
      ;;

    ollama)
      echo ""
      # 允许用户自定义 Ollama 地址 / Allow custom Ollama host
      read -p "  Ollama 地址 / Ollama host (默认 / default: localhost:11434): " OLLAMA_HOST_INPUT
      OLLAMA_HOST="${OLLAMA_HOST_INPUT:-localhost:11434}"
      # 补全协议前缀 / Ensure http:// prefix
      if [[ "$OLLAMA_HOST" != http://* && "$OLLAMA_HOST" != https://* ]]; then
        OLLAMA_HOST="http://${OLLAMA_HOST}"
      fi
      # 去掉尾部斜杠 / Strip trailing slash
      OLLAMA_HOST="${OLLAMA_HOST%/}"

      info "检测 Ollama 服务 / Detecting Ollama service at ${OLLAMA_HOST}..."

      # 检测 Ollama 是否运行
      OLLAMA_RUNNING=false
      if curl -s --max-time 3 "${OLLAMA_HOST}/api/version" >/dev/null 2>&1; then
        OLLAMA_RUNNING=true
        success "Ollama 服务正在运行 / Ollama service is running"
      elif [[ "$OLLAMA_HOST" == *"localhost"* || "$OLLAMA_HOST" == *"127.0.0.1"* ]] && command -v ollama &>/dev/null; then
        warn "Ollama 已安装但未运行 / Ollama installed but not running. Run 'ollama serve' first."
        read -p "  已启动 Ollama？按回车继续 / Ollama running? Press Enter to continue, Ctrl+C to exit: "
        if curl -s --max-time 3 "${OLLAMA_HOST}/api/version" >/dev/null 2>&1; then
          OLLAMA_RUNNING=true
        else
          fail "Ollama 服务仍未响应 / Ollama still not responding at ${OLLAMA_HOST}."
        fi
      else
        fail "无法连接 Ollama / Cannot reach Ollama at ${OLLAMA_HOST}. Check the address and try again."
      fi

      API_BASE_URL="${OLLAMA_HOST}/v1"
      API_KEY="ollama"

      # 列出本地 embedding 模型
      echo ""
      info "查询本地模型列表 / Listing local models..."
      OLLAMA_MODELS=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' || echo "")

      if [[ -n "$OLLAMA_MODELS" ]]; then
        # 筛选 embedding 模型
        EMBED_MODELS=""
        ALL_MODELS=""
        while IFS= read -r model; do
          ALL_MODELS="$ALL_MODELS $model"
          # 常见 embedding 模型名称匹配
          if echo "$model" | grep -qiE 'embed|bge|e5-|gte-|nomic|mxbai'; then
            EMBED_MODELS="$EMBED_MODELS $model"
          fi
        done <<< "$OLLAMA_MODELS"

        if [[ -n "$EMBED_MODELS" ]]; then
          echo ""
          echo -e "  ${BOLD}检测到以下 embedding 模型 / Detected embedding models:${NC}"
          local_n=0
          declare -a LOCAL_EMBED_LIST=()
          for m in $EMBED_MODELS; do
            local_n=$((local_n + 1))
            LOCAL_EMBED_LIST+=("$m")
            echo "    $local_n) $m"
          done
          echo ""
          read -p "  选一个 / Pick one (number, Enter for 1): " EMBED_CHOICE
          EMBED_CHOICE=${EMBED_CHOICE:-1}
          if [[ "$EMBED_CHOICE" =~ ^[0-9]+$ ]] && [[ "$EMBED_CHOICE" -ge 1 ]] && [[ "$EMBED_CHOICE" -le $local_n ]]; then
            EMBEDDING_MODEL="${LOCAL_EMBED_LIST[$((EMBED_CHOICE - 1))]}"
          else
            EMBEDDING_MODEL="${LOCAL_EMBED_LIST[0]}"
          fi
          success "已选模型 / Selected model: $EMBEDDING_MODEL"
        else
          echo ""
          warn "本地没有 embedding 模型 / No local embedding models. Available: $ALL_MODELS"
          echo ""
          echo "  推荐拉一个 embedding 模型 / Recommended — pull an embedding model:"
          echo "    ollama pull nomic-embed-text"
          echo "    ollama pull mxbai-embed-large"
          echo ""
          read -p "  已拉取？输入模型名 / Already pulled? Enter model name (Enter for nomic-embed-text): " EMBEDDING_MODEL
          EMBEDDING_MODEL=${EMBEDDING_MODEL:-nomic-embed-text}

          # 自动拉取
          if ! echo "$ALL_MODELS" | grep -q "$EMBEDDING_MODEL"; then
            echo ""
            read -p "  要自动拉取 $EMBEDDING_MODEL 吗？/ Auto-pull $EMBEDDING_MODEL? (y/n) [y]: " PULL_IT
            if [[ "${PULL_IT:-y}" =~ ^[yY]$ ]]; then
              info "正在拉取 / Pulling $EMBEDDING_MODEL..."
              if ollama pull "$EMBEDDING_MODEL" 2>&1; then
                success "模型拉取完成 / Model pulled successfully"
              else
                fail "拉取失败 / Pull failed. Run manually: ollama pull $EMBEDDING_MODEL"
              fi
            fi
          fi
        fi
      else
        warn "没有检测到任何本地模型 / No local models detected."
        echo ""
        echo "  请先拉取一个 embedding 模型 / Pull an embedding model first:"
        echo "    ollama pull nomic-embed-text"
        echo ""
        read -p "  已拉取？输入模型名 / Already pulled? Enter model name (Enter for nomic-embed-text): " EMBEDDING_MODEL
        EMBEDDING_MODEL=${EMBEDDING_MODEL:-nomic-embed-text}
      fi
      # Ollama 没有 rerank
      ;;

    custom)
      echo ""
      echo "  填写 OpenAI 兼容 API 信息 / Enter your OpenAI-compatible API info:"
      echo "  （支持 / Supports: LM Studio, vLLM, LocalAI, DeepSeek, Together, etc.）"
      echo ""
      read -p "  API Base URL (e.g. http://localhost:1234/v1): " API_BASE_URL
      [[ -n "$API_BASE_URL" ]] || fail "Base URL 不能为空 / Base URL cannot be empty"

      read -p "  API Key（回车跳过 / Enter to skip）: " API_KEY
      API_KEY=${API_KEY:-"no-key"}

      echo ""
      read -p "  Embedding 模型名 / Embedding model name (Enter to auto-detect): " EMBEDDING_MODEL
      echo ""
      echo "  是否有 rerank 服务？/ Do you have a rerank service?"
      read -p "  Rerank endpoint URL（回车跳过 / Enter to skip）: " RERANK_ENDPOINT
      if [[ -n "$RERANK_ENDPOINT" ]]; then
        read -p "  Rerank model name: " RERANK_MODEL
        RERANK_API_KEY="$API_KEY"
        RERANK_PROVIDER="jina"  # 默认假设 Jina 格式
      fi
      ;;
  esac

  success "API 来源 / API provider: $PROVIDER"

  # ============================================================
  #  第 5 步：能力探测（v3.0 核心改动）
  # ============================================================
  echo ""
  info "第 5 步：能力探测 / Probing API capabilities..."

  PROBE_RESULT="$(mktemp "${TMPDIR:-/tmp}/memory-probe-XXXXXX")"
  _TMPFILES+=("$PROBE_RESULT")

  # 构建 probe 命令参数
  PROBE_ARGS=(--baseURL "$API_BASE_URL" --apiKey "$API_KEY" --output "$PROBE_RESULT")
  if [[ -n "$PROVIDER_PRESET" ]]; then
    PROBE_ARGS+=(--preset "$PROVIDER_PRESET")
  fi
  if [[ -n "$EMBEDDING_MODEL" ]]; then
    PROBE_ARGS+=(--model "$EMBEDDING_MODEL")
  fi
  if [[ -n "$RERANK_ENDPOINT" ]]; then
    PROBE_ARGS+=(--rerankEndpoint "$RERANK_ENDPOINT")
    PROBE_ARGS+=(--rerankApiKey "${RERANK_API_KEY:-$API_KEY}")
    PROBE_ARGS+=(--rerankModel "${RERANK_MODEL:-}")
    PROBE_ARGS+=(--rerankProvider "${RERANK_PROVIDER:-jina}")
  fi

  if $DRY_RUN; then
    dry "node $PROBE_SCRIPT ${PROBE_ARGS[*]}"
    RECOMMENDED_LEVEL="balanced-default"
    warn "DRY-RUN 模式不真实探测 / DRY-RUN skips real probe, assuming balanced-default."
  else
    info "正在探测，请稍候 / Probing, please wait..."
    echo ""

    if node "$PROBE_SCRIPT" "${PROBE_ARGS[@]}" 2>/dev/null; then
      # 解析探测结果
      PROBE_EMB_OK=$(node -p "JSON.parse(require('fs').readFileSync('$PROBE_RESULT','utf8')).embedding.available" 2>/dev/null || echo "false")
      PROBE_EMB_MODEL=$(node -p "JSON.parse(require('fs').readFileSync('$PROBE_RESULT','utf8')).embedding.model || 'unknown'" 2>/dev/null || echo "unknown")
      PROBE_EMB_DIM=$(node -p "JSON.parse(require('fs').readFileSync('$PROBE_RESULT','utf8')).embedding.dimensions || 0" 2>/dev/null || echo "0")
      PROBE_EMB_MS=$(node -p "JSON.parse(require('fs').readFileSync('$PROBE_RESULT','utf8')).embedding.latencyMs || 0" 2>/dev/null || echo "0")
      PROBE_RERANK_OK=$(node -p "JSON.parse(require('fs').readFileSync('$PROBE_RESULT','utf8')).rerank.available" 2>/dev/null || echo "false")
      PROBE_RERANK_MODEL=$(node -p "JSON.parse(require('fs').readFileSync('$PROBE_RESULT','utf8')).rerank.model || ''" 2>/dev/null || echo "")
      PROBE_RERANK_MS=$(node -p "JSON.parse(require('fs').readFileSync('$PROBE_RESULT','utf8')).rerank.latencyMs || 0" 2>/dev/null || echo "0")
      RECOMMENDED_LEVEL=$(node -p "JSON.parse(require('fs').readFileSync('$PROBE_RESULT','utf8')).recommendedLevel || 'lite-safe'" 2>/dev/null || echo "lite-safe")

      # 展示探测结果
      if [[ "$PROBE_EMB_OK" == "true" ]]; then
        success "Embedding   $PROBE_EMB_MODEL (${PROBE_EMB_DIM}d, ${PROBE_EMB_MS}ms)"
      else
        PROBE_EMB_ERR=$(node -p "JSON.parse(require('fs').readFileSync('$PROBE_RESULT','utf8')).embedding.error || 'unknown error'" 2>/dev/null || echo "unknown error")
        warn "Embedding   探测失败 / Probe failed: $PROBE_EMB_ERR"
      fi

      if [[ "$PROBE_RERANK_OK" == "true" ]]; then
        success "Rerank      $PROBE_RERANK_MODEL (${PROBE_RERANK_MS}ms)"
      else
        PROBE_RERANK_REASON=$(node -p "JSON.parse(require('fs').readFileSync('$PROBE_RESULT','utf8')).rerank.reason || 'unavailable'" 2>/dev/null || echo "unavailable")
        info "Rerank      $PROBE_RERANK_REASON"
      fi

      echo ""

      if [[ "$PROBE_EMB_OK" != "true" ]]; then
        # embedding 都不通，提示用户
        warn "Embedding 探测失败 / Embedding probe failed. Possible causes:"
        echo "    - API Key 不正确 / Incorrect API Key"
        echo "    - 服务未启动 / Service not running"
        echo "    - 网络不通 / Network unreachable"
        echo ""
        echo "  可先选 lite-safe 装上，之后调通重跑 / Pick lite-safe for now, re-run after fixing."
        RECOMMENDED_LEVEL="lite-safe"
      fi

      if $SELFCHECK_ONLY; then
        echo ""
        success "--selfcheck-only 完成 / Done. Probe report: $PROBE_RESULT"
        exit 0
      fi
    else
      warn "探测脚本执行失败，使用默认推荐 / Probe script failed, using defaults."
      RECOMMENDED_LEVEL="balanced-default"
      if $SELFCHECK_ONLY; then
        fail "--selfcheck-only 模式下探测失败 / Probe failed in selfcheck-only mode."
      fi
      # 探测失败时用已收集的变量生成兜底探测结果，防止下游读到空文件
      # Generate fallback probe result from collected variables so downstream doesn't read empty file
      PROBE_RESULT_ENV="$PROBE_RESULT" API_BASE_URL_ENV="$API_BASE_URL" API_KEY_ENV="$API_KEY" EMBEDDING_MODEL_ENV="${EMBEDDING_MODEL:-unknown}" \
        node -e "
          const result = {
            baseURL: process.env.API_BASE_URL_ENV,
            embedding: {
              available: true,
              model: process.env.EMBEDDING_MODEL_ENV,
              dimensions: 1024,
              apiKey: process.env.API_KEY_ENV,
              baseURL: process.env.API_BASE_URL_ENV,
              taskQuery: null,
              taskPassage: null,
              normalized: false,
            },
            rerank: { available: false, reason: 'probe failed, using fallback' },
          };
          require('fs').writeFileSync(process.env.PROBE_RESULT_ENV, JSON.stringify(result, null, 2));
        " 2>/dev/null || true
    fi
  fi

  # ============================================================
  #  第 6 步：选择配置等级
  # ============================================================
  echo ""
  info "第 6 步：选择配置等级 / Choose config level..."
  echo ""

  # 如果 rerank 不可用，pro-rerank 不推荐
  PRO_NOTE=""
  if [[ "${PROBE_RERANK_OK:-false}" != "true" ]]; then
    PRO_NOTE=" ${YELLOW}(需要 rerank / requires rerank)${NC}"
  fi

  echo -e "  ${BOLD}1) lite-safe${NC}        — 先存不召回 / Store only, no recall ${GREEN}← 新手推荐 / Recommended${NC}"
  echo -e "  ${BOLD}2) balanced-default${NC} — 存+召回 / Store + recall, fits most users"
  echo -e "  ${BOLD}3) pro-rerank${NC}       — 追求召回质量 / Best recall quality$PRO_NOTE"
  echo ""

  # 标记推荐
  case "$RECOMMENDED_LEVEL" in
    lite-safe)        REC_NUM=1 ;;
    balanced-default) REC_NUM=2 ;;
    pro-rerank)       REC_NUM=3 ;;
    *)                REC_NUM=2 ;;
  esac

  while true; do
    read -p "  输入数字 / Enter number (1/2/3), Enter for recommended ($REC_NUM): " LEVEL_CHOICE
    LEVEL_CHOICE=${LEVEL_CHOICE:-$REC_NUM}
    case "$LEVEL_CHOICE" in
      1) TEMPLATE="lite-safe"; break ;;
      2) TEMPLATE="balanced-default"; break ;;
      3)
        if [[ "${PROBE_RERANK_OK:-false}" != "true" ]]; then
          warn "你的 API 不支持 rerank / Your API does not support rerank. Reranking won't work."
          read -p "  仍然选择？/ Still choose this? (y/n) [n]: " FORCE_PRO
          if [[ "${FORCE_PRO:-n}" =~ ^[yY]$ ]]; then
            TEMPLATE="pro-rerank"; break
          fi
        else
          TEMPLATE="pro-rerank"; break
        fi
        ;;
      *) warn "无效选择，请输入 1-3 / Invalid, enter 1-3." ;;
    esac
  done
  success "配置等级 / Config level: $TEMPLATE"

  # ============================================================
  #  第 7 步：生成配置 JSON（v3.0 动态生成）
  # ============================================================
  echo ""
  info "第 7 步：生成配置 / Generating config from probe result..."

  probe_result_is_valid() {
    local f="${1:-}"
    [[ -n "$f" ]] && [[ -s "$f" ]] && node -e "
      const fs = require('fs');
      try {
        const d = JSON.parse(fs.readFileSync(process.env.F, 'utf8'));
        if (!d || typeof d !== 'object') process.exit(1);
        process.exit(0);
      } catch { process.exit(1); }
    " F="$f" 2>/dev/null
  }

  gen_config_from_probe() {
    local PROBE_FILE="$1"
    local LEVEL="$2"

    PROBE_FILE_ENV="$PROBE_FILE" LEVEL_ENV="$LEVEL" \
      RERANK_ENDPOINT_ENV="${RERANK_ENDPOINT:-}" \
      RERANK_MODEL_ENV="${RERANK_MODEL:-}" \
      RERANK_PROVIDER_ENV="${RERANK_PROVIDER:-jina}" \
      RERANK_API_KEY_ENV="${RERANK_API_KEY:-$API_KEY}" \
      EMBEDDING_MODEL_ENV="${EMBEDDING_MODEL:-${DEFAULT_EMBEDDING_MODEL:-unknown}}" \
      node -e "
      const fs = require('fs');
      try {
        const probe = JSON.parse(fs.readFileSync(process.env.PROBE_FILE_ENV, 'utf8'));
        const level = process.env.LEVEL_ENV;
        const configuredRerank = {
          endpoint: process.env.RERANK_ENDPOINT_ENV || '',
          model: process.env.RERANK_MODEL_ENV || '',
          provider: process.env.RERANK_PROVIDER_ENV || 'jina',
          apiKey: process.env.RERANK_API_KEY_ENV || '',
        };

        const emb = probe.embedding || {};

        const config = {
          embedding: {
            apiKey: emb.apiKey || 'YOUR_API_KEY',
            model: emb.model || process.env.EMBEDDING_MODEL_ENV || 'unknown',
            baseURL: emb.baseURL || probe.baseURL || '',
            dimensions: emb.dimensions || 1024,
          },
          autoCapture: true,
          autoRecall: level !== 'lite-safe',
          retrieval: {
            mode: 'hybrid',
            candidatePoolSize: 20,
            minScore: 0.45,
            hardMinScore: level === 'pro-rerank' ? 0.35 : 0.55,
            rerank: 'none',
            filterNoise: true,
          },
          sessionStrategy: 'systemSessionMemory',
        };

        if (emb.taskQuery) config.embedding.taskQuery = emb.taskQuery;
        if (emb.taskPassage) config.embedding.taskPassage = emb.taskPassage;
        if (emb.normalized) config.embedding.normalized = true;

        if (level !== 'lite-safe') {
          config.autoRecallMinLength = 8;
          config.autoRecallTopK = 3;
          config.autoRecallExcludeReflection = true;
          config.autoRecallMaxAgeDays = 30;
          config.autoRecallMaxEntriesPerKey = 10;
        }

        if (level === 'lite-safe') {
          config.mdMirror = { enabled: true, dir: 'memory-md' };
        }

        const rr = probe.rerank || {};
        const canUseConfiguredRerank =
          !!configuredRerank.endpoint && !!configuredRerank.model;
        if (level === 'pro-rerank' && (rr.available || canUseConfiguredRerank)) {
          config.retrieval.rerank = 'cross-encoder';
          config.retrieval.rerankApiKey =
            rr.apiKey || configuredRerank.apiKey || emb.apiKey || '';
          config.retrieval.rerankModel = rr.model || configuredRerank.model || '';
          config.retrieval.rerankEndpoint =
            rr.endpoint || configuredRerank.endpoint || '';
          config.retrieval.rerankProvider =
            rr.provider || configuredRerank.provider || 'jina';
          config.retrieval.recencyHalfLifeDays = 14;
          config.retrieval.recencyWeight = 0.1;
        }

        console.log(JSON.stringify(config, null, 2));
      } catch (err) {
        console.error('Invalid probe result: ' + err.message);
        process.exit(1);
      }
    "
  }

  if $DRY_RUN; then
    dry "从探测结果生成配置 / Generate $TEMPLATE config from probe result"
    CONFIG_JSON='{}'
  else
    if probe_result_is_valid "${PROBE_RESULT:-}"; then
      CONFIG_JSON=$(gen_config_from_probe "$PROBE_RESULT" "$TEMPLATE") || {
        warn "配置生成失败 / Config generation failed from probe result."
        CONFIG_JSON='{}'
      }
    else
      # 没有探测结果（跳过了探测），用预设生成
      warn "探测结果无效或为空，使用预设默认值 / Probe result missing or invalid, using preset defaults."
      # 写一个临时探测结果
      PROBE_RESULT="$(mktemp "${TMPDIR:-/tmp}/memory-probe-XXXXXX")"
      _TMPFILES+=("$PROBE_RESULT")
      HAS_RERANK_ENV="$( [[ -n "${RERANK_ENDPOINT:-}" ]] && [[ -n "${RERANK_MODEL:-}" ]] && echo true || echo false )" \
        RERANK_MODEL_ENV="${RERANK_MODEL:-}" \
        RERANK_ENDPOINT_ENV="${RERANK_ENDPOINT:-}" \
        RERANK_PROVIDER_ENV="${RERANK_PROVIDER:-jina}" \
        RERANK_API_KEY_ENV="${RERANK_API_KEY:-$API_KEY}" \
        PROBE_RESULT_ENV="$PROBE_RESULT" API_BASE_URL_ENV="$API_BASE_URL" API_KEY_ENV="$API_KEY" EMBEDDING_MODEL_ENV="${EMBEDDING_MODEL:-unknown}" \
        node -e "
        const result = {
          baseURL: process.env.API_BASE_URL_ENV,
          embedding: {
            available: true,
            model: process.env.EMBEDDING_MODEL_ENV,
            dimensions: 1024,
            apiKey: process.env.API_KEY_ENV,
            baseURL: process.env.API_BASE_URL_ENV,
            taskQuery: null,
            taskPassage: null,
            normalized: false,
          },
          rerank: {
            available: process.env.HAS_RERANK_ENV === 'true',
            reason: 'no probe data',
            model: process.env.RERANK_MODEL_ENV || '',
            endpoint: process.env.RERANK_ENDPOINT_ENV || '',
            provider: process.env.RERANK_PROVIDER_ENV || 'jina',
            apiKey: process.env.RERANK_API_KEY_ENV || '',
          },
        };
        require('fs').writeFileSync(process.env.PROBE_RESULT_ENV, JSON.stringify(result, null, 2));
      " || warn "临时探测文件写入失败 / Failed to write temp probe file."
      CONFIG_JSON=$(gen_config_from_probe "$PROBE_RESULT" "$TEMPLATE") || {
        warn "配置生成失败 / Config generation failed."
        CONFIG_JSON='{}'
      }
    fi
  fi

  success "配置已生成 / Config generated (level: ${TEMPLATE})"

  # ── 第 8 步：克隆插件 ──
  echo ""
  info "第 8 步：下载插件 / Downloading plugin..."
  # 全新安装时如果没指定 --ref 且第 2.5 步没执行（目录不存在），给默认值
  [[ -z "$PLUGIN_REF" ]] && PLUGIN_REF="master"
  echo "  repo: $GITHUB_URL"
  echo "  ref : $PLUGIN_REF"

  if [[ -d "$PLUGIN_DIR" ]]; then
    # 已有目录（git 更新已在第 2.5 步完成，npm 用户自己管）
    success "插件目录已存在，跳过下载 / Plugin dir exists, skipping download: $PLUGIN_DIR"
  elif $DRY_RUN; then
    dry "git clone --branch $PLUGIN_REF --depth 1 $GITHUB_URL $PLUGIN_DIR"
  else
    mkdir -p "$(dirname "$PLUGIN_DIR")"
    info "正在下载，请稍候 / Downloading, please wait..."
    if ! git clone --branch "$PLUGIN_REF" --depth 1 --quiet "$GITHUB_URL" "$PLUGIN_DIR" 2>&1; then
      warn "GitHub clone 失败，尝试镜像 / GitHub failed, trying mirror..."
      git clone --branch "$PLUGIN_REF" --depth 1 --quiet "https://ghproxy.com/$GITHUB_URL" "$PLUGIN_DIR" \
        || fail "镜像也失败 / Mirror also failed. Download zip manually to $PLUGIN_DIR and re-run."
    fi
    INSTALLED_REF=$(git -C "$PLUGIN_DIR" rev-parse --short HEAD 2>/dev/null || echo "$PLUGIN_REF")
    success "插件下载完成 / Plugin downloaded (ref: $PLUGIN_REF, HEAD: $INSTALLED_REF)"
  fi

  # ── 第 9 步：安装依赖 ──
  echo ""
  info "第 9 步：安装依赖 / Installing dependencies..."

  if $DRY_RUN; then
    dry "cd $PLUGIN_DIR && npm install"
  elif [[ -d "$PLUGIN_DIR/node_modules" ]] && [[ -n "${OLD_HEAD:-}" ]] && [[ "${OLD_HEAD:-}" == "${INSTALLED_REF:-}" ]]; then
    warn "node_modules 已存在且版本未变，跳过 / node_modules exists and version unchanged, skipping."
  else
    info "正在安装依赖 / Installing dependencies..."
    if ! (cd "$PLUGIN_DIR" && npm install --loglevel=warn 2>&1); then
      warn "默认源失败，切换镜像 / Default registry failed, trying mirror..."
      (cd "$PLUGIN_DIR" && npm install --loglevel=warn --registry https://registry.npmmirror.com 2>&1) \
        || fail "npm install 失败 / npm install failed. Run manually: cd $PLUGIN_DIR && npm install --registry https://registry.npmmirror.com"
    fi
    success "依赖安装完成 / Dependencies installed"
  fi

  # ── 第 9.5 步：Schema 动态过滤 ──

  if ! $DRY_RUN && [[ -f "$PLUGIN_MANIFEST" ]]; then
    # 过滤前校验
    if ! CONFIG_JSON_ENV="$CONFIG_JSON" node -e 'JSON.parse(process.env.CONFIG_JSON_ENV)' >/dev/null 2>&1; then
      fail "生成的配置不是合法 JSON（过滤前）/ Generated config is not valid JSON (pre-filter)."
    fi

    FILTER_RESULT_JSON=$(filter_config_by_schema "$CONFIG_JSON" "$PLUGIN_MANIFEST") || true
    if [[ -n "$FILTER_RESULT_JSON" ]]; then
      CONFIG_JSON=$(FILTER_RESULT_JSON_ENV="$FILTER_RESULT_JSON" node -e \
        "const d=JSON.parse(process.env.FILTER_RESULT_JSON_ENV);process.stdout.write(JSON.stringify(d.filtered,null,2));")
      REMOVED_KEYS=$(FILTER_RESULT_JSON_ENV="$FILTER_RESULT_JSON" node -e \
        "const d=JSON.parse(process.env.FILTER_RESULT_JSON_ENV);const r=d.removed||[];if(r.length)console.log(r.join(', '));" 2>/dev/null || echo "")
      if [[ -n "$REMOVED_KEYS" ]]; then
        warn "根据插件 schema 自动移除了不支持的字段 / Removed unsupported fields: $REMOVED_KEYS"
      else
        success "Schema 校验通过，所有字段合法 / All fields valid"
      fi

      # 过滤后校验
      if ! CONFIG_JSON_ENV="$CONFIG_JSON" node -e 'JSON.parse(process.env.CONFIG_JSON_ENV)' >/dev/null 2>&1; then
        fail "schema 过滤后配置不是合法 JSON / Config is not valid JSON after schema filter."
      fi
    else
      warn "Schema 过滤执行失败，跳过过滤，使用原始配置 / Schema filter failed, using original config."
    fi
  elif ! $DRY_RUN; then
    warn "未找到插件 manifest（$PLUGIN_MANIFEST），跳过 schema 过滤 / No manifest found, skipping schema filter."
  fi

  # ── 第 10 步：写入 openclaw.json ──
  echo ""
  info "第 10 步：写入 / Step 10: Writing openclaw.json..."

  MERGE_JSON=$(cat <<MERGEOF
{
  "plugins": {
    "load": {
      "paths": ["$PLUGIN_DIR"]
    },
    "allow": ["memory-lancedb-pro"],
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
    dry "将以下配置合并到 / Merge config into $OPENCLAW_JSON:"
    echo "$MERGE_JSON" | head -20
    echo "  ..."
  elif ! $HAS_JQ; then
    echo ""
    echo "======================================================"
    echo "  没有 jq，无法自动合并 / No jq, cannot auto-merge."
    echo "  请手动加入以下内容 / Manually add to ${OPENCLAW_JSON}:"
    echo "======================================================"
    echo ""
    echo "$MERGE_JSON"
    echo ""
    echo "------------------------------------------------------"
    echo "  如果已有 plugins 字段，请合并 / If plugins key exists, merge instead of overwrite."
    echo "  提示 / Tip: Install jq and re-run for full automation."
    echo "    Mac:   brew install jq"
    echo "    Linux: sudo apt install jq"
    echo "------------------------------------------------------"
    echo ""
    read -p "编辑完成后按回车 / Press Enter when done... "
  else
    if [[ ! -f "$OPENCLAW_JSON" ]]; then
      warn "openclaw.json 不存在，将创建 / openclaw.json not found, creating new file."
      echo '{}' > "$OPENCLAW_JSON"
    fi

    if ! jq empty "$OPENCLAW_JSON" 2>/dev/null; then
      fail "openclaw.json 格式错误 / Invalid JSON in openclaw.json. Please fix manually."
    fi

    EXISTING_MEMORY=$(jq -r '.plugins.slots.memory // empty' "$OPENCLAW_JSON" 2>/dev/null || echo "")
    if [[ -n "$EXISTING_MEMORY" && "$EXISTING_MEMORY" != "memory-lancedb-pro" ]]; then
      echo ""
      warn "检测到已有 memory 插件 / Existing memory plugin found: $EXISTING_MEMORY"
      echo ""
      echo "  继续将替换 memory slot 为 memory-lancedb-pro / This will replace the memory slot."
      echo "  原插件配置保留 / Original plugin config will be kept."
      echo ""
      read -p "  要替换吗？/ Replace? (y/n) [n]: " REPLACE
      if [[ "${REPLACE:-n}" != "y" && "${REPLACE:-n}" != "Y" ]]; then
        echo ""
        echo "  已取消 / Cancelled. Config for manual reference:"
        echo ""
        echo "$MERGE_JSON"
        echo ""
        exit 0
      fi
    fi

    BACKUP_FILE="$OPENCLAW_JSON.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$OPENCLAW_JSON" "$BACKUP_FILE"
    success "已备份当前配置 / Current config backed up → $BACKUP_FILE"

    MERGED=$(jq --argjson new "$MERGE_JSON" '
      .plugins //= {} |
      .plugins.load //= {} |
      .plugins.load.paths //= [] |
      .plugins.allow //= [] |
      .plugins.entries //= {} |
      .plugins.slots //= {} |
      .plugins.load.paths = (.plugins.load.paths + $new.plugins.load.paths | unique) |
      .plugins.allow = (.plugins.allow + $new.plugins.allow | unique) |
      .plugins.entries["memory-lancedb-pro"] = $new.plugins.entries["memory-lancedb-pro"] |
      .plugins.slots.memory = $new.plugins.slots.memory
    ' "$OPENCLAW_JSON")

    if echo "$MERGED" | jq empty 2>/dev/null; then
      echo "$MERGED" > "$OPENCLAW_JSON"
      success "openclaw.json 已更新 / openclaw.json updated (original backed up)"
    else
      fail "合并后 JSON 异常，已中止 / Merged JSON invalid, aborted. Backup: $BACKUP_FILE"
    fi
  fi

fi  # end of FRESH_INSTALL block

# ============================================================
#  通用步骤：重启、验证、config validate、配置全景
# ============================================================

# ── 重启 Gateway ──
NEED_GATEWAY_RESTART=true
if ! $FRESH_INSTALL && ! $UPGRADE_DONE && ! ${CONFIG_MISSING:-false}; then
  NEED_GATEWAY_RESTART=false
fi

if $NEED_GATEWAY_RESTART; then
  echo ""
  info "重启 Gateway / Restarting Gateway..."

  if $DRY_RUN; then
    dry "openclaw gateway restart"
  else
    RESTART_OUT=$(openclaw gateway restart 2>&1) || true
    if echo "$RESTART_OUT" | grep -qiE 'disabled|unavailable|not found|error|failed'; then
      echo "$RESTART_OUT"
      warn "Gateway 未能正常重启 / Gateway restart may have failed."
      echo "    容器内请手动前台启动 / In containers, start in foreground:"
      echo "    openclaw gateway start --foreground"
    else
      echo "$RESTART_OUT"
      success "Gateway 重启完成 / Gateway restarted"
    fi
  fi
fi

# ── 验证 ──
echo ""
info "确认插件运行状态 / Verifying plugin status..."

if $DRY_RUN; then
  dry "openclaw plugins info memory-lancedb-pro"
  dry "openclaw config get plugins.slots.memory"
  dry "openclaw memory-pro stats"
  dry "node $VALIDATE_SCRIPT"
  echo ""
  success "DRY-RUN 完成 / DRY-RUN done. Remove --dry-run to run for real."
  exit 0
fi

PASS=0
TOTAL=3

echo ""
echo "--- 检查 1/3：插件是否加载 / Plugin loaded? ---"
if openclaw plugins info memory-lancedb-pro 2>&1; then
  success "插件已加载 / Plugin loaded"
  PASS=$((PASS + 1))
else
  warn "插件加载可能有问题 / Plugin may not be loaded correctly"
fi

echo ""
echo "--- 检查 2/3：memory slot ---"
SLOT=$(openclaw config get plugins.slots.memory 2>/dev/null || echo "")
if [[ "$SLOT" == *"memory-lancedb-pro"* ]]; then
  success "memory slot → memory-lancedb-pro"
  PASS=$((PASS + 1))
else
  warn "memory slot 未正确配置 / memory slot misconfigured, current: $SLOT"
fi

echo ""
echo "--- 检查 3/3：记忆库状态 / Memory store status ---"
if openclaw memory-pro stats 2>&1; then
  success "记忆库正常 / Memory store OK"
  PASS=$((PASS + 1))
else
  if $FRESH_INSTALL; then
    info "记忆库尚未初始化（正常）/ Memory store not initialized yet (normal, auto-created after first chat)"
    PASS=$((PASS + 1))
  else
    warn "记忆库状态检查失败 / Memory store check failed"
  fi
fi

# ── 结果汇报 ──
echo ""
echo "======================================================"
if [[ "$PASS" -eq "$TOTAL" ]]; then
  if $FRESH_INSTALL; then
    echo -e "${GREEN}${BOLD}  全部通过 / All passed (${PASS}/${TOTAL})! 安装完成 / Install complete!${NC}"
  elif $UPGRADE_DONE; then
    echo -e "${GREEN}${BOLD}  全部通过 / All passed (${PASS}/${TOTAL})! 升级完成 / Upgrade complete!${NC}"
  else
    echo -e "${GREEN}${BOLD}  全部通过 / All passed (${PASS}/${TOTAL})! 插件运行正常 / Plugin running OK.${NC}"
    if ! $FRESH_INSTALL; then
      echo -e "  当前版本 / Current version: v$LOCAL_VER"
    fi
  fi
else
  echo -e "${YELLOW}${BOLD}  $PASS/$TOTAL 通过 / passed${NC}"
  echo ""
  echo "  请检查上方未通过的项目 / Check failed items above."
  echo ""
  if [[ -n "${BACKUP_FILE:-}" ]]; then
    echo "  如需还原 / To restore: cp $BACKUP_FILE $OPENCLAW_JSON"
  fi
fi
echo "======================================================"
echo ""

# ============================================================
#  Config Validate（v3.0 新增）
# ============================================================
if [[ "$PASS" -eq "$TOTAL" ]] && ! $DRY_RUN && [[ -f "$VALIDATE_SCRIPT" ]]; then
  echo ""
  info "配置校验 / Config Validation..."
  node "$VALIDATE_SCRIPT" 2>/dev/null || warn "配置校验发现问题 / Config validation found issues. Check output above."
fi

# ============================================================
#  配置全景 + 可选功能
# ============================================================
if [[ "$PASS" -eq "$TOTAL" ]] && ! $DRY_RUN; then
  echo ""
  info "配置全景 / Full Configuration Overview"
  echo ""

  CFG_PATH='.plugins.entries["memory-lancedb-pro"].config'

  if $HAS_JQ && [[ -f "$OPENCLAW_JSON" ]]; then
    # 读取所有配置值
    AUTO_CAPTURE=$(jq -r "$CFG_PATH.autoCapture // false" "$OPENCLAW_JSON" 2>/dev/null)
    AUTO_RECALL=$(jq -r "$CFG_PATH.autoRecall // false" "$OPENCLAW_JSON" 2>/dev/null)
    AUTO_RECALL_MIN_LEN=$(jq -r "$CFG_PATH.autoRecallMinLength // \"N/A\"" "$OPENCLAW_JSON" 2>/dev/null)
    AUTO_RECALL_TOP_K=$(jq -r "$CFG_PATH.autoRecallTopK // \"N/A\"" "$OPENCLAW_JSON" 2>/dev/null)
    AUTO_RECALL_MAX_AGE=$(jq -r "$CFG_PATH.autoRecallMaxAgeDays // \"N/A\"" "$OPENCLAW_JSON" 2>/dev/null)
    SESSION_STRATEGY=$(jq -r "$CFG_PATH.sessionStrategy // \"systemSessionMemory\"" "$OPENCLAW_JSON" 2>/dev/null)
    RERANK_MODE=$(jq -r "$CFG_PATH.retrieval.rerank // \"none\"" "$OPENCLAW_JSON" 2>/dev/null)
    MD_MIRROR=$(jq -r "$CFG_PATH.mdMirror.enabled // false" "$OPENCLAW_JSON" 2>/dev/null)
    MIN_SCORE=$(jq -r "$CFG_PATH.retrieval.minScore // \"N/A\"" "$OPENCLAW_JSON" 2>/dev/null)
    HARD_MIN_SCORE=$(jq -r "$CFG_PATH.retrieval.hardMinScore // \"N/A\"" "$OPENCLAW_JSON" 2>/dev/null)
    FILTER_NOISE=$(jq -r "$CFG_PATH.retrieval.filterNoise // false" "$OPENCLAW_JSON" 2>/dev/null)
    CANDIDATE_POOL=$(jq -r "$CFG_PATH.retrieval.candidatePoolSize // \"N/A\"" "$OPENCLAW_JSON" 2>/dev/null)
    RETRIEVAL_MODE=$(jq -r "$CFG_PATH.retrieval.mode // \"N/A\"" "$OPENCLAW_JSON" 2>/dev/null)

    # embedding 信息
    EMB_MODEL=$(jq -r "$CFG_PATH.embedding.model // \"N/A\"" "$OPENCLAW_JSON" 2>/dev/null)
    EMB_BASE_URL=$(jq -r "$CFG_PATH.embedding.baseURL // \"N/A\"" "$OPENCLAW_JSON" 2>/dev/null)
    EMB_DIM=$(jq -r "$CFG_PATH.embedding.dimensions // \"N/A\"" "$OPENCLAW_JSON" 2>/dev/null)

    # API Key 状态
    JINA_KEY_VAL=$(jq -r "$CFG_PATH.embedding.apiKey // \"\"" "$OPENCLAW_JSON" 2>/dev/null)
    if [[ -n "$JINA_KEY_VAL" && "$JINA_KEY_VAL" != "YOUR_JINA_API_KEY" && "$JINA_KEY_VAL" != "YOUR_API_KEY" ]]; then
      KEY_STATUS="${GREEN}已配置 / Configured${NC}"
    else
      KEY_STATUS="${YELLOW}未配置（占位符）/ Not configured (placeholder)${NC}"
    fi

    # ── 展示全景 ──
    echo -e "  ${BOLD}版本 / Version:${NC}      v$LOCAL_VER"
    echo -e "  ${BOLD}API Key:${NC}             $KEY_STATUS"
    echo -e "  ${BOLD}Embedding Model:${NC}     $EMB_MODEL ($EMB_BASE_URL, ${EMB_DIM}d)"
    echo ""

    echo -e "  ${BOLD}── 存储 / Storage ──${NC}"
    if [[ "$AUTO_CAPTURE" == "true" ]]; then
      show_feature on "autoCapture" "自动存储 / Auto store"
    else
      show_feature off "autoCapture" "自动存储 / Auto store"
    fi
    if [[ "$MD_MIRROR" == "true" ]]; then
      show_feature on "mdMirror" "可读 .md 备份 / Readable .md backup"
    else
      show_feature off "mdMirror" "可读 .md 备份 / Readable .md backup"
    fi

    echo ""
    echo -e "  ${BOLD}── 召回 / Recall ──${NC}"
    if [[ "$AUTO_RECALL" == "true" ]]; then
      show_feature on "autoRecall" "自动召回 / Auto recall" "minLength=$AUTO_RECALL_MIN_LEN, topK=$AUTO_RECALL_TOP_K, maxAge=${AUTO_RECALL_MAX_AGE}d"
    else
      show_feature off "autoRecall" "自动召回 / Auto recall"
    fi
    if [[ "$SESSION_STRATEGY" == "memoryReflection" ]]; then
      show_feature on "Reflection" "智能提炼 / Smart extraction"
    else
      show_feature off "Reflection" "智能提炼 / Smart extraction (currently: basic storage)"
    fi

    echo ""
    echo -e "  ${BOLD}── 检索 / Retrieval ──${NC}"
    if [[ "$RERANK_MODE" != "none" ]]; then
      show_feature on "rerank" "精排 / Reranking" "mode=$RERANK_MODE"
    else
      show_feature off "rerank" "精排 / Reranking"
    fi
    if [[ "$FILTER_NOISE" == "true" ]]; then
      show_feature on "filterNoise" "噪声过滤 / Noise filter"
    else
      show_feature off "filterNoise" "噪声过滤 / Noise filter"
    fi
    echo -e "        retrievalMode       = $RETRIEVAL_MODE"
    echo -e "        candidatePoolSize   = $CANDIDATE_POOL"
    echo -e "        minScore            = $MIN_SCORE"
    echo -e "        hardMinScore        = $HARD_MIN_SCORE"

    # ── 动态可选功能 ──
    echo ""
    OPTIONS=()
    OPTION_KEYS=()
    OPTION_LABELS=()
    n=0

    # 检查 schema 是否支持某个字段（不支持就不提供该选项）
    schema_has_field() {
      local field="$1"
      [[ -f "$PLUGIN_MANIFEST" ]] || return 0  # 没 manifest 就假设支持
      MANIFEST_ENV="$PLUGIN_MANIFEST" FIELD_ENV="$field" node -e "
        const m = JSON.parse(require('fs').readFileSync(process.env.MANIFEST_ENV,'utf8'));
        const props = m.configSchema?.properties || {};
        process.exit(props.hasOwnProperty(process.env.FIELD_ENV) ? 0 : 1);
      " 2>/dev/null
    }

    if [[ "$AUTO_CAPTURE" != "true" ]] && schema_has_field "autoCapture"; then
      n=$((n+1)); OPTION_KEYS+=("autoCapture")
      OPTION_LABELS+=("$n) autoCapture    — 开启自动存储 / Enable auto store")
    fi
    if [[ "$AUTO_RECALL" != "true" ]] && schema_has_field "autoRecall"; then
      n=$((n+1)); OPTION_KEYS+=("autoRecall")
      OPTION_LABELS+=("$n) autoRecall     — 开启自动召回 / Enable auto recall in new chats")
    fi
    if [[ "$SESSION_STRATEGY" != "memoryReflection" ]] && schema_has_field "sessionStrategy"; then
      n=$((n+1)); OPTION_KEYS+=("reflection")
      OPTION_LABELS+=("$n) Reflection     — 智能提炼 / Smart extraction (~500-1000 extra tokens/turn)")
    fi
    if [[ "$RERANK_MODE" == "none" ]]; then
      n=$((n+1)); OPTION_KEYS+=("rerank")
      OPTION_LABELS+=("$n) rerank         — 精排 / Enable reranking")
    fi
    if [[ "$MD_MIRROR" != "true" ]] && schema_has_field "mdMirror"; then
      n=$((n+1)); OPTION_KEYS+=("mdMirror")
      OPTION_LABELS+=("$n) mdMirror       — 可读 .md 备份 / Enable .md mirror")
    fi

    if [[ $n -eq 0 ]]; then
      echo -e "  ${GREEN}所有功能已开启，无需调整 / All features enabled, no changes needed.${NC}"
    else
      echo -e "  ${BOLD}可选开启 / Available to enable (space-separated, Enter to skip):${NC}"
      echo ""
      for label in "${OPTION_LABELS[@]}"; do
        echo "    $label"
      done
      echo ""
      read -p "  输入编号 / Enter numbers (e.g. 1 2 or 1,2), Enter to skip: " UPGRADE_INPUT

      # 只按空格/逗号/中文逗号分割，不拆连续数字（防止 12 变成 1 2）
      UPGRADE_INPUT=$(echo "$UPGRADE_INPUT" | tr '，,' ' ' | tr -s ' ' | sed 's/^ *//;s/ *$//')

      if [[ -n "$UPGRADE_INPUT" ]]; then
        NEED_RESTART=false

        for choice in $UPGRADE_INPUT; do
          if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            warn "请输入数字 / Please enter a number, got: $choice"
            continue
          fi

          if [[ "$choice" -lt 1 || "$choice" -gt $n ]]; then
            warn "选项超出范围 / Option $choice out of range (1-$n)"
            continue
          fi

          local_key="${OPTION_KEYS[$((choice-1))]}"

          case "$local_key" in
            autoCapture)
              if jq_safe_write "$CFG_PATH.autoCapture = true" "$OPENCLAW_JSON"; then
                success "autoCapture enabled / 已开启自动存储"
                NEED_RESTART=true
              else
                warn "autoCapture 写入失败 / Failed"
              fi
              ;;
            autoRecall)
              if jq_safe_write "
                $CFG_PATH.autoRecall = true |
                $CFG_PATH.autoRecallMinLength = ($CFG_PATH.autoRecallMinLength // 8) |
                $CFG_PATH.autoRecallTopK = ($CFG_PATH.autoRecallTopK // 3) |
                $CFG_PATH.autoRecallMaxAgeDays = ($CFG_PATH.autoRecallMaxAgeDays // 30)
              " "$OPENCLAW_JSON"; then
                success "autoRecall enabled / 已开启自动召回"
                NEED_RESTART=true
              else
                warn "autoRecall 写入失败 / Failed"
              fi
              ;;
            reflection)
              if jq_safe_write "$CFG_PATH.sessionStrategy = \"memoryReflection\"" "$OPENCLAW_JSON"; then
                success "memoryReflection enabled / 已开启智能提炼"
                echo "    每轮多一次 AI 调用 / Extra AI call per turn for distillation."
                NEED_RESTART=true
              else
                warn "memoryReflection 写入失败 / Failed"
              fi
              ;;
            rerank)
              RERANK_KEY_VAL=$(jq -r "$CFG_PATH.embedding.apiKey // \"\"" "$OPENCLAW_JSON" 2>/dev/null)
              EMBED_BASE_URL=$(jq -r "$CFG_PATH.embedding.baseURL // \"\"" "$OPENCLAW_JSON" 2>/dev/null)
              # 根据 embedding provider 确定 rerank 端点 / Detect rerank endpoint from embedding provider
              RERANK_EP="https://api.jina.ai/v1/rerank"
              RERANK_MDL="jina-reranker-v3"
              RERANK_PROV="jina"
              if [[ "$EMBED_BASE_URL" == *"dashscope"* ]]; then
                RERANK_EP="https://dashscope.aliyuncs.com/compatible-api/v1/reranks"
                RERANK_MDL="qwen3-rerank"
                RERANK_PROV="jina"  # DashScope rerank 响应格式兼容 Jina / DashScope rerank is Jina-compatible
              fi
              # Ollama / 本地模型没有在线 rerank 能力
              if [[ "$RERANK_KEY_VAL" == "ollama" || "$EMBED_BASE_URL" == *":11434"* ]]; then
                warn "rerank 需要在线 API（如 Jina），Ollama 本地模型不支持 / Rerank requires an online API (e.g. Jina). Ollama doesn't support rerank."
                echo "    如需使用 rerank，请先注册 Jina（免费）获取 API Key / To use rerank, get a free Jina API Key: https://jina.ai/"
                echo ""
                read -p "    输入 Jina API Key（直接回车跳过 rerank）/ Paste Jina API Key (Enter to skip): " RERANK_JINA_KEY
                if [[ -n "$RERANK_JINA_KEY" ]]; then
                  RERANK_KEY_VAL="$RERANK_JINA_KEY"
                else
                  info "跳过 rerank / Skipping rerank"
                  continue
                fi
              elif [[ -z "$RERANK_KEY_VAL" || "$RERANK_KEY_VAL" == "YOUR_JINA_API_KEY" || "$RERANK_KEY_VAL" == "YOUR_API_KEY" ]]; then
                warn "rerank 需要 API Key，请先配置 / Rerank requires API Key"
                continue
              fi
              # 使用 --arg 传递 API key，避免特殊字符注入 jq 表达式
              # Pass API key via --arg to avoid special-char injection in jq expression
              if jq_safe_write \
                --arg rkey "$RERANK_KEY_VAL" \
                --arg rep  "$RERANK_EP" \
                --arg rmdl "$RERANK_MDL" \
                --arg rprov "$RERANK_PROV" \
                "
                  $CFG_PATH.retrieval.rerank = \"cross-encoder\" |
                  $CFG_PATH.retrieval.rerankApiKey = \$rkey |
                  $CFG_PATH.retrieval.rerankModel = \$rmdl |
                  $CFG_PATH.retrieval.rerankEndpoint = \$rep |
                  $CFG_PATH.retrieval.rerankProvider = \$rprov |
                  $CFG_PATH.retrieval.hardMinScore = 0.35
                " "$OPENCLAW_JSON"; then
                success "rerank enabled / 已开启精排"
                NEED_RESTART=true
              else
                warn "rerank 写入失败 / Failed"
              fi
              ;;
            mdMirror)
              if jq_safe_write "$CFG_PATH.mdMirror = {\"enabled\": true, \"dir\": \"memory-md\"}" "$OPENCLAW_JSON"; then
                success "mdMirror enabled / 已开启 .md 备份"
                NEED_RESTART=true
              else
                warn "mdMirror 写入失败 / Failed"
              fi
              ;;
          esac
        done

        if $NEED_RESTART; then
          # v3.3: 可选功能写入后再跑一次 schema 过滤，防止写入了插件不认的字段
          if [[ -f "$PLUGIN_MANIFEST" ]]; then
            CURRENT_CFG=$(jq -r "$CFG_PATH" "$OPENCLAW_JSON" 2>/dev/null)
            if [[ -n "$CURRENT_CFG" && "$CURRENT_CFG" != "null" ]]; then
              POST_FILTER=$(filter_config_by_schema "$CURRENT_CFG" "$PLUGIN_MANIFEST") || true
              if [[ -n "$POST_FILTER" ]]; then
                POST_REMOVED=$(echo "$POST_FILTER" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));const r=d.removed||[];if(r.length)console.log(r.join(', '));" 2>/dev/null || echo "")
                if [[ -n "$POST_REMOVED" ]]; then
                  warn "根据插件 schema 自动移除了不支持的字段 / Removed unsupported fields: $POST_REMOVED"
                  POST_FILTERED_CFG=$(echo "$POST_FILTER" | node -e "const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));process.stdout.write(JSON.stringify(d.filtered,null,2));" 2>/dev/null)
                  if [[ -n "$POST_FILTERED_CFG" ]]; then
                    jq_safe_write "$CFG_PATH = $POST_FILTERED_CFG" "$OPENCLAW_JSON" \
                      && success "配置已清理 / Config cleaned" \
                      || warn "schema 过滤写回失败 / Schema filter write-back failed"
                  fi
                fi
              fi
            fi
          fi

          echo ""
          info "配置已更新，重启 Gateway / Config updated, restarting Gateway..."
          RESTART_OUT2=$(openclaw gateway restart 2>&1) || true
          if echo "$RESTART_OUT2" | grep -qiE 'disabled|unavailable|not found|error|failed'; then
            echo "$RESTART_OUT2"
            warn "Gateway 未能正常重启 / Gateway restart may have failed."
            echo "    容器内请手动前台启动 / In containers, start in foreground:"
            echo "    openclaw gateway start --foreground"
          else
            echo "$RESTART_OUT2"
            success "Gateway 重启完成 / Gateway restarted."
          fi
        else
          echo ""
          info "没有选中有效功能，配置未改动 / No valid options selected, config unchanged."
        fi
      else
        echo ""
        success "保持当前配置 / Keeping current config."
      fi
    fi

  else
    if ! $HAS_JQ; then
      warn "没有 jq，无法读取配置全景 / No jq, cannot display config overview. Install jq and re-run."
      echo "    Mac: brew install jq  |  Linux: sudo apt install jq"
    fi

    if $FRESH_INSTALL; then
      echo -e "  ${BOLD}已选等级 / Level: ${TEMPLATE:-unknown}${NC}"
      echo ""
      echo "  现在试试对你的 Agent 说 / Try telling your Agent:"
      echo ""
      echo "    「记住：我喜欢冷萃咖啡，不喜欢太甜。」"
      echo ""
      echo "  然后在新对话里问 / Then in a new chat, ask:"
      echo "    「我平时喝什么咖啡？」"
    fi
  fi

  # ── 提示下次升级 ──
  echo ""
  echo -e "  ${BOLD}之后升级 / Future upgrades:${NC}"
  echo "    bash setup-memory.sh          # 检查稳定版更新 / Check for stable updates"
  echo "    bash setup-memory.sh --beta   # 包含 beta 版本 / Include beta versions"
fi
