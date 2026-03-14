# memory-lancedb-pro Setup Script

One-click installer for the [memory-lancedb-pro](https://github.com/CortexReach/memory-lancedb-pro) plugin.

> [memory-lancedb-pro](https://github.com/CortexReach/memory-lancedb-pro) 插件的一键安装脚本，小白友好。

## Quick Start

```bash
# Download and run
curl -fsSL https://raw.githubusercontent.com/CortexReach/toolbox/main/memory-lancedb-pro-setup/setup-memory.sh -o setup-memory.sh
bash setup-memory.sh
```

Or clone the whole repo:

```bash
git clone https://github.com/CortexReach/toolbox.git
cd toolbox/memory-lancedb-pro-setup
bash setup-memory.sh
```

## Usage

```bash
bash setup-memory.sh              # Normal install / 正常安装
bash setup-memory.sh --dry-run    # Preview only, no changes / 只预览不执行
bash setup-memory.sh --selfcheck-only  # Run capability check only / 只跑能力自检
bash setup-memory.sh --uninstall  # Revert config and remove plugin / 还原配置并移除插件
```

## What It Does

1. **Environment check** — Node.js, OpenClaw CLI, jq
2. **Workspace detection** — Auto-detect or manual input
3. **Template selection** — Auto-probe or manual pick from 3 profiles:
   - `lite-safe` — Store only, no recall (recommended for beginners / 新手推荐)
   - `balanced-default` — Store + recall, no rerank
   - `pro-rerank` — Store + recall + Jina Reranker
4. **Jina API Key** — Prompt with skip option
5. **Capability self-check** — Test embedding & rerank before committing
6. **Plugin install** — git clone + npm install (with China mirror fallback)
7. **Config merge** — Safe deep-merge into `openclaw.json` (auto-backup)
8. **Verification** — 3 checks to confirm everything works
9. **Feature awareness** — Show what's ON/OFF, optionally enable advanced features

## Feature Awareness (v1.3)

After a successful install, the script shows your current feature status and lets you optionally enable:

- **autoRecall** — Auto search old memories in new chats / 自动召回旧记忆
- **memoryReflection** — AI summarizes key points each turn (costs ~500-1000 extra tokens) / AI 智能提炼

Beginner-proof input handling: `12`, `1,2`, `1，2`, `yes` — all handled gracefully.

## Files

| File | Description |
|------|-------------|
| `setup-memory.sh` | Main installer script (v1.3) |
| `scripts/memory-selfcheck.mjs` | Capability self-check (embedding & rerank probe) |
| `selfcheck.example.json` | Example config for self-check |

## Requirements

- Node.js v18+
- OpenClaw CLI installed
- jq (optional, enables auto config merge; without it you edit manually)

## Tested On

| OS | Terminal | Result |
|----|----------|--------|
| macOS | Terminal / iTerm2 | v1.2+ pass |
| Windows WSL | Windows Terminal | v1.1+ pass |
| Linux | Various | v1.1+ pass |
