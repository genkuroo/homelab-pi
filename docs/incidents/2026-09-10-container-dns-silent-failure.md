# 2026-09-10: Containers lose DNS while showing "Up"

| | |
|---|---|
| **Status** | Resolved. Detection added 2026-09-11. Root cause fixed later, after the [repeat on 2026-10-20](2026-10-20-container-dns-repeat.md) |
| **Duration** | About 31 hours of DNS failures in containers (09-10 02:01 → 09-11 08:52 PT, from cloudflared's log) |
| **Detected by** | Ethan, by chance, about 15 hours in, while rolling out the launcher page. No automated detection existed |
| **Severity** | Partial outage. Public sites stayed up; background jobs and the Discord bot did not |

## Summary

For more than a day, containers on the Pi couldn't resolve hostnames, so they
couldn't reach anything on the internet. `docker compose ps` showed every
container as "Up" the whole time. A container's DNS settings are copied in once,
when it starts. The host's DNS resolver (Tailscale's, at `100.100.100.100`)
broke, and the running containers stayed pointed at it. Restarting sleeper-bot
fixed that container right away, but nothing else was restarted. cloudflared
kept failing until the next morning. Nothing was monitoring for this kind of
failure, so it was only found by accident.

## Impact

- **sleeper-bot:** couldn't reach Discord or the Sleeper API until it was
  restarted on the evening of 09-10. League transactions were **delayed, not
  lost.** The bot only marks a transaction as announced after Discord accepts
  the post, so on restart it posts everything it hasn't announced yet. (This
  container's logs from September are gone because it was recreated on 09-11.
  The same catch-up behavior is confirmed in the October repeat, where the bot
  posted a backlog of 10 transactions the moment DNS came back.)
- **cloudflared:** every DNS lookup failed from 09-10 02:01 to 09-11 08:52 PT.
  **Public sites stayed reachable anyway.** cloudflared's tunnel connections to
  Cloudflare were already open and never dropped. The one connection that reset
  (09-11 03:14) reconnected in 20 seconds to a saved IP address, without needing
  DNS. The failures were only cloudflared's periodic refreshes of its server
  list, which had no effect for users while existing connections held.
- **Scheduled jobs that run inside containers** (`ffta-sync` every 15 minutes,
  `stock-refresh`) need outbound DNS. Their logs from September have since been
  rotated away, but they would have failed the same way they did in October, so
  their data went stale. Nothing was watching their results.
- **No data was lost.**

## Timeline (Pacific)

Sources: cloudflared's container log (still on the Pi) and git commit times.
The host's system log from before 2026-09-24 has been rotated away, so
NetworkManager's and Tailscale's own record of this incident is gone.

| Time | Event |
|---|---|
| 2026-09-08 23:20 | Pi reboots (from `uptime -s`). Not known to be related |
| 2026-09-09 19:30 | cloudflared reports "no recent network activity" on its tunnel connections. **A network drop on the Pi.** Most likely the trigger, the same as the October repeat |
| 2026-09-10 02:01 | cloudflared's first failed DNS lookup through Docker's resolver. It fails every 5 minutes from here on |
| 2026-09-10 ~17:13–17:39 | While rolling out the launcher page (`9cb52d8`, `b91318b`), Ethan notices sleeper-bot has gone silent. **About 15 hours after DNS broke.** The exact time and first symptom weren't recorded |
| 2026-09-10 (evening) | `docker compose restart sleeper-bot` fixes the bot right away. **No other container is restarted.** cloudflared keeps failing |
| 2026-09-11 03:14 | One cloudflared tunnel connection resets and reconnects in 20 s by IP. Public traffic unaffected |
| 2026-09-11 08:52 | cloudflared's last DNS failure. It wasn't restarted, so the shared resolver itself recovered here. Most likely from work on the host that morning, but that wasn't recorded |
| 2026-09-11 09:03 | `scripts/healthcheck.sh` added, with a check of each container's DNS upstream (`f505b5c`) |
| 2026-09-11 10:34 | Health check runs hourly on a systemd timer (`b3ea52f`) |
| 2026-09-11 11:11 | Health check sends a Discord alert when the overall state changes (`c7d494c`) |
| 2026-09-11 11:19 | `/health` command added to the Discord bot (`d100303`) |

## Root cause

**What we knew at the time:** the host's Tailscale DNS resolver had stopped
answering. Every container's Docker DNS forwarded to it, so every container lost
DNS. The process inside each container kept running, so Docker reported nothing
wrong.

**Why "Up" was misleading:** Docker saves each container's DNS settings when the
container is created (in `/var/lib/docker/containers/<id>/resolv.conf`) and
never updates them while it runs. "Up" only means the process hasn't exited. It
says nothing about whether the container can reach anything.

**What we didn't know yet:** *why* Tailscale's resolver broke. That only became
clear when the same failure happened again on 2026-10-20 (see that report). A
Wi-Fi drop leads to an empty `/etc/resolv.conf`, and Tailscale then saves that
empty file as its list of upstream servers. The 19:30 network drop in
cloudflared's log fits that pattern. This report is left as it was understood
at the time on purpose. The first response fixed **detection**, not the
**cause**, and that's why the failure came back.

## What went well

- Once spotted, the fix for the bot took one restart command.
- The follow-up went past "restart and move on." Within a day there was a health
  check that tests whether things *work* (DNS answers, apps respond, public
  URLs return the expected status), not just whether processes are running.
- The bot's "mark announced only after Discord accepts it" design meant the
  outage delayed league updates but didn't lose any.

## What went poorly

- **About 15 hours with no automated detection.** It was found only because
  Ethan happened to be working on the server.
- **The only health signal was process liveness** (`docker compose ps`), which
  can't see this kind of failure.
- **Only the noticed symptom was fixed.** The bot was restarted, but nobody
  checked the other containers, which shared the same broken resolver.
  cloudflared failed for about 15 more hours.
- **The root cause wasn't found.** Restarting cleared one symptom but left the
  trigger in place.

## Where we got lucky

- cloudflared's tunnel connections never needed DNS while they stayed open.
  If they had all dropped, they couldn't have looked up where to reconnect, and
  every public site would have gone down.

## Action items

| # | Action | Type | Status |
|---|---|---|---|
| 1 | Health check that queries each container's DNS upstream directly | Detect | ✅ `f505b5c` |
| 2 | Run it hourly with systemd | Detect | ✅ `b3ea52f` |
| 3 | Discord alert when health state changes | Detect | ✅ `c7d494c` |
| 4 | Check whether the last run of each scheduled job succeeded | Detect | ✅ part of `f505b5c` |
| 5 | Find *why* Tailscale DNS broke | Root cause | ❌ Not done. The failure happened again on 2026-10-20 |

## Lessons

- **"Running" is not "working."** Health checks should test the job the service
  does, not just whether its process exists.
- **Check everything that shares the failing dependency.** The bot was the
  container that got noticed, not the only one that was broken.
- **Fixing the symptom isn't fixing the cause.** Action item 5 was the one that
  mattered, and it was the one left undone.
- **Logs expire.** The host's log for this incident was gone within weeks. Write
  the postmortem while the evidence still exists.
