#!/usr/bin/env bash
# Ships the ff-trade-analyzer backups to a Cloudflare R2 bucket.
#
# Why this exists: the Pi boots from an SD card, and the nightly backups land on
# that same card. If it fails, the live database and every backup go together.
# Most of what is in the stack could be re-fetched afterwards -- Sleeper still
# has the transactions, yfinance still has the prices -- but the analyzer's
# daily market-value snapshots could not. FantasyCalc serves current values only
# and has no history endpoint, so a lost snapshot is lost permanently. That is
# the half worth getting off the device.
#
# Deliberately ffta only. The same folder holds real bodyweight history and real
# stock holdings, and those stay in the house.
#
# Local backups are pruned at 14 days; this uses `rclone copy`, which never
# deletes at the destination, so R2 is the long archive and the card is just the
# recent working copy. At roughly a megabyte a night that is a few hundred MB a
# year against a 10 GB free tier.
#
#   ./scripts/r2-sync.sh          upload anything new
#   ./scripts/r2-sync.sh verify   show what is actually in the bucket

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
[ -f .env ] && set -a && . ./.env && set +a

SRC="${BACKUP_DIR:-/opt/homelab/backups}"
PREFIX="${R2_PREFIX:-ffta}"
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

if [ "${1:-upload}" = "verify" ]; then
	echo "objects in r2://${R2_BUCKET}/${PREFIX}:"
	run_rclone lsl "R2:${R2_BUCKET}/${PREFIX}" | sort -k4 | tail -20
	echo
	run_rclone size "R2:${R2_BUCKET}/${PREFIX}"
	exit 0
fi

echo "uploading ffta backups -> r2://${R2_BUCKET}/${PREFIX}"
run_rclone copy /backup "R2:${R2_BUCKET}/${PREFIX}" \
	--include 'ffta-*.db.gz' \
	--no-traverse \
	--stats-one-line \
	--stats 0

count=$(run_rclone lsf "R2:${R2_BUCKET}/${PREFIX}" | wc -l | tr -d ' ')
echo "done — ${count} snapshot(s) archived off-device"
