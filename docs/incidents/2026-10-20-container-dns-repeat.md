# 2026-10-20: Wi-Fi drop takes out DNS for every container (repeat)

| | |
|---|---|
| **Status** | Resolved, with the root cause fixed permanently (`7e04457`) |
| **Duration** | 2026-10-20 14:48 → 2026-10-21 09:02 PT, about 18 hours 15 minutes |
| **Detected by** | The automated health check added after the [2026-09-10 incident](2026-09-10-container-dns-silent-failure.md), 18 minutes after the trigger |
| **Severity** | Partial outage. Public sites stayed up; every container lost outbound DNS |

## Summary

A Wi-Fi drop on the Pi set off a chain that left every container unable to
resolve hostnames, the same failure as 2026-09-10. This time the health check
caught it in 18 minutes, and this time the cause was traced all the way back.
NetworkManager and Tailscale were both rewriting `/etc/resolv.conf`, and the
Wi-Fi drop left Tailscale holding an empty list of upstream DNS servers.
Detection worked, but nobody acted on the alerts until the next morning. The
permanent fix gives containers their own fixed DNS servers and stops Tailscale
from managing the host's DNS, so this chain can't happen again.

## Impact

All figures are from the Pi's system log and container logs.

- **All 10 containers** lost outbound DNS: sleeper-bot, ffta, stock,
  stock-demo, fitness, fitness-demo, dnd, dnd-staging, caddy and cloudflared.
- **sleeper-bot** was disconnected from Discord and Sleeper for 18 hours.
  League transactions were **delayed, not lost.** It posted a backlog of **10
  transactions** two seconds after reconnecting (09:02:50).
- **ffta-sync** failed **74 times in a row** (every 15 minutes), so the
  trade analyzer's league data went stale overnight.
- **ffta-values** (the nightly market-value snapshot) failed at 03:06. That
  matters because FantasyCalc has no history, so a missed day can't be
  re-fetched later. It was re-run by hand at 09:03, **6 hours late but not lost.**
  The 03:30 backup and 04:18 R2 upload ran successfully (they run on the host,
  which had working DNS) but didn't include that day's snapshot until the next
  night.
- **stock-refresh** failed to fetch any of its 4 tickers at 16:06 but **exited
  with success**, so neither systemd nor the health check saw it fail. That's a
  separate silent failure this incident exposed (see action items).
- **Public sites kept serving.** Every hourly health check passed all 6 public
  endpoint checks through Cloudflare. Host uptime was unaffected.
- **No data was lost.**

## Timeline (Pacific)

| Time | Event |
|---|---|
| 14:31–14:37 | Early warning signs: Tailscale's DNS forwards to the local network's resolver (`192.168.88.100`) start timing out. sleeper-bot fails a Sleeper lookup at 14:34 and recovers |
| 14:44 | Wi-Fi gets a new DHCP lease |
| 14:48:36 | **Wi-Fi disconnects.** NetworkManager restarts DHCP |
| 14:48:52 | **NetworkManager writes an empty `/etc/resolv.conf`.** Tailscale logs: *"resolv.conf changed from what we expected. did some other program interfere?"* and saves the empty list. `100.100.100.100` now fails every lookup |
| 14:49:06 | First failed `ffta-sync` run |
| **15:06:45** | **Health check detects it:** 12 failures (DNS in all 10 containers, sleeper-bot unhealthy, ffta-sync failed). Discord alert sent. **18 minutes after the trigger** |
| 15:06 → 08:06 | Health check fails every hour, 18 runs in a row. Because of an alert bug (see below), it most likely posted a new Discord alert almost every hour |
| 16:06 | `stock-refresh` fetches 0 of 4 tickers but exits 0. Not detected |
| 03:06 | `ffta-values` nightly snapshot fails. Failures rise to 13 from the 04:07 run |
| 03:34 / 04:18 | Nightly backup and R2 upload succeed, without that day's value snapshot |
| **09:01:36** | **First response**, the next morning: investigation on the Pi starts (`tailscale debug prefs`) |
| 09:02:11 | Current `/etc/resolv.conf` saved as a backup. `/etc/docker/daemon.json` written with fixed DNS servers |
| 09:02:22 | Docker restarted so containers pick up the new DNS |
| 09:02:48 | sleeper-bot reconnects to Discord. Posts its 10-transaction backlog at 09:02:50 |
| 09:03:34 | Missed `ffta-values` snapshot re-run by hand. Succeeds |
| 09:06:44 | Health check: **42 ok / 0 fail** |
| 09:18 | Fix committed (`7e04457`): `docker/daemon.json` in the repo, installed by `bootstrap.sh`, health-check hint updated. Pulled on the Pi |

## Root cause

Three normal behaviors combined into a failure:

1. **NetworkManager** rewrites `/etc/resolv.conf` when the network changes. While
   Wi-Fi was down, it wrote the file with no DNS servers (14:48:52).
2. **Tailscale** (with `accept-dns` on) also manages `/etc/resolv.conf`. It
   noticed the change ("trampled," in its own log) and saved whatever servers it
   found there as the upstreams for its own resolver, `100.100.100.100`. It saved
   the **empty** list and didn't recover when Wi-Fi came back, so
   `100.100.100.100` returned SERVFAIL for everything.
