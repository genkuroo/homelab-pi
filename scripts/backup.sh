#!/usr/bin/env bash
# Nightly backup of every SQLite database in the stack.
#
# Why not just `cp` the .db files: SQLite writes are not atomic at the file
# level. Copying a database while the web app is mid-write can capture a
# torn page and produce a backup that only *looks* fine until you restore it.
# sqlite3's backup API takes a proper read lock and produces a consistent
# snapshot of a live database, which is exactly the guarantee wanted here.
#
# Run by homelab-backup.timer. Restore is just: gunzip and drop the file back
# into the volume.

set -euo pipefail

cd "$(dirname "$0")/.."

DEST="${BACKUP_DIR:-/opt/homelab/backups}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$DEST"

# service:path-inside-container — only the instances holding real data. The
# demo databases are regenerated from seed scripts, so backing them up would
# just be storing reproducible noise.
TARGETS=(
	"stock:/data/stocks.db"
	"fitness:/data/fitness.db"
	# The league data here could be re-synced from Sleeper, but the daily
	# market-value snapshots could not — FantasyCalc serves current values only
	# and has no history endpoint. Losing this file loses the ability to grade a
	# past trade against the values that were true when it was made.
	"ffta:/data/ffta.db"
)

backup_one() {
	local svc="$1" db="$2"
	local name; name="$(basename "$db" .db)"
	local out="$DEST/${name}-${STAMP}.db"

	if ! docker compose ps --status running --services | grep -qx "$svc"; then
		echo "skip: $svc is not running"
		return 0
	fi

	# The apps are Python, so the sqlite3 module is guaranteed present in the
	# image — no need to install a sqlite3 CLI just for backups.
	docker compose exec -T "$svc" python -c "
import sqlite3
src = sqlite3.connect('$db')
dst = sqlite3.connect('/tmp/_backup.db')
with dst:
    src.backup(dst)
dst.close(); src.close()
"
	docker compose cp "$svc:/tmp/_backup.db" "$out"
	docker compose exec -T "$svc" rm -f /tmp/_backup.db
	gzip -f "$out"
	echo "backed up $svc -> ${out}.gz"
}

for t in "${TARGETS[@]}"; do
	backup_one "${t%%:*}" "${t#*:}"
done

# The D&D tracker keeps a folder of per-campaign databases plus uploaded avatar
# and map images, so it gets an archive of the whole volume rather than a
# single-file snapshot. Same rule as above, though: every .db inside goes
# through sqlite3's backup API first (a plain tar of a live database can catch
# a torn page), and everything else is copied as-is. The archive's layout is
# unchanged, so a restore is still: untar into the volume.
if docker compose ps --status running --services | grep -qx dnd; then
	docker compose exec -T dnd python -c "
import os, sqlite3, tarfile, tempfile
with tempfile.TemporaryDirectory() as snap, tarfile.open('/tmp/_dnd.tar.gz', 'w:gz') as tar:
    for root, _, files in os.walk('/data'):
        for f in files:
            src = os.path.join(root, f)
            rel = os.path.relpath(src, '/data')
            if f.endswith('.db'):
                copy = os.path.join(snap, rel.replace(os.sep, '__'))
                s, d = sqlite3.connect(src), sqlite3.connect(copy)
                with d:
                    s.backup(d)
                d.close(); s.close()
                tar.add(copy, arcname='./' + rel)
            else:
                tar.add(src, arcname='./' + rel)
"
	docker compose cp dnd:/tmp/_dnd.tar.gz "$DEST/dnd-${STAMP}.tar.gz"
	docker compose exec -T dnd rm -f /tmp/_dnd.tar.gz
	echo "backed up dnd -> $DEST/dnd-${STAMP}.tar.gz"
fi

# Prune old backups. Deletes only files this script's naming scheme produces.
find "$DEST" -maxdepth 1 -type f \( -name '*.db.gz' -o -name 'dnd-*.tar.gz' \) \
	-mtime "+${KEEP_DAYS}" -print -delete

echo "backup complete: $(date -Is)"
