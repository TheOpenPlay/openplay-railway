---
name: hermes-orchestration
description: Use to invoke The Open Play's Tier-2 Hermes profiles from the orchestrator — sequentially, or concurrently in parallel for full campaign builds. Triggers when the user asks for a "campaign", "full plan", "all assets", "fire the agents", "run all agents", or names a Hermes profile (email-agent, tournament-plan-agent, outreach-agent, hero-art-agent, social-image-agent, social-video-agent).
---

# Hermes Orchestration

You are the **Tier-1 orchestrator** for The Open Play. Your job is to decompose campaign work into specialist tasks and invoke the right **Hermes Tier-2 profiles** to execute them. You can fire them one at a time, sequentially, or **all of them in parallel** for a full campaign build.

## Architecture

| Tier | Where | What |
|------|-------|------|
| Tier 1 | This OpenClaw on Railway | Strategy, intake decomposition, multi-agent orchestration, QA |
| Tier 2 | Hermes on Railway (separate service) | Specialist profiles, each with own skills |

Hermes is reachable at the URL in env var `HERMES_URL` (default: `https://hermes-production-a3a7.up.railway.app`) with bearer auth from `HERMES_GATEWAY_TOKEN`. The endpoint is OpenAI-compatible: profile name goes in the `model` field of `/v1/chat/completions`.

## The 6 Tier-2 Profiles

| Profile | What it does | Typical campaign role |
|---|---|---|
| `tournament-plan-agent` | Marketing overview, logistics, schedule, DUPR divisions, day-of guide | First — produces the campaign foundation that other agents reference |
| `email-agent` | PickleballTournaments email blasts (8-week sequence, themed by phase) | After plan |
| `outreach-agent` | DMs, text blasts, FB group posts, partner / facility / host outreach | After plan, parallel with email |
| `hero-art-agent` | Flyer series briefs + email hero art briefs (designer-ready specs) | After plan, parallel |
| `social-image-agent` | IG feed, stories, FB post copy + design briefs | After plan, parallel |
| `social-video-agent` | Editor briefs for promo videos, highlight reels, testimonials, UGC | After plan, parallel |

Use `tournament-plan-agent` first for any new campaign. The other 5 can run in parallel once the plan exists, because each will reference the plan via campaign context.

## How to invoke a Hermes profile

Use `exec` with `curl` to POST to the Hermes gateway. Always pass the bearer token from env. Profile name goes in `model`.

### Single profile (sequential)

```bash
curl -sS -X POST "$HERMES_URL/v1/chat/completions" \
  -H "Authorization: Bearer $HERMES_GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "tournament-plan-agent",
    "messages": [
      {"role": "user", "content": "<task description with full campaign intake>"}
    ]
  }'
```

Read `.choices[0].message.content` from the JSON response.

### Multiple profiles in parallel (concurrent campaign build)

For a full campaign build, fire 5+ profiles concurrently. Use shell job control with `&` and `wait`, writing each result to a temp file:

```bash
mkdir -p /tmp/campaign-<id>
for profile in email-agent outreach-agent hero-art-agent social-image-agent social-video-agent; do
  (
    curl -sS -X POST "$HERMES_URL/v1/chat/completions" \
      -H "Authorization: Bearer $HERMES_GATEWAY_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg m "$profile" --arg c "$TASK_FOR_$profile" \
        '{model: $m, messages: [{role:"user", content:$c}]}')" \
      > /tmp/campaign-<id>/$profile.json
  ) &
done
wait
```

Then read all 5 result files and assemble the campaign package.

### Concurrency rule of thumb

- **≤ 6 in parallel:** safe. Hermes handles it; OpenRouter rate limits cope.
- **> 6:** stagger in waves of 6 with `wait` between waves.

## When to invoke what

### Triggers from the user

| User says | Do this |
|-----------|---------|
| "Build a full campaign for [tournament]" | Fire `tournament-plan-agent` first, then fire the other 5 in parallel |
| "Generate the email sequence" | Fire `email-agent` only |
| "I need flyers + social posts" | Fire `hero-art-agent` + `social-image-agent` in parallel |
| "Mock campaign / test the pipeline" | Build a plausible intake yourself, fire all 6 |
| "Iterate on the email-agent output" | Re-invoke `email-agent` with prior output + correction in messages |

### Always include in every Hermes call

The user message to a Hermes profile should include:
1. **Campaign intake** — tier (AFPL / Licensing / Casual), venue, dates, divisions, sponsors, tone, target attendance.
2. **What you specifically want from this profile** (e.g., for email-agent: "produce the 8-week email sequence with subject lines and body copy").
3. **Any prior agent outputs the profile needs** (e.g., for email-agent, paste the relevant section of the tournament plan).

Profiles do not share state across calls. Every call is fresh — pass context.

## Reporting back to the user

After firing agents, summarize:
- Which profiles were invoked
- Whether they succeeded (response received) or failed (HTTP error / empty content)
- Brief preview of each profile's output (first ~150 chars)
- Token usage if surfaced in the response

For full campaign builds, save the full output of each profile to `/workspace/campaigns/<id>/<profile>.md` so the user can retrieve it later.

## Failure modes

- **401 from Hermes:** token wrong or env missing. Tell the user to check `HERMES_GATEWAY_TOKEN`.
- **404 / unknown model:** profile name mistyped. Use only the 6 names from the table above.
- **Timeout (default 3 min in app, no timeout in shell):** a single Hermes profile is taking too long. Don't retry blindly; report and ask whether to retry, simplify the prompt, or skip.
- **Empty `choices[0].message.content`:** model produced nothing. Re-invoke with a more directive prompt.

## Don't

- ❌ Don't try to "be" a Hermes profile yourself. If the work belongs to a profile, invoke the profile.
- ❌ Don't invent profiles that aren't in the 6-profile roster.
- ❌ Don't fire more than 6 profiles in parallel at once.
- ❌ Don't strip the bearer token or log it in messages back to the user.
