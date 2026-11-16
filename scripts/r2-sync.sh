#!/usr/bin/env bash
# Ships the ff-trade-analyzer and D&D backups to a Cloudflare R2 bucket.
#
# Why this exists: the Pi boots from an SD card, and the nightly backups land on
# that same card. If it fails, the live database and every backup go together.
# Most of what is in the stack could be re-fetched afterwards -- Sleeper still
# has the transactions, yfinance still has the prices -- but the analyzer's
# daily market-value snapshots could not. FantasyCalc serves current values only
# and has no history endpoint, so a lost snapshot is lost permanently. That is
# the half worth getting off the device.
#
# The D&D tracker's campaigns are the other thing nothing could rebuild: they're
# my players' sessions, notes and maps, typed in by hand. Added 2026-11-14.
#
# Deliberately those two only. The same folder holds real bodyweight history and
# real stock holdings, and those stay in the house.
#
# Local backups are pruned at 14 days; this uses `rclone copy`, which never
# deletes at the destination, so R2 is the long archive and the card is just the
# recent working copy. At roughly a megabyte a night that is a few hundred MB a
# year (plus ~0.5 MB a night for D&D) against a 10 GB free tier.
#
#   ./scripts/r2-sync.sh          upload anything new
#   ./scripts/r2-sync.sh verify   show what is actually in the bucket

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
[ -f .env ] && set -a && . ./.env && set +a

SRC="${BACKUP_DIR:-/opt/homelab/backups}"
PREFIX="${R2_PREFIX:-ffta}"         # ffta's folder in the bucket (historical name)
DND_PREFIX="${R2_DND_PREFIX:-dnd}"
IMAGE="${RCLONE_IMAGE:-rclone/rclone:latest}"

if [ -z "${R2_ACCOUNT_ID:-}" ] || [ -z "${R2_ACCESS_KEY_ID:-}" ] ||
   [ -z "${R2_SECRET_ACCESS_KEY:-}" ] || [ -z "${R2_BUCKET:-}" ]; then
	echo "R2 is not configured (R2_ACCOUNT_ID / R2_ACCESS_KEY_ID /"
	echo "R2_SECRET_ACCESS_KEY / R2_BUCKET in .env) — skipping."
	# Not an error: the off-site copy is optional, and a nightly timer failing
	# loudly for an unconfigured feature is noise rather than signal.
	exit 0
fi

# rclone is configured entirely through the environment, so no config file has
# to be written and no secret ever appears in a command line or in `ps`.
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
# All configuration comes from the environment, so point rclone at an empty
# config rather than letting it warn nightly that it could not find one.
export RCLONE_CONFIG=/dev/null

# `-e NAME` with no value passes the variable through from this shell rather
# than putting its value on the command line.
run_rclone() {
	docker run --rm \
		-v "$SRC:/backup:ro" \
		-e RCLONE_CONFIG_R2_TYPE \
		-e RCLONE_CONFIG_R2_PROVIDER \
		-e RCLONE_CONFIG_R2_ACCESS_KEY_ID \
		-e RCLONE_CONFIG_R2_SECRET_ACCESS_KEY \
		-e RCLONE_CONFIG_R2_ENDPOINT \
		-e RCLONE_CONFIG_R2_NO_CHECK_BUCKET \
		-e RCLONE_CONFIG \
		"$IMAGE" "$@"
}

# name|folder in the bucket|files to send
SETS=(
	"ffta|${PREFIX}|ffta-*.db.gz"
	"dnd|${DND_PREFIX}|dnd-*.tar.gz"
)

if [ "${1:-upload}" = "verify" ]; then
	for set in "${SETS[@]}"; do
		IFS='|' read -r _ prefix _ <<<"$set"
		echo "objects in r2://${R2_BUCKET}/${prefix}:"
		run_rclone lsl "R2:${R2_BUCKET}/${prefix}" | sort -k4 | tail -20
		echo
		run_rclone size "R2:${R2_BUCKET}/${prefix}"
		echo
	done
	exit 0
fi

for set in "${SETS[@]}"; do
	IFS='|' read -r name prefix pattern <<<"$set"
	echo "uploading ${name} backups -> r2://${R2_BUCKET}/${prefix}"
	run_rclone copy /backup "R2:${R2_BUCKET}/${prefix}" \
		--include "$pattern" \
		--no-traverse \
		--stats-one-line \
		--stats 0
	count=$(run_rclone lsf "R2:${R2_BUCKET}/${prefix}" | wc -l | tr -d ' ')
	echo "done — ${count} ${name} snapshot(s) archived off-device"
done