3. **Docker containers** forward DNS to whatever the host used when they started.
   They were all forwarding to `100.100.100.100`, so they all lost DNS. The host
   itself recovered as soon as NetworkManager wrote a proper file again.

**The underlying problem:** two programs were both managing the same file, and
every container depended on the result. The containers didn't need any of it.
Nothing on the Pi uses Tailscale's MagicDNS names, and `tailscale serve` works
without it.

**Why it happened twice:** the first time (2026-09-10), the follow-up added
detection but didn't find the trigger. The health check did its job this time,
and its per-container DNS check pointed straight at the shared resolver.

## Why the response took 18 hours

Detection took 18 minutes. Response took about 18 hours. No reason was recorded
at the time, but the setup explains most of it:

- **Alerts went to a Discord channel, nothing more.** Nothing reached a phone as
  an urgent notification, and nothing escalated when a failure went unanswered.
  A failure at 15:00 that lasts overnight looks the same as a minor warning.
- **Repeated alerts carried no new information.** The health check is supposed
  to alert only when its state changes. It decides that by fingerprinting the
  list of problems, and that list is built from `docker compose config
  --services`, which **returns services in a different order every run**
  (confirmed on the Pi). So the same 12 failures looked like a new state almost
  every hour, and probably posted a new alert each time. A channel that repeats
  the same alert every hour is easy to start ignoring.

## Resolution

Two changes. Either one alone would have prevented this incident.

1. **Separate container DNS from host DNS.** `docker/daemon.json` sets
   `"dns": ["1.1.1.1", "9.9.9.9"]`, so containers no longer inherit whatever the
   host happens to have. Two providers, so one being down isn't an outage.
2. **Stop Tailscale from managing the host's DNS.** `tailscale set
   --accept-dns=false` ends the conflict with NetworkManager over
   `/etc/resolv.conf`.

Both are now in code (`bootstrap.sh` installs `daemon.json`). `CLAUDE.md` and
`README.md` warn against undoing them. The per-container DNS check stays in the
health check as a guard. Its failure hint now explains what it means if a
container is ever back on Tailscale DNS.

## What went well

- **The health check from the last incident caught it in 18 minutes,** compared
  with about 15 hours, by chance, in September. That follow-up action worked.
- The check pointed straight at the cause: all 10 containers failing DNS through
  the same upstream address.
- The investigation saved the current `resolv.conf` before changing anything, so
  the change could be undone.
- The fix removes the dependency instead of restarting containers, and it's in
  the repo instead of being a one-off change on the Pi.
- Both design choices that protect data held: the bot's backlog posted on
  reconnect, and the missed value snapshot was re-run the same morning.

## What went poorly

- **About 18 hours from alert to fix.** Detection worked; response didn't.
- **Alert noise.** The same failure probably posted every hour because of the
  ordering bug, which buries the one alert that matters.
- **It was a repeat.** The first incident's action items didn't include finding
  the root cause, so the same trigger hit again six weeks later.
- **A job reported success when it had failed.** `stock-refresh` exits 0 even
  when every ticker fails, so the health check can't catch it.

## Where we got lucky

- Public sites stayed up, so no outside users were affected. cloudflared's open
  tunnel connections didn't need DNS, the same as in September.
- The value snapshot was re-run within hours. If it had been missed for a whole
  day without anyone noticing, that day's market values would have been gone for
  good.

## Action items

| # | Action | Type | Status |
|---|---|---|---|
| 1 | Pin container DNS in `/etc/docker/daemon.json` | Prevent | ✅ `7e04457` |
| 2 | `tailscale set --accept-dns=false` on the Pi | Prevent | ✅ applied 2026-10-21 |
| 3 | `bootstrap.sh` installs `daemon.json`, so a rebuild keeps the fix | Prevent | ✅ `7e04457` |
| 4 | Document "don't undo this" in `README.md` / `CLAUDE.md` | Prevent | ✅ |
| 5 | Sort the problem list before fingerprinting it, so the same failures don't re-alert every hour | Respond | ✅ committed with this report. Needs `git pull` on the Pi |
| 6 | Make `stock-refresh` exit non-zero when every ticker fails, so systemd and the health check see it | Detect | ✅ stock-tracker `69fcc73`. Needs `git pull` + `docker compose build stock stock-demo && docker compose up -d stock stock-demo` on the Pi |
| 7 | Separate alert urgency: failures in every container → phone notification; single warnings → channel only | Respond | ⬜ Todo |
| 8 | Monitor the public sites from **outside** the Pi (uptime checker), so an outage of the Pi itself can still alert | Detect | ⬜ Todo |
| 9 | Confirm Tailscale's own DNS health warning has cleared | Cleanup | ✅ `tailscale status` shows no health warnings (checked 2026-10-22) |

## Lessons

- **Detection without root-cause work just means you'll get paged for the same
  thing again.** The September follow-up was half done.
- **Detection isn't response.** An alert that nobody sees for 18 hours is only
  slightly better than no alert. Urgent failures need a path that reaches a
  person.
- **Alerts have to stay trustworthy.** If the same alert repeats every hour,
  people stop reading it.
- **Remove dependencies you don't need.** Containers never needed Tailscale's
  resolver. They were using it only because that was Docker's default.
- **Watch for two programs managing the same file.** If two daemons both think
  they own a config file, sooner or later one will leave it in a broken state.
