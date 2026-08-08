# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this is

Infrastructure-as-code for a self-hosted stack on a Raspberry Pi 400. It does
not contain application code — it orchestrates four sibling repos in
`~/Code/`: `stock-tracker`, `fitness-dashboard`, `dnd-campaign-tracker` and
`sleeper-discord-bot`. Compose build contexts point at `../<app>`, so a change
to an app's Dockerfile is a change to this deployment.

## Invariants — don't break these

- **Never expose an app with real personal data to the tunnel.** Only `dnd`
  goes public with real data, and only because it has login auth. The `stock`
  and `fitness` services (real data) bind to `127.0.0.1` and are reachable
  solely through `tailscale serve`. Their public counterparts are the separate
  `-demo` services running on synthetic data with `READ_ONLY=1`.
- **No `ports:` binding to `0.0.0.0`,** and no router port-forwarding. All
  public ingress goes through `cloudflared`.
- **No secrets in committed files.** They live in `.env` on the Pi
  (gitignored); `.env.example` documents the keys with empty values.
- **`DND_SECRET_KEY` is stable state,** not a generated value. Rotating it logs
  out every player.
- **`sleeper_bot_data` is stable state too.** It records which league
  transactions have already been announced. Deleting the volume makes the bot
  re-absorb history silently — but any change that makes it *replay* history
  spams a real Discord channel, so treat the store as production data.

## Conventions

- Timers must set `Persistent=true`. Catching up a missed run is the whole
  reason this moved off macOS `launchd`.
- Scheduled jobs run via `docker compose exec` against the already-running
  service so they share its volume — never a fresh `run` container, which
  risks writing to a different database than the dashboard reads.
- Back up SQLite with the `sqlite3` backup API, never `cp`. A file copy of a
  live database can capture a torn write.
- Comments explain *why*, matching the style of the sibling app repos.

## Testing changes

There is no test suite. Validate with:

```bash
docker compose config          # compose file parses, env vars resolve
docker compose build           # images build (ARM64 on the Pi)
shellcheck scripts/*.sh
systemd-analyze verify systemd/*.service systemd/*.timer
```

Build on the Pi, not the Mac — the Mac is also arm64, but the base images and
Python wheels differ between macOS and Debian aarch64.
