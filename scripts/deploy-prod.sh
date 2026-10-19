#!/usr/bin/env bash
# Redeploys dnd (prod) from the latest dnd-campaign-tracker main branch.
#
# Invoked two ways: by hand, and as the one command a restricted SSH deploy
# key is allowed to run (see the authorized_keys entry on this host) -- the
# promote-prod GitHub Actions workflow in dnd-campaign-tracker SSHes in with
# that key after a human approves the deploy via the `production` GitHub
# Environment. Deliberately narrow: touches only dnd, never caddy, staging,
# or any other service, so a promotion can never take down anything else.
# See dnd-campaign-tracker/docs/CICD_PLAN.md.

set -euo pipefail

echo "=== dnd (prod) deploy: $(date -Is) ==="

# Hard reset, not a merge -- this checkout is a deploy target, not a dev
# workspace, so it should never carry local changes. Shared with
# deploy-staging.sh: dnd and dnd-staging build from the same checkout.
cd /opt/dnd-campaign-tracker
git fetch origin main
git reset --hard origin/main
echo "dnd-campaign-tracker at $(git rev-parse --short HEAD)"

cd /opt/homelab
docker compose build dnd
docker compose up -d dnd

echo "=== deploy complete: $(date -Is) ==="
