#!/usr/bin/env bash
# System-wide health check: not just "is the container running", but "can it
# actually resolve DNS and answer real traffic".
#
# This exists because of a real incident (2026-09-10): sleeper-bot and
# cloudflared sat with `docker compose ps` showing "Up" for a full day while
# both were silently deaf to the internet. A container's DNS config is a
# snapshot frozen at the moment it started; when the host's resolver later
# broke and recovered, the *running* containers never noticed either change.
# `docker compose ps` only tells you the process didn't crash -- it has no
# way to know that. This script checks the things that would have caught it.
#
# Exit code doubles as a severity signal for cron/systemd/alerting later:
#   0 = all clear, 1 = warnings only, 2 = at least one failure.

set -uo pipefail   # not -e: one failed check must not abort the rest

cd "$(dirname "$0")/.."

# Pull in DOMAIN etc. the same way `docker compose` does, so URLs below match
# whatever's actually configured rather than being hardcoded twice.
set -a
# shellcheck disable=SC1091
[[ -f .env ]] && source .env
set +a
: "${DOMAIN:?DOMAIN is not set -- check .env}"

STATUS=0            # highest severity seen: 0 ok, 1 warn, 2 fail
OK_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0

# Colors only when attached to a terminal -- a cron/systemd log shouldn't
# fill up with escape codes.
if [[ -t 1 ]]; then
	C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_RESET=$'\033[0m'
else
	C_OK=""; C_WARN=""; C_FAIL=""; C_RESET=""
fi

ok()      { OK_COUNT=$((OK_COUNT + 1));   printf '%s[ OK ]%s %s\n'   "$C_OK"   "$C_RESET" "$1"; }
warn()    { WARN_COUNT=$((WARN_COUNT + 1)); (( STATUS < 1 )) && STATUS=1; printf '%s[WARN]%s %s\n' "$C_WARN" "$C_RESET" "$1"; }
fail()    { FAIL_COUNT=$((FAIL_COUNT + 1)); STATUS=2; printf '%s[FAIL]%s %s\n' "$C_FAIL" "$C_RESET" "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. Containers: process state + Docker HEALTHCHECK, if the image defines one
# ---------------------------------------------------------------------------
section "Containers"
mapfile -t SERVICES < <(docker compose config --services)
for svc in "${SERVICES[@]}"; do
	cid="$(docker compose ps -q "$svc" 2>/dev/null)"
	if [[ -z "$cid" ]]; then
		fail "$svc: not running"
		continue
	fi
	state="$(docker inspect "$cid" --format '{{.State.Status}}')"
	health="$(docker inspect "$cid" --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')"
	if [[ "$state" != "running" ]]; then
		fail "$svc: container state is '$state'"
	elif [[ "$health" == "unhealthy" ]]; then
		fail "$svc: HEALTHCHECK reports unhealthy"
	elif [[ "$health" == "starting" ]]; then
		warn "$svc: HEALTHCHECK still starting"
	elif [[ -n "$health" ]]; then
		ok "$svc: running ($health)"
	else
		ok "$svc: running"
	fi
done

# ---------------------------------------------------------------------------
# 2. Per-container DNS: is the upstream resolver each container was handed at
# startup actually answering right now? This is the exact check that would
# have caught the 2026-09-10 outage automatically.
#
# Docker bakes a container's resolver config into
# /var/lib/docker/containers/<id>/resolv.conf at creation time and never
# touches it again while the container runs. The `# ExtServers:` comment in
# that file records which real DNS servers its embedded resolver (127.0.0.11)
# forwards to -- reading it (root-only) and querying those servers directly
# from the host tells us what that specific container has been stuck with,
# without needing a shell inside every image (cloudflared's has none).
# ---------------------------------------------------------------------------
section "DNS (per-container upstream resolvers)"
dns_probe() {
	# Sends one raw A/AAAA query for github.com to $1 and exits 0 on a
	# real (non-SERVFAIL) answer. No external module needed -- python3
	# ships on Raspberry Pi OS by default.
	python3 - "$1" <<'PYEOF' 2>/dev/null
import socket, struct, sys
ip = sys.argv[1]
fam = socket.AF_INET6 if ":" in ip else socket.AF_INET
q = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0)
for part in "github.com".split("."):
    q += struct.pack("B", len(part)) + part.encode()
q += b"\x00" + struct.pack(">HH", 1, 1)
s = socket.socket(fam, socket.SOCK_DGRAM)
s.settimeout(3)
try:
    s.sendto(q, (ip, 53))
    data, _ = s.recvfrom(512)
    sys.exit(0 if (data[3] & 0x0F) == 0 else 1)
except OSError:
    sys.exit(1)
PYEOF
}

for svc in "${SERVICES[@]}"; do
	cid="$(docker compose ps -q "$svc" 2>/dev/null)"
	[[ -z "$cid" ]] && continue   # already flagged as down above

	full_id="$(docker inspect "$cid" --format '{{.Id}}')"
	resolv="/var/lib/docker/containers/$full_id/resolv.conf"
	# -n: fail fast instead of hanging on a password prompt if this ever
	# runs somewhere without passwordless sudo configured.
	servers="$(sudo -n sed -n 's/.*ExtServers: \[\(.*\)\]/\1/p' "$resolv" 2>/dev/null \
		| grep -oE '[0-9a-fA-F:.]+' | tr '\n' ' ')"
	servers="${servers% }"   # drop the trailing space from tr's join
	if [[ -z "$servers" ]]; then
		warn "$svc: couldn't read its resolver config (needs passwordless sudo)"
		continue
	fi
	broken=""
	for ip in $servers; do
		dns_probe "$ip" || broken+="$ip "
	done
	if [[ -n "$broken" ]]; then
		fail "$svc: DNS upstream not answering (${broken% }) -- restart the container to pick up a working resolver"
	else
		ok "$svc: DNS upstream answering ($servers)"
	fi
