#!/usr/bin/env bash
# Entrypoint for OpenClaw container on Railway.
# - Seeds a minimal workspace if the volume is empty
# - Writes provider config (OpenRouter) from env
# - Launches `openclaw gateway run` in foreground
set -euo pipefail

: "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY is required}"
: "${OPENCLAW_GATEWAY_TOKEN:?OPENCLAW_GATEWAY_TOKEN is required}"
: "${HERMES_URL:=https://hermes-production-a3a7.up.railway.app}"
: "${HERMES_GATEWAY_TOKEN:?HERMES_GATEWAY_TOKEN is required}"
export HERMES_URL HERMES_GATEWAY_TOKEN

PORT="${PORT:-8080}"
OPENCLAW_CONFIG_DIR="${HOME}/.openclaw"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_DIR}/openclaw.json"
WORKSPACE_DIR="${HOME}"

mkdir -p "${OPENCLAW_CONFIG_DIR}"
mkdir -p "${WORKSPACE_DIR}/memory"

# ---------- Always rewrite AGENTS.md (it lists the live profile roster) ----------
cat > "${WORKSPACE_DIR}/AGENTS.md" <<'EOF'
# AGENTS.md — The Open Play (Railway)

This is the orchestrator OpenClaw workspace for The Open Play.

## Role
- Tier-1 orchestrator. Ingests campaign intake, decomposes work,
  delegates specialist work to Hermes profiles in parallel, QAs, packages.
- Read-only by default: skills live in the GitHub skills repo (Phase 2).
- Writes go through git commits, not loose files.

## Hermes profiles (Tier 2 — 6 total)
- `tournament-plan-agent` — marketing overview, logistics, schedule, DUPR divisions, day-of guide
- `email-agent`           — PickleballTournaments 8-week email sequence
- `outreach-agent`        — DMs, text blasts, FB groups, partner/facility/host outreach
- `hero-art-agent`        — flyer series + email hero art briefs (designer-ready)
- `social-image-agent`    — IG feed/stories/FB posts (copy + image briefs)
- `social-video-agent`    — editor briefs for promo/highlight/testimonial videos

## How to invoke them
See `~/.openclaw/skills/hermes-orchestration/SKILL.md` for the full recipe
(single profile, sequential, or parallel for full campaign builds).

Hermes endpoint: `$HERMES_URL/v1/chat/completions` (OpenAI-compatible).
Auth: `Authorization: Bearer $HERMES_GATEWAY_TOKEN`.
Profile name goes in the `model` field.

## Persistence
- /workspace is a Railway volume. Treat contents as durable.
- Memory: ~/memory/YYYY-MM-DD.md (create as needed).
- Campaign outputs: ~/campaigns/<id>/<profile>.md

EOF

if [ ! -f "${WORKSPACE_DIR}/SOUL.md" ]; then
  cat > "${WORKSPACE_DIR}/SOUL.md" <<'EOF'
# SOUL.md
You are the orchestrator for The Open Play. Terse, competent,
no filler. Delegate specialist work to Hermes profiles via the
openplay-skills repo conventions.

When the user asks for a campaign, fire the Hermes profiles in parallel
per the hermes-orchestration skill. Don't try to be a Hermes profile
yourself — invoke the profile.
EOF
fi

# ---------- Install baked-in skills into the workspace ----------
# Skills are shipped inside the image at /opt/openclaw-skills and copied
# into the OpenClaw skills directory on every boot. Workspace-local edits
# to a baked skill are preserved (we only refresh files that have changed).
SKILLS_SRC="/opt/openclaw-skills"
SKILLS_DST="${OPENCLAW_CONFIG_DIR}/skills"
if [ -d "${SKILLS_SRC}" ]; then
  mkdir -p "${SKILLS_DST}"
  # cp -RTu: recursive, no nested target dir, only-newer (preserves user edits)
  cp -RTu "${SKILLS_SRC}/." "${SKILLS_DST}/" 2>/dev/null || cp -R "${SKILLS_SRC}/." "${SKILLS_DST}/"
  echo "[openclaw-entrypoint] installed baked skills from ${SKILLS_SRC} → ${SKILLS_DST}"
fi

# ---------- Config file ----------
# Use Python (always present) to (re)write a valid config on every boot.
# Schema matches Brian's local ~/.openclaw/openclaw.json (2026.4.24):
#   - gateway.auth is an object {mode, token}
#   - gateway.mode is "local" (remote access comes from bind=lan + token)
#   - env.OPENROUTER_API_KEY is how provider keys are surfaced
#   - secrets.providers.openrouter wires the env allowlist
#   - auth.profiles declares the openrouter profile OpenClaw expects
python3 - <<'PY'
import json, os, pathlib

cfg_path = pathlib.Path(os.environ["HOME"]) / ".openclaw" / "openclaw.json"
port = int(os.environ.get("PORT", "8080"))
token = os.environ["OPENCLAW_GATEWAY_TOKEN"]
or_key = os.environ["OPENROUTER_API_KEY"]

cfg = {}
if cfg_path.exists():
    try:
        cfg = json.loads(cfg_path.read_text())
    except Exception:
        cfg = {}

cfg.setdefault("auth", {}).setdefault("profiles", {})
cfg["auth"]["profiles"]["openrouter:default"] = {
    "provider": "openrouter",
    "mode": "api_key",
}

cfg.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})
cfg["agents"]["defaults"]["model"].setdefault(
    "primary", "openrouter/anthropic/claude-opus-4.7"
)
cfg["agents"]["defaults"].setdefault("workspace", os.environ["HOME"])

cfg["gateway"] = {
    "port": port,
    "mode": "local",
    "bind": "lan",
    "auth": {"mode": "token", "token": token},
    "tailscale": {"mode": "off", "resetOnExit": False},
    "trustedProxies": [],
}

cfg.setdefault("plugins", {}).setdefault("entries", {})
cfg["plugins"]["entries"].setdefault("openrouter", {"enabled": True})
# Bonjour (mDNS) crashes in Railway's network namespace (CIAO PROBING
# CANCELLED). There's no LAN to advertise on anyway, so turn it off.
cfg["plugins"]["entries"]["bonjour"] = {"enabled": False}

cfg.setdefault("env", {})
cfg["env"]["OPENROUTER_API_KEY"] = or_key

cfg.setdefault("secrets", {}).setdefault("providers", {})
cfg["secrets"]["providers"]["openrouter"] = {
    "source": "env",
    "allowlist": ["OPENROUTER_API_KEY"],
}

# OpenClaw config validator is strict about unknown keys. Drop anything we
# know it doesn't recognise so stale volumes survive schema churn.
for bad_meta in ("lastTouchedBy",):
    if isinstance(cfg.get("meta"), dict) and bad_meta in cfg["meta"]:
        del cfg["meta"][bad_meta]
# Remove legacy top-level `providers` key (pre-refactor schema) if present.
if "providers" in cfg:
    del cfg["providers"]

cfg_path.write_text(json.dumps(cfg, indent=2))
print(f"[openclaw-entrypoint] wrote {cfg_path}")
PY

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
