#!/usr/bin/env bash
# Redeploys dnd-staging from the latest dnd-campaign-tracker main branch.
#
# Invoked two ways: by hand, and as the one command a restricted SSH deploy
# key is allowed to run (see the authorized_keys entry on this host) -- the
# GitHub Actions workflow in dnd-campaign-tracker SSHes in with that key
# after its test suite passes. Deliberately narrow: touches only dnd-staging,
# never caddy or any other service, so a routine app-code deploy can never
# take down anything public. See dnd-campaign-tracker/docs/CICD_PLAN.md.

set -euo pipefail

echo "=== dnd-staging deploy: $(date -Is) ==="

# Hard reset, not a merge -- this checkout is a deploy target, not a dev
# workspace, so it should never carry local changes. Robust against any
# stray drift in a way `git pull` (which can fail on diverged history) isn't.
cd /opt/dnd-campaign-tracker
git fetch origin main
git reset --hard origin/main
echo "dnd-campaign-tracker at $(git rev-parse --short HEAD)"

cd /opt/homelab
docker compose build dnd-staging
docker compose up -d dnd-staging

echo "=== deploy complete: $(date -Is) ==="
