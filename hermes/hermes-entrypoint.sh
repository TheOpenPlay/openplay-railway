#!/usr/bin/env bash
# Entrypoint for Hermes Agent container on Railway.
# - Seeds config.yaml with OpenRouter as the default provider
# - Creates three profiles on first boot (idempotent)
# - Launches the messaging gateway (which ALSO runs the API server when env is set)
set -euo pipefail

: "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY is required}"
: "${HERMES_GATEWAY_TOKEN:?HERMES_GATEWAY_TOKEN is required}"

PORT="${PORT:-8080}"
export HERMES_HOME="${HERMES_HOME:-/workspace}"
mkdir -p "${HERMES_HOME}"

# ---------- API server env (consumed by `hermes gateway run`) ----------
export API_SERVER_ENABLED=true
export API_SERVER_HOST=0.0.0.0
export API_SERVER_PORT="${PORT}"
export API_SERVER_KEY="${HERMES_GATEWAY_TOKEN}"

# ---------- Base config.yaml ----------
CFG="${HERMES_HOME}/config.yaml"
if [ ! -f "${CFG}" ]; then
  cat > "${CFG}" <<'EOF'
model:
  default: anthropic/claude-opus-4.7
  provider: openrouter
  base_url: https://openrouter.ai/api/v1
  api_mode: chat_completions
providers:
  openrouter:
    base_url: https://openrouter.ai/api/v1
    api_mode: chat_completions
agent:
  max_turns: 90
  gateway_timeout: 1800
  api_max_retries: 3
  verbose: false
EOF
fi

# ---------- Credentials (OpenRouter) ----------
# Hermes reads provider API keys from ~/.hermes/auth.json style storage, but
# the simplest portable path is the env passthrough. Hermes honours
# OPENROUTER_API_KEY at the env level when the provider is OpenRouter.
# (Already exported by Railway env vars.)

# ---------- Profiles ----------
# `hermes profile create <name>` is idempotent-ish — it errors if the profile
# exists. We swallow the error and move on.
create_profile() {
  local name="$1"
  if hermes profile list 2>/dev/null | grep -q "^${name}\b\|^\*\?\s*${name}\b"; then
    echo "[hermes-entrypoint] profile ${name} already exists"
  else
    echo "[hermes-entrypoint] creating profile ${name}"
    hermes profile create "${name}" --no-interactive 2>&1 || \
      hermes profile create "${name}" 2>&1 || \
      echo "[hermes-entrypoint] WARN: could not create profile ${name} (may already exist)"
  fi
}

create_profile "email-agent"
create_profile "tournament-plan-agent"
create_profile "social-design-agent"

echo "[hermes-entrypoint] HERMES_HOME=${HERMES_HOME}"
echo "[hermes-entrypoint] api_server=0.0.0.0:${PORT} (auth: bearer)"
hermes profile list 2>&1 || true

# ---------- Launch ----------
# `hermes gateway run` starts the messaging gateway AND the API server
# (when API_SERVER_ENABLED=true). Railway's only exposed port is $PORT,
# which the API server binds. The messaging gateway will try to start
# messaging adapters — none are configured here, so it logs a notice and
# continues serving the API.
export PYTHONUNBUFFERED=1
# Allow any caller for the API server — Railway edge is the auth boundary
# and we also gate via bearer token.
export GATEWAY_ALLOW_ALL_USERS=true
exec hermes gateway run -vv --accept-hooks
