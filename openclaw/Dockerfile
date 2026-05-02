# Dockerfile.openclaw
# Headless OpenClaw gateway for The Open Play (Railway)
#
# Responsibilities:
#   - Install OpenClaw CLI from npm (global)
#   - Seed a minimal BOOTSTRAP-free workspace at /workspace
#   - Launch `openclaw gateway run` bound to 0.0.0.0, port $PORT (Railway-provided)
#   - Token auth required (OPENCLAW_GATEWAY_TOKEN env)
#   - Model routing: OpenRouter via OPENROUTER_API_KEY
#
# Persistent volume: /workspace (Railway volume mount)

FROM node:22-bookworm-slim

# ---------- system deps ----------
# git/curl/ca-certs for skills repo pulls, ripgrep for search tools,
# python3 for any scripts OpenClaw may shell out to.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git curl ca-certificates ripgrep python3 python3-pip jq procps tini \
    && rm -rf /var/lib/apt/lists/*

# ---------- OpenClaw ----------
# Pin to the version matching Brian's local install (2026.4.24) to avoid drift.
RUN npm install -g openclaw@2026.4.24 && openclaw --version || true

# ---------- workspace ----------
# /workspace is the persistent volume mount point. OpenClaw's OPENCLAW_HOME
# nests .openclaw/ under $HOME, so we point HOME at /workspace and keep
# the config + state inside the volume.
ENV HOME=/workspace
ENV OPENCLAW_HOME=/workspace
WORKDIR /workspace

# ---------- entrypoint ----------
COPY openclaw-entrypoint.sh /usr/local/bin/openclaw-entrypoint.sh
RUN chmod +x /usr/local/bin/openclaw-entrypoint.sh

# Railway injects $PORT; default to 8080 for local docker runs.
ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT}/health" || exit 1

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/openclaw-entrypoint.sh"]
