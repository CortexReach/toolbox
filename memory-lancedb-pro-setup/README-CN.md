# memory-lancedb-pro 一键安装脚本

[memory-lancedb-pro](https://github.com/CortexReach/memory-lancedb-pro) 插件的一键安装脚本，对新手友好，一个命令搞定所有事。

> **[English →](README.md)**

## 快速开始

```bash
# 下载并运行
curl -fsSL https://raw.githubusercontent.com/CortexReach/toolbox/main/memory-lancedb-pro-setup/setup-memory.sh -o setup-memory.sh
bash setup-memory.sh
```

或者 clone 整个仓库：

```bash
git clone https://github.com/CortexReach/toolbox.git
cd toolbox/memory-lancedb-pro-setup
bash setup-memory.sh
```

## 不管你是什么情况，跑一个命令就行

| 你的情况 | 脚本做什么 |
|---|---|
| 啥都没装过 | 全新下载 → 装依赖 → 选配置 → 写入 → 重启 |
| 之前 git clone 装的，停在旧版本 | 自动 fetch + checkout 到最新 → 重装依赖 → 检查 |
| npm 装的 | 跳过 git 更新，提示你 `npm update` |
| 已是最新 | 只跑健康检查，不改任何东西 |
| 配置有非法字段 | 按插件 schema 自动裁掉，初始写入和可选功能开启后都会过滤 |
| openclaw CLI 因配置损坏无法使用 | 兜底：直接从 JSON 文件读 workspace |
| 不知道默认分支叫 main 还是 master | 自动检测 |
| 插件装在 extensions/ 而不是 plugins/ | 自动探测 |

## 用法

```bash
bash setup-memory.sh                    # 安装或升级
bash setup-memory.sh --dry-run          # 只预览不执行
bash setup-memory.sh --beta             # 包含 beta 版本
bash setup-memory.sh --ref v1.2.0       # 锁定到指定版本
bash setup-memory.sh --selfcheck-only   # 只跑能力自检
bash setup-memory.sh --uninstall        # 还原配置并移除插件
```

## 执行流程

```
bash setup-memory.sh
 │
 ├─ 第 1 步    环境检查（node、openclaw、jq）
 ├─ 第 2 步    确认 workspace 路径（三级兜底）
 ├─ 第 2.5 步  Git 自动更新（fetch + checkout + pull）
 ├─ 第 3 步    检测已安装版本
 ├─ 第 4 步    对比远程版本，提供升级
 │
 │  ── 仅全新安装 ──
 ├─ 第 5-7 步  选择 API 服务商 + 配置等级
 ├─ 第 8 步    下载插件（--branch $ref --depth 1）
 ├─ 第 9 步    npm install
 ├─ 第 9.5 步  Schema 过滤（移除不支持的字段）
 ├─ 第 10 步   写入 openclaw.json（安全深度合并）
 │
 │  ── 所有用户 ──
 ├─ 重启 Gateway
 ├─ 健康检查（3/3）
 └─ 配置全景 + 可选功能开关
```

## 核心特性

- **Schema 过滤** — 初始写入和可选功能开启后都会自动裁掉插件不认的字段，彻底告别 `additional properties` 报错
- **Git 自动更新** — 已有 git 仓库自动 fetch + checkout 到最新，自动检测 `main` 还是 `master`
- **版本锁定** — `--ref v1.2.0` 锁定到指定版本
- **Workspace 兜底** — 即使 `openclaw` CLI 因配置损坏无法使用也能跑
- **插件路径探测** — 自动在 `extensions/`、`plugins/` 或自定义目录里找到你的插件
- **多服务商** — 内置 Jina / 阿里云 DashScope / SiliconFlow / OpenAI / Ollama 快捷入口，也支持任意 OpenAI 兼容 API

## 文件说明

| 文件 | 说明 |
|------|------|
| `setup-memory.sh` | 主安装脚本（v3.4） |
| `scripts/memory-selfcheck.mjs` | 能力自检（embedding 和 rerank 探测） |
| `scripts/probe-endpoint.mjs` | 通用 OpenAI 兼容 API 端口探测（v3.0+） |
| `scripts/config-validate.mjs` | 安装后配置字段校验（v3.0+） |
| `selfcheck.example.json` | 自检配置示例 |

## 环境要求

- Node.js v18+
- OpenClaw CLI 已安装
- jq（可选 — 有 jq 才能自动合并配置，没有的话手动编辑）

## 已测试环境

| 系统 | 终端 | 结果 |
|------|------|------|
| Linux (Docker arm64) | OpenClaw 容器 | 通过 |
| macOS | Terminal / iTerm2 | 通过 |
| Windows WSL | Windows Terminal | 通过 |

## 更新日志

### v3.4（2026-03-15）
- 安全：`eval` tilde 展开改为纯参数替换，防命令注入
- 安全：`node -e` 文件路径改用环境变量传入，防路径注入
- 安全：rerank API key 改用 `jq --arg` 传入，防特殊字符注入
- 新增 `plugins.allow` 白名单（修复 git-clone 插件 "plugin not found"）
- DashScope embedding 用户自动检测 rerank 端点（qwen3-rerank）
- 分支检测优化：`git fetch --prune` 清理残留远程分支，fallback 硬编码 `master`
- 修复：版本展示从 git 远程分支读真实版本（之前 tags API 和实际安装版本不一致）
- 修复：changelog 非 beta 模式过滤 beta 版本；目标版本是 beta 时自动包含 beta
- 修复：Gateway 重启假阳性——检测输出中的 `disabled`/`unavailable`，容器环境正确提示
- 修复：升级路径 `PLUGIN_MANIFEST` 未定义导致崩溃
- 修复：`filter_config_by_schema` 提到全局作用域（之前只在全新安装块里定义，升级路径 schema 过滤失效）
- 修复：checkout 前 `git stash`，防止 `package-lock.json` 本地改动挡住分支切换
- 新增：启动时自动修复非法配置字段（打破 additional properties 导致的重启循环）
- 新增：无 jq 强提示——列出影响，默认退出引导安装 jq
- 新增：`schema_has_field` 守门——可选功能只展示当前插件 schema 支持的选项

### v3.3（2026-03-14）
- 修复：可选功能（autoRecall/reflection/rerank/mdMirror）写入后、Gateway 重启前再跑一次 schema 过滤，防止绕过 v3.1 的初始过滤
- Ollama/本地模型用户选 rerank 时提示需要在线 API Key（之前会把 `"ollama"` 写成 rerankApiKey）

### v3.2（2026-03-14）
- Git 自动更新：已有 git 仓库自动 `fetch` + `checkout` 到目标 ref
- 自动检测远程默认分支（`main` 还是 `master`）
- openclaw CLI 因配置损坏无法使用时的 workspace 兜底
- HEAD 变化后自动重装依赖

### v3.1（2026-03-14）
- `--ref` 参数：锁定 clone 到指定 tag/branch/commit
- Schema 动态过滤：写入配置前自动裁剪非法字段
- 过滤前后双重 JSON 校验

### v3.0（2026-03-14）
- 通用端口探测：支持任意 OpenAI 兼容 API
- 快捷入口：Jina / 阿里云 DashScope / SiliconFlow / OpenAI / Ollama
- 安装后配置校验（`config-validate.mjs`）
- 动态配置生成（替代硬编码模板）
- 插件路径自动探测（`extensions/` / `plugins/` / 自定义目录）

### v2.0（2026-03-14）
- 升级路径：版本对比 + 一键升级 + 失败自动回滚
- 配置全景：从 `openclaw.json` 实际读取并展示
- 20+ 项小白防护改进

### v1.3（2026-03-14）
- 功能知情：安装后展示 ON/OFF 状态
- 可选升级：交互式开启高级功能

### v1.2（2026-03-13）
- 修复：mktemp macOS 兼容性

### v1.1（2026-03-13）
- 修复：插件路径从相对路径改为绝对路径
