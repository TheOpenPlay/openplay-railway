#!/usr/bin/env bash
# Entrypoint for OpenClaw container on Railway.
# - Seeds a minimal workspace if the volume is empty
# - Writes provider config (OpenRouter) from env
# - Launches `openclaw gateway run` in foreground
set -euo pipefail

: "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY is required}"
: "${OPENCLAW_GATEWAY_TOKEN:?OPENCLAW_GATEWAY_TOKEN is required}"

PORT="${PORT:-8080}"
OPENCLAW_CONFIG_DIR="${HOME}/.openclaw"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_DIR}/openclaw.json"
WORKSPACE_DIR="${HOME}"

mkdir -p "${OPENCLAW_CONFIG_DIR}"
mkdir -p "${WORKSPACE_DIR}/memory"

# ---------- Seed a minimal workspace if empty ----------
if [ ! -f "${WORKSPACE_DIR}/AGENTS.md" ]; then
  cat > "${WORKSPACE_DIR}/AGENTS.md" <<'EOF'
# AGENTS.md — The Open Play (Railway)

This is the orchestrator OpenClaw workspace for The Open Play.

## Role
- Tier-1 orchestrator. Ingests campaign intake, decomposes work,
  delegates specialist work to Hermes profiles, QAs, packages.
- Read-only by default: skills live in the GitHub skills repo (Phase 2).
- Writes go through git commits, not loose files.

## Hermes profiles (Tier 2)
- `email-agent`        — tournament email lifecycle
- `tournament-plan-agent` — full marketing plan
- `social-design-agent`   — IG/X + designer briefs

## Persistence
- /workspace is a Railway volume. Treat contents as durable.
- Memory: ~/memory/YYYY-MM-DD.md (create as needed).

EOF
fi

if [ ! -f "${WORKSPACE_DIR}/SOUL.md" ]; then
  cat > "${WORKSPACE_DIR}/SOUL.md" <<'EOF'
# SOUL.md
You are the orchestrator for The Open Play. Terse, competent,
no filler. Delegate specialist work to Hermes profiles via the
openplay-skills repo conventions.
EOF
fi

# ---------- Config file ----------
# Minimal headless config: token auth, LAN bind (Railway exposes via proxy),
# OpenRouter as the default provider, default model Claude Opus 4.7.
if [ ! -f "${OPENCLAW_CONFIG_FILE}" ]; then
  cat > "${OPENCLAW_CONFIG_FILE}" <<EOF
{
  "gateway": {
    "mode": "remote",
    "bind": "lan",
    "auth": "token",
    "port": ${PORT}
  },
  "providers": {
    "openrouter": {
      "apiKey": "${OPENROUTER_API_KEY}"
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "openrouter/anthropic/claude-opus-4.7"
      }
    }
  }
}
EOF
fi

# Refresh the token + API key on every boot so env rotations take effect.
# We use python3 (always available) to patch JSON in place.
python3 - <<PY
import json, os, pathlib
p = pathlib.Path(os.environ["HOME"]) / ".openclaw" / "openclaw.json"
cfg = json.loads(p.read_text())
cfg.setdefault("gateway", {})
cfg["gateway"]["mode"] = "remote"
cfg["gateway"]["bind"] = "lan"
cfg["gateway"]["auth"] = "token"
cfg["gateway"]["port"] = int(os.environ.get("PORT", "8080"))
cfg.setdefault("providers", {}).setdefault("openrouter", {})
cfg["providers"]["openrouter"]["apiKey"] = os.environ["OPENROUTER_API_KEY"]
cfg.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})
cfg["agents"]["defaults"]["model"].setdefault("primary", "openrouter/anthropic/claude-opus-4.7")
p.write_text(json.dumps(cfg, indent=2))
PY

# Write the gateway token to the file OpenClaw expects for --token auth.
# openclaw gateway accepts --token <token>; we pass via env + CLI arg.
export OPENCLAW_GATEWAY_PORT="${PORT}"

echo "[openclaw-entrypoint] HOME=${HOME}"
echo "[openclaw-entrypoint] OPENCLAW_HOME=${OPENCLAW_HOME:-unset}"
echo "[openclaw-entrypoint] port=${PORT} bind=lan auth=token"

exec openclaw gateway run \
  --bind lan \
  --auth token \
  --token "${OPENCLAW_GATEWAY_TOKEN}" \
  --port "${PORT}" \
  --allow-unconfigured
