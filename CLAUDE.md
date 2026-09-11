# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this is

Infrastructure-as-code for a self-hosted stack on a Raspberry Pi 400. It does
not contain application code — it orchestrates five sibling repos in
`~/Code/`: `stock-tracker`, `fitness-dashboard`, `dnd-campaign-tracker`,
`sleeper-discord-bot` and `ff-trade-analyzer`. Compose build contexts point at
`../<app>`, so a change to an app's Dockerfile is a change to this deployment.

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
- **The Pi boots from an SD card and the backups live on it.** `/opt/homelab/backups`
  is on the same device as the live databases, so a card failure takes both.
  `ffta-r2-sync` is the mitigation: it copies the analyzer's backups to
  Cloudflare R2 nightly. It uploads **ffta only** — the same folder holds real
  bodyweight history and real stock holdings, and those stay in the house.
  Do not widen the `--include` filter without asking.
- **`ffta_data` holds one thing that cannot be rebuilt.** Its league data can
  always be re-synced from Sleeper, but its daily market-value snapshots
  cannot: FantasyCalc serves current values only and has no history endpoint.
  Those snapshots are what let a trade be graded against the values that were
  true on the day it was made, so the volume is backed up and `ffta-values`
  sets `Persistent=true` for the same reason.
- **`ffta` is public only behind basic auth.** It is reachable two ways: the
  tailnet via its `127.0.0.1` binding, and `fantasy.${DOMAIN}` through Caddy
  with a shared password. The password is the whole protection — it republishes
  nine other league members' names and the app has no login of its own. Do not
  remove the `basic_auth` block to "simplify" the Caddyfile.

## Gotchas that cost real debugging time

- **Double every `$` in a bcrypt hash written to `.env`.** Compose interpolates
  values it reads from `.env`, so `$2a$14$w1kHv...` loses `$w1kHv...` as an
  undefined variable and Caddy receives a truncated hash. The failure mode is a
  silent 401 with nothing in any log. Verify with
  `docker compose exec caddy printenv FFTA_AUTH_HASH`, which shows what the
  container actually got — not `docker compose config`, which re-escapes `$` for
  display and looks wrong even when it is right.
- **`encode` is site-level and cannot live in a snippet imported inside
  `reverse_proxy`.** Caddy refuses the whole config, which surfaces downstream
  as a generic 502 from Cloudflare with nothing pointing at a parse error.
- **Caddy is a local build, not the stock image.** `caddy/Dockerfile` compiles
  in `replace-response`. `caddy` in the compose file is `build: ./caddy`, so
  `docker compose build caddy` must run on the Pi (it needs network for the Go
  module fetch) before the new config works — `docker compose up -d caddy`
  alone will reuse the old image.
- **The replace-response directive is `replace`, not `replace_response`,** and
  it self-orders after `encode` — no `order` line in the global options. An
  older syntax used `replace_response` plus a manual `order`; with the current
  module that fails at startup as `replace_response is not a registered
  directive`, which surfaces as a blanket 502 from Cloudflare.
- **The `(homelink)` replacement string must contain no `{` or `}`.** Caddy
  treats braces as placeholders even inside a backtick string, so the injected
  button is styled with an inline `style="..."` attribute, never a `<style>`
  block.

## Conventions

- Timers must set `Persistent=true`. Catching up a missed run is the whole
  reason this moved off macOS `launchd`.
- Scheduled jobs run via `docker compose exec` against the already-running
  service so they share its volume — never a fresh `run` container, which
  risks writing to a different database than the dashboard reads.
- Back up SQLite with the `sqlite3` backup API, never `cp`. A file copy of a
  live database can capture a torn write.
- Local backups prune at 14 days; R2 uses `rclone copy`, which never deletes at
  the destination. That split is intentional — the card holds the recent working
  copy, R2 is the permanent archive.
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
