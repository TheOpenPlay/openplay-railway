# Dockerfile.hermes
# Hermes Agent v0.11.0 for The Open Play (Railway)
#
# Responsibilities:
#   - Install Hermes Agent v0.11.0 from the NousResearch GitHub tag
#   - Pre-create three profiles: email-agent, tournament-plan-agent, social-design-agent
#   - Enable the OpenAI-compatible API server on 0.0.0.0:$PORT
#   - Persist /workspace (HERMES_HOME) on a Railway volume
#
# Hermes exposes two surfaces:
#   - Messaging gateway (Telegram/Discord/WhatsApp) — NOT used here
#   - API server (/v1/chat/completions) — THIS is what we expose to Vercel
#
# We run `hermes gateway run` which boots the API server when
# API_SERVER_ENABLED=true + API_SERVER_KEY + API_SERVER_HOST=0.0.0.0 are set.

FROM python:3.11-slim-bookworm

# ---------- system deps ----------
# Match the upstream Hermes Dockerfile's runtime tools (git/node/ripgrep/ffmpeg)
# so the bundled tools actually work, but skip Playwright (we don't need it
# for API-server workloads and it more than doubles the image size).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential git curl ca-certificates ripgrep ffmpeg \
        nodejs npm jq procps tini \
    && rm -rf /var/lib/apt/lists/*

# ---------- hermes install ----------
# v0.11.0 tag. pip install direct from GitHub. The [all] extra pulls in every
# optional dep (messaging adapters, provider SDKs, MCP, etc.); we could slim
# this later if size matters.
# NousResearch uses calendar tags; v0.11.0 == v2026.4.23 per release notes.
ARG HERMES_VERSION=v2026.4.23
RUN pip install --no-cache-dir "hermes-agent[all] @ git+https://github.com/NousResearch/hermes-agent.git@${HERMES_VERSION}"

# Sanity check — fail fast if the install is broken.
RUN hermes --version

# ---------- workspace ----------
ENV HERMES_HOME=/workspace
WORKDIR /workspace

# ---------- entrypoint ----------
COPY hermes-entrypoint.sh /usr/local/bin/hermes-entrypoint.sh
RUN chmod +x /usr/local/bin/hermes-entrypoint.sh

ENV PORT=8080
EXPOSE 8080

# Hermes API server exposes /v1/models — cheap + auth-free for identity probes?
# It DOES require the bearer token. So we probe via /v1/models with the key.
# For simplicity we hit the TCP port with curl and accept any HTTP response.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/v1/models" | grep -E "^(200|401)$" || exit 1

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/hermes-entrypoint.sh"]
