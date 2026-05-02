#!/usr/bin/env bash
# Entrypoint for Hermes Agent container on Railway.
# - Seeds config.yaml with OpenRouter as the default provider
# - Clones + periodically pulls the openplay-skills repo into /workspace/skills
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

# ---------- Skills repo sync ----------
# Clone openplay-skills into /workspace/skills on boot; background-pull every 5 min.
# OPENPLAY_SKILLS_REPO defaults to the public path; OPENPLAY_SKILLS_TOKEN optional for private.
SKILLS_DIR="${HERMES_HOME}/skills"
SKILLS_REPO="${OPENPLAY_SKILLS_REPO:-https://github.com/TheOpenPlay/openplay-skills.git}"
SKILLS_BRANCH="${OPENPLAY_SKILLS_BRANCH:-main}"
SKILLS_PULL_INTERVAL="${OPENPLAY_SKILLS_PULL_INTERVAL:-300}"  # seconds

sync_skills() {
  # Inject token into URL if OPENPLAY_SKILLS_TOKEN is set and repo is https://github.com/…
  local url="${SKILLS_REPO}"
  if [[ -n "${OPENPLAY_SKILLS_TOKEN:-}" && "${url}" == https://github.com/* ]]; then
    url="https://x-access-token:${OPENPLAY_SKILLS_TOKEN}@${url#https://}"
  fi

  if [ -d "${SKILLS_DIR}/.git" ]; then
    git -C "${SKILLS_DIR}" remote set-url origin "${url}" 2>/dev/null || true
    git -C "${SKILLS_DIR}" fetch --quiet origin "${SKILLS_BRANCH}" 2>/dev/null || {
      echo "[hermes-entrypoint] skills: fetch failed, continuing with cached copy"
      return 0
    }
    git -C "${SKILLS_DIR}" reset --hard "origin/${SKILLS_BRANCH}" --quiet 2>/dev/null || true
    echo "[hermes-entrypoint] skills: pulled latest ($(git -C "${SKILLS_DIR}" rev-parse --short HEAD 2>/dev/null))"
  else
    echo "[hermes-entrypoint] skills: cloning ${SKILLS_REPO} → ${SKILLS_DIR}"
    if ! git clone --depth 1 --branch "${SKILLS_BRANCH}" "${url}" "${SKILLS_DIR}" 2>&1; then
      echo "[hermes-entrypoint] skills: clone failed — hermes will boot without skills"
      mkdir -p "${SKILLS_DIR}"
    fi
  fi
}

sync_skills

# Background loop — pulls every SKILLS_PULL_INTERVAL seconds.
(
  while true; do
    sleep "${SKILLS_PULL_INTERVAL}"
    sync_skills || true
  done
) &

# Skills webhook listener — tiny HTTP server on port 8090 that triggers an
# immediate sync when GitHub pushes a webhook. Optional; no-op if python3
# missing (it is present in the image). The webhook path is /_skills_sync
# and accepts any POST.
(
  python3 - <<'PYEOF' &
import http.server, socketserver, subprocess, os, signal, sys
PORT = int(os.environ.get("SKILLS_WEBHOOK_PORT", "8090"))
SKILLS_DIR = os.environ.get("HERMES_HOME", "/workspace") + "/skills"
BRANCH = os.environ.get("OPENPLAY_SKILLS_BRANCH", "main")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            # Drain body
            ln = int(self.headers.get("Content-Length", "0") or 0)
            if ln: self.rfile.read(ln)
        except Exception: pass
        try:
            subprocess.run(["git", "-C", SKILLS_DIR, "fetch", "--quiet", "origin", BRANCH], check=False, timeout=30)
            subprocess.run(["git", "-C", SKILLS_DIR, "reset", "--hard", f"origin/{BRANCH}", "--quiet"], check=False, timeout=30)
            sha = subprocess.run(["git", "-C", SKILLS_DIR, "rev-parse", "--short", "HEAD"], capture_output=True, text=True, timeout=10).stdout.strip()
            print(f"[skills-webhook] pulled {sha}", flush=True)
        except Exception as e:
            print(f"[skills-webhook] pull failed: {e}", flush=True)
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a, **k): pass
try:
    with socketserver.TCPServer(("127.0.0.1", PORT), H) as s:
        print(f"[skills-webhook] listening on 127.0.0.1:{PORT}", flush=True)
        s.serve_forever()
except Exception as e:
    print(f"[skills-webhook] disabled: {e}", flush=True)
PYEOF
) &

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
echo "[hermes-entrypoint] skills_dir=${SKILLS_DIR} (pull every ${SKILLS_PULL_INTERVAL}s)"
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
