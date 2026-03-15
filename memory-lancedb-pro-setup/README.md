# memory-lancedb-pro Setup Script

One-click installer for the [memory-lancedb-pro](https://github.com/CortexReach/memory-lancedb-pro) plugin.

> **[中文文档 →](README-CN.md)**

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

## What Problems Does It Solve?

| Your situation | What the script does |
|---|---|
| Never installed | Fresh download → install deps → pick config → write to openclaw.json → restart |
| Installed via `git clone`, stuck on old commit | Auto `git fetch` + `checkout` to latest → reinstall deps → verify |
| Installed via `npm` | Skip git update, remind you to `npm update` yourself |
| Already up to date | Run health checks only, no changes |
| Config has invalid fields | Auto-detect via schema filter, remove unsupported fields (initial + post-toggle) |
| `openclaw` CLI broken due to invalid config | Fallback: read workspace path directly from `openclaw.json` file |
| Don't know if default branch is `main` or `master` | Auto-detect from remote |
| Plugin installed in `extensions/` instead of `plugins/` | Auto-detect from config or `find` |

## Usage

```bash
bash setup-memory.sh                    # Install or upgrade
bash setup-memory.sh --dry-run          # Preview only
bash setup-memory.sh --beta             # Include pre-release versions
bash setup-memory.sh --ref v1.2.0       # Lock to specific version
bash setup-memory.sh --selfcheck-only   # Capability check only
bash setup-memory.sh --uninstall        # Revert config and remove plugin
```

## How It Works

```
bash setup-memory.sh
 │
 ├─ Step 1    Environment check (node, openclaw, jq)
 ├─ Step 2    Detect workspace path (3-level fallback)
 ├─ Step 2.5  Git auto-update (fetch + checkout + pull)
 ├─ Step 3    Detect installed version
 ├─ Step 4    Compare with remote, offer upgrade
 │
 │  ── Fresh install only ──
 ├─ Step 5-7  Choose API provider + config template
 ├─ Step 8    Clone plugin (--branch $ref --depth 1)
 ├─ Step 9    npm install
 ├─ Step 9.5  Schema filter (remove unsupported fields)
 ├─ Step 10   Write to openclaw.json (safe deep-merge)
 │
 │  ── All users ──
 ├─ Restart Gateway
 ├─ Health checks (3/3)
 └─ Config overview + optional feature toggles
```

## Key Features

- **Schema filter** — auto-remove unsupported config fields both on initial write and after toggling optional features, no more `additional properties` errors
- **Git auto-update** — existing git repos auto fetch + checkout to latest, detects `main` vs `master`
- **Version locking** — `--ref v1.2.0` to pin a specific version
- **Workspace fallback** — works even when `openclaw` CLI is broken by invalid config
- **Plugin path detection** — finds your plugin in `extensions/`, `plugins/`, or custom dirs
- **Multi-provider** — presets for Jina / DashScope / SiliconFlow / OpenAI / Ollama, or any OpenAI-compatible API

## Files

| File | Description |
|------|-------------|
| `setup-memory.sh` | Main installer script (v3.4) |
| `scripts/memory-selfcheck.mjs` | Capability self-check (embedding & rerank probe) |
| `scripts/probe-endpoint.mjs` | Universal OpenAI-compatible API endpoint probe (v3.0+) |
| `scripts/config-validate.mjs` | Post-install config field validation (v3.0+) |
| `selfcheck.example.json` | Example config for self-check |

## Requirements

- Node.js v18+
- OpenClaw CLI installed
- jq (optional — enables auto config merge; without it you edit manually)

## Tested On

| OS | Terminal | Result |
|----|----------|--------|
| Linux (Docker arm64) | OpenClaw container | pass |
| macOS | Terminal / iTerm2 | pass |
| Windows WSL | Windows Terminal | pass |

## Changelog

### v3.4 (2026-03-15)
- Security: replace `eval` tilde expansion with safe parameter substitution
- Security: pass file paths to `node -e` via env vars instead of string interpolation
- Security: pass API keys to `jq` via `--arg` instead of direct interpolation
- Add `plugins.allow` whitelist to fix "plugin not found" for git-cloned plugins
- Auto-detect DashScope rerank endpoint when DashScope is the embedding provider
- Branch detection: `git fetch --prune` before detecting, fallback hardcoded to `master`
- Fix: version display now reads from actual git target branch (was showing stale tag)
- Fix: changelog filters out beta versions when not in `--beta` mode; auto-includes beta when target is beta
- Fix: Gateway restart false positive — detect `disabled`/`unavailable` in output for container environments
- Fix: `PLUGIN_MANIFEST` unbound variable crash on upgrade path
- Fix: `filter_config_by_schema` moved to global scope (was only defined in fresh-install block, breaking upgrade-path schema filter)
- Fix: `git stash` before checkout to prevent `package-lock.json` local changes from blocking branch switch
- New: auto-repair invalid config fields on startup (breaks crash loops caused by unsupported fields)
- New: prominent jq warning with opt-out — lists impact of missing jq, default exits to install first
- New: `schema_has_field` guard — optional feature toggles only offer options supported by current plugin schema

### v3.3 (2026-03-14)
- Fix: run schema filter again before gateway restart after optional feature toggles (autoRecall/reflection/rerank/mdMirror wrote fields that bypassed the v3.1 initial filter)
- Ollama/local model users selecting rerank are now prompted for a Jina API Key or can skip (previously wrote `"ollama"` as rerankApiKey which doesn't work)

### v3.2 (2026-03-14)
- Git auto-update: existing git repos auto `fetch` + `checkout` to target ref
- Auto-detect remote default branch (`main` vs `master`)
- Workspace fallback when `openclaw` CLI is broken by invalid config
- npm reinstall when HEAD changes after git update

### v3.1 (2026-03-14)
- `--ref` parameter: lock clone to specific tag/branch/commit
- Schema dynamic filter: remove unsupported config fields before writing
- Pre/post filter JSON validation

### v3.0 (2026-03-14)
- Universal endpoint probe for any OpenAI-compatible API
- Quick-start presets: Jina / DashScope / SiliconFlow / OpenAI / Ollama
- Post-install config validation (`config-validate.mjs`)
- Dynamic config generation (replaces hardcoded templates)
- Plugin path auto-detection (`extensions/` / `plugins/` / custom)

### v2.0 (2026-03-14)
- Upgrade path: version compare + one-click upgrade with rollback
- Config overview: read actual values from `openclaw.json`
- 20+ beginner-proof improvements

### v1.3 (2026-03-14)
- Feature awareness: show ON/OFF status after install
- Optional upgrade: enable advanced features interactively

### v1.2 (2026-03-13)
- Fix: mktemp macOS compatibility

### v1.1 (2026-03-13)
- Fix: plugin path from relative to absolute