done

# ---------------------------------------------------------------------------
# 3. Internal app responses -- direct container-to-container, bypassing Caddy
# and the tunnel entirely. Separates "the app itself is broken" from
# "something in the public path is broken", which the next section can't.
# ---------------------------------------------------------------------------
section "Internal app responses (direct, bypassing the tunnel)"
INTERNAL_HTTP_SERVICES=(stock stock-demo fitness fitness-demo dnd ffta)
for svc in "${INTERNAL_HTTP_SERVICES[@]}"; do
	cid="$(docker compose ps -q "$svc" 2>/dev/null)"
	[[ -z "$cid" ]] && continue   # already flagged as down above

	# Every one of these is Python behind gunicorn, so urllib is guaranteed
	# present -- no extra tooling needed just for a health probe.
	if docker compose exec -T "$svc" python -c "
import urllib.request
urllib.request.urlopen('http://localhost:8080/', timeout=5)
" >/dev/null 2>&1; then
		ok "$svc: answers on :8080 internally"
	else
		fail "$svc: not answering on :8080 internally -- container is up but the app inside it is not"
	fi
done

# ---------------------------------------------------------------------------
# 4. Public endpoints -- the full external path: Cloudflare edge -> tunnel ->
# Caddy -> app. Checked against the exact status each site is *supposed* to
# return, since a password prompt (401) or a login redirect (302) is success,
# not failure, for those two.
# ---------------------------------------------------------------------------
section "Public endpoints (external path, via Cloudflare)"
# url;expected_status;extra_curl_flags
ENDPOINTS=(
	"https://${DOMAIN}/;200;"
	"https://www.${DOMAIN}/;301;"
	"https://stocks.${DOMAIN}/;200;"
	"https://fitness.${DOMAIN}/;200;"
	"https://dnd.${DOMAIN}/;200;-L"     # -L: follow the /login redirect
	"https://fantasy.${DOMAIN}/;401;"   # expected -- password required
)
for entry in "${ENDPOINTS[@]}"; do
	IFS=';' read -r url want flag <<< "$entry"
	# shellcheck disable=SC2086  # $flag is an intentional optional curl flag
	got="$(curl -sS -o /dev/null -w '%{http_code}' $flag --max-time 10 "$url" 2>/dev/null || echo 000)"
	if [[ "$got" == "$want" ]]; then
		ok "$url -> $got"
	else
		fail "$url -> $got (expected $want)"
	fi
done

# ---------------------------------------------------------------------------
# 5. Tailscale -- surfaces the exact health line that flagged the DNS bug
# ---------------------------------------------------------------------------
section "Tailscale"
if ! systemctl is-active --quiet tailscaled; then
	fail "tailscaled is not running"
else
	ok "tailscaled is running"
	health="$(tailscale status 2>/dev/null | sed -n '/^# Health check:/,$ { /^#/p }' | sed '1d;s/^#\s*//')"
	if [[ -n "$health" ]]; then
		warn "tailscale reports: $(tr '\n' ' ' <<< "$health")"
	else
		ok "tailscale reports no health issues"
	fi
fi

# ---------------------------------------------------------------------------
# 6. systemd timers -- did the last scheduled run actually succeed?
# ---------------------------------------------------------------------------
section "systemd timers"
TIMERS=(homelab-backup ffta-sync ffta-values ffta-r2-sync stock-refresh stock-tldr)
for t in "${TIMERS[@]}"; do
	if ! systemctl list-unit-files "${t}.timer" &>/dev/null || \
		! systemctl is-active --quiet "${t}.timer"; then
		fail "$t.timer is not active"
		continue
	fi
	if systemctl is-failed --quiet "${t}.service"; then
		fail "$t.service failed on its last run"
	else
		ok "$t.timer active, last run OK"
	fi
done

# ---------------------------------------------------------------------------
# 7. Disk space & backup freshness -- cheap, and the SD card is the one part
# of this stack with no redundancy at all.
# ---------------------------------------------------------------------------
section "Disk & backups"
use_pct="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
if (( use_pct >= 90 )); then
	fail "root filesystem at ${use_pct}% -- SD card nearly full"
elif (( use_pct >= 80 )); then
	warn "root filesystem at ${use_pct}%"
else
	ok "root filesystem at ${use_pct}%"
fi

BACKUP_DIR="${BACKUP_DIR:-/opt/homelab/backups}"
if find "$BACKUP_DIR" -maxdepth 1 -type f -mtime -1 2>/dev/null | grep -q .; then
	ok "a backup younger than 24h exists in $BACKUP_DIR"
else
	warn "no backup younger than 24h in $BACKUP_DIR"
fi

# ---------------------------------------------------------------------------
section "Summary"
printf 'ok=%d warn=%d fail=%d\n' "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
exit "$STATUS"
