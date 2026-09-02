#!/usr/bin/env bash
# One-time setup for a fresh Raspberry Pi OS Lite (64-bit) install.
#
# Idempotent — safe to re-run after changing a systemd unit or the compose file.
#
#   ssh ethan@raspberrypi.local
#   sudo mkdir -p /opt/homelab && sudo chown "$USER" /opt/homelab
#   git clone <this repo> /opt/homelab && cd /opt/homelab
#   cp .env.example .env && nano .env      # fill in DOMAIN + secrets first
#   ./scripts/bootstrap.sh

set -euo pipefail

REPO_DIR="/opt/homelab"
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
	echo "error: .env not found. Copy .env.example to .env and fill it in first." >&2
	exit 1
fi
# shellcheck disable=SC1091
set -a; source .env; set +a

echo "==> Setting timezone to ${TZ}"
# Pi OS defaults to UTC. The stock timers are pegged to US market close, so
# skipping this makes the "4pm" job fire at 9am Pacific.
sudo timedatectl set-timezone "$TZ"

echo "==> Installing Docker"
if ! command -v docker >/dev/null; then
	curl -fsSL https://get.docker.com | sudo sh
	sudo usermod -aG docker "$USER"
	echo "    NOTE: log out and back in for the docker group to take effect."
fi

echo "==> Installing Tailscale"
if ! command -v tailscale >/dev/null; then
	curl -fsSL https://tailscale.com/install.sh | sh
	echo "    Run 'sudo tailscale up' and follow the login link."
fi

echo "==> Reducing SD card wear"
# Every SQLite write updates an inode access time otherwise. On a card that is
# already the weakest link in this build, that is free wear for no benefit.
if ! grep -q "noatime" /etc/fstab; then
	echo "    Add 'noatime' to the root filesystem options in /etc/fstab manually,"
	echo "    then reboot. Skipping automatic edit — /etc/fstab is worth eyeballing."
fi

echo "==> Installing systemd timers"
sudo cp systemd/*.service systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
for t in stock-refresh stock-tldr ffta-sync ffta-values ffta-r2-sync homelab-backup; do
	sudo systemctl enable --now "${t}.timer"
done

echo "==> Building and starting the stack"
docker compose up -d --build

echo "==> Exposing the private dashboards on your tailnet"
# These two hold real data and are bound to 127.0.0.1 in compose, so this is
# the only path to them. Tailscale issues a real cert for the *.ts.net name,
# so it is https in the browser with no warnings.
sudo tailscale serve --bg --https 443 http://127.0.0.1:5001   # stock  (real)
sudo tailscale serve --bg --https 8443 http://127.0.0.1:5002  # fitness (real)
# The fantasy analyzer is here rather than public for a different reason than
# the other two: its data is not personal, but it republishes nine other
# league members' names and teams and it has no login of its own.
sudo tailscale serve --bg --https 8444 http://127.0.0.1:5003  # fantasy (real)

cat <<EOF

Done.

Public (anyone with the link, synthetic data):
  https://stocks.${DOMAIN}
  https://fitness.${DOMAIN}
  https://dnd.${DOMAIN}          <- share this one with your players

Private (your devices only, real data):
  https://\$(tailscale status --json | grep -o '"DNSName":"[^"]*' | head -1 | cut -d'"' -f4 | sed 's/\.$//')
  ...same host on :8443 for fitness
  ...same host on :8444 for the fantasy trade analyzer

Check the schedule:   systemctl list-timers 'stock-*' 'ffta-*' homelab-backup.timer
Off-site backup:      ./scripts/r2-sync.sh verify   (needs R2_* in .env)
Follow the logs:      journalctl -u stock-refresh -f
Force a run now:      sudo systemctl start stock-refresh.service
EOF
