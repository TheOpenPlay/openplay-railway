# openplay-railway

Deployment configs for The Open Play 2-tier agent platform on Railway.

## Services

| Service  | Role                                   | Root dir    |
|----------|----------------------------------------|-------------|
| openclaw | Tier-1 orchestrator (OpenClaw gateway) | `openclaw/` |
| hermes   | Tier-2 specialist host (Hermes API)    | `hermes/`   |

Each subfolder has its own `Dockerfile` + entrypoint, and is wired to its own
Railway service with a volume mount.

## Env vars (both services)

- `OPENROUTER_API_KEY` — the project's OpenRouter key
- `OPENCLAW_GATEWAY_TOKEN` — bearer for OpenClaw (openclaw service only)
- `HERMES_GATEWAY_TOKEN`   — bearer for Hermes API server (hermes service only)
- `PORT` — injected by Railway; entrypoints honour it.

## Volumes

- `openclaw` → `/workspace` (orchestrator state, config, memory)
- `hermes`   → `/workspace` (Hermes HERMES_HOME: profiles, skills, sessions)

## Local test

```bash
cd openclaw && docker build -t openplay-openclaw .
cd ../hermes   && docker build -t openplay-hermes   .
```

Railway builds these remotely on every push to `main`.
