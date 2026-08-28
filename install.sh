#!/usr/bin/env bash
#
# IPDR / NAT Log Server — one-shot installer
# Author: Ali Asad <aliasad4t@gmail.com>
# Project: KK Networks IPDR/NAT Log Server
#
# Stack: VictoriaLogs (compressed columnar log storage)
#      + Vector       (syslog/RADIUS ingestion + parsing)
#      + Grafana OSS  (dashboards / search UI)
#
# Usage:
#   sudo bash install.sh
#
# Tested target: Ubuntu 22.04 / 24.04 LTS, x86_64 or arm64
#
set -euo pipefail

# ── Editable settings ────────────────────────────────────────────────
VLOGS_HTTP_PORT=9428          # VictoriaLogs HTTP/query port
SYSLOG_UDP_PORT=514           # Juniper / RADIUS syslog listener (UDP)
SYSLOG_TCP_PORT=514           # Juniper / RADIUS syslog listener (TCP)
GRAFANA_PORT=3000
RETENTION_PERIOD="12"         # months of log retention (compliance window)
DATA_DIR="/var/lib/victoria-logs"
INSTALL_DIR="/opt/ipdr-logserver"
RADIUS_DETAIL_GLOB="/var/log/radius/radacct/*/detail-*"   # adjust to your freeradius layout
# ─────────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash install.sh"
  exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  VL_ARCH="amd64" ;;
  aarch64) VL_ARCH="arm64" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

echo "=============================================="
echo " IPDR/NAT Log Server — automated install"
echo " Author: Ali Asad <aliasad4t@gmail.com>"
echo "=============================================="

apt-get update -y
apt-get install -y curl wget tar ufw apt-transport-https software-properties-common gnupg

mkdir -p "$INSTALL_DIR" "$DATA_DIR"
cd "$INSTALL_DIR"

# ── 1. Install VictoriaLogs ────────────────────────────────────────
echo "[1/5] Installing VictoriaLogs..."
VL_TAG=$(curl -s https://api.github.com/repos/VictoriaMetrics/VictoriaLogs/releases/latest \
  | grep '"tag_name"' | head -1 | cut -d '"' -f4 || true)
VL_TAG=${VL_TAG:-v1.52.0}   # fallback pin if API rate-limited
VL_VER=${VL_TAG#v}

curl -L -o victoria-logs.tar.gz \
  "https://github.com/VictoriaMetrics/VictoriaLogs/releases/download/${VL_TAG}/victoria-logs-linux-${VL_ARCH}-${VL_TAG}.tar.gz"
tar xzf victoria-logs.tar.gz
mv victoria-logs-prod /usr/local/bin/victoria-logs
chmod +x /usr/local/bin/victoria-logs
rm -f victoria-logs.tar.gz

id -u vlogs &>/dev/null || useradd -r -s /usr/sbin/nologin vlogs
chown -R vlogs:vlogs "$DATA_DIR"

cat > /etc/systemd/system/victoria-logs.service <<EOF
[Unit]
Description=VictoriaLogs
After=network.target

[Service]
Type=simple
User=vlogs
Group=vlogs
ExecStart=/usr/local/bin/victoria-logs \\
  -storageDataPath=${DATA_DIR} \\
  -httpListenAddr=:${VLOGS_HTTP_PORT} \\
  -retentionPeriod=${RETENTION_PERIOD}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# ── 2. Install Vector (log shipper / parser) ───────────────────────
echo "[2/5] Installing Vector..."
curl --proto '=https' --tlsv1.2 -sSfL https://sh.vector.dev | bash -s -- -y
cp "$(dirname "$0")/config/vector.toml" /etc/vector/vector.toml 2>/dev/null || true

# ── 3. Install Grafana OSS ──────────────────────────────────────────
echo "[3/5] Installing Grafana..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt-get update -y
apt-get install -y grafana

# VictoriaLogs datasource plugin for Grafana
grafana-cli plugins install victoriametrics-logs-datasource || true
echo "GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=victoriametrics-logs-datasource" \
  >> /etc/default/grafana-server 2>/dev/null || true

mkdir -p /etc/grafana/provisioning/datasources
cp "$(dirname "$0")/config/grafana-datasource.yaml" \
   /etc/grafana/provisioning/datasources/victorialogs.yaml 2>/dev/null || true

# ── 4. Firewall ──────────────────────────────────────────────────────
echo "[4/5] Configuring firewall..."
ufw allow ${SYSLOG_UDP_PORT}/udp  >/dev/null 2>&1 || true
ufw allow ${SYSLOG_TCP_PORT}/tcp  >/dev/null 2>&1 || true
ufw allow ${GRAFANA_PORT}/tcp     >/dev/null 2>&1 || true
ufw allow ${VLOGS_HTTP_PORT}/tcp  >/dev/null 2>&1 || true

# ── 5. Start everything ─────────────────────────────────────────────
echo "[5/5] Starting services..."
systemctl daemon-reload
systemctl enable --now victoria-logs
systemctl enable --now vector
systemctl enable --now grafana-server

sleep 3

echo ""
echo "=============================================="
echo " Install complete — log server is LIVE"
echo "=============================================="
echo " VictoriaLogs UI/API : http://$(hostname -I | awk '{print $1}'):${VLOGS_HTTP_PORT}"
echo " Grafana dashboard   : http://$(hostname -I | awk '{print $1}'):${GRAFANA_PORT}  (default admin/admin)"
echo " Syslog listener     : UDP/TCP ${SYSLOG_UDP_PORT} (point Juniper 'log <ip>' / RADIUS syslog here)"
echo ""
echo " Next steps:"
echo "  1. On each Juniper MX/ACX: configure syslog forwarding to this server's IP, port ${SYSLOG_UDP_PORT}"
echo "  2. Edit /etc/vector/vector.toml if your NAT/RADIUS log format needs different field parsing"
echo "  3. Login to Grafana, VictoriaLogs datasource is pre-provisioned — start querying with LogsQL"
echo ""
echo " Retention: ${RETENTION_PERIOD} months (edit RETENTION_PERIOD in this script + rerun to change)"
echo "=============================================="
