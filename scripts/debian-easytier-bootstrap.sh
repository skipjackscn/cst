#!/bin/bash
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
  echo "ERROR: bootstrap must run as root" >&2
  exit 1
fi

ENV_FILE=/root/easytier.env
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"
: "${ET_NAME_B64:?missing ET_NAME_B64}"
: "${ET_SECRET_B64:?missing ET_SECRET_B64}"
: "${ET_PEER_B64:?missing ET_PEER_B64}"
: "${ROOT_PASSWORD_B64:?missing ROOT_PASSWORD_B64}"

export DEBIAN_FRONTEND=noninteractive

b64dec() {
  printf '%s' "$1" | base64 -d
}

toml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

NET_NAME="$(b64dec "$ET_NAME_B64")"
NET_SECRET="$(b64dec "$ET_SECRET_B64")"
PEER="$(b64dec "$ET_PEER_B64")"
ROOT_PASSWORD="$(b64dec "$ROOT_PASSWORD_B64")"

printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget unzip openssh-server \
  iproute2 iputils-ping procps net-tools sudo

mkdir -p /run/sshd /root/.ssh /var/log/easytier
cat >/etc/ssh/sshd_config.d/99-cst.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
systemctl enable --now ssh

rm -rf /opt/easytier
mkdir -p /opt/easytier
wget -qO /tmp/easytier-install.sh \
  https://raw.githubusercontent.com/EasyTier/EasyTier/main/script/install.sh
bash /tmp/easytier-install.sh install /opt/easytier --no-gh-proxy

mkdir -p /opt/easytier/config
ESC_NAME="$(toml_escape "$NET_NAME")"
ESC_SECRET="$(toml_escape "$NET_SECRET")"
ESC_PEER="$(toml_escape "$PEER")"

cat >/opt/easytier/config/default.conf <<EOF
instance_name = "cst-debian"
hostname = "CST-DEBIAN"
ipv4 = "10.1.1.52/24"
dhcp = false
listeners = [
  "tcp://0.0.0.0:11010",
  "udp://0.0.0.0:11010",
  "wg://0.0.0.0:11011",
]
rpc_portal = "127.0.0.1:15888"

[network_identity]
network_name = "${ESC_NAME}"
network_secret = "${ESC_SECRET}"

[[peer]]
uri = "${ESC_PEER}"

[flags]
default_protocol = "udp"
enable_encryption = true
enable_ipv6 = false
latency_first = true
enable_exit_node = true
no_tun = false
foreign_network_whitelist = "*"
EOF
chmod 600 /opt/easytier/config/default.conf

cat >/etc/systemd/system/easytier.service <<'EOF'
[Unit]
Description=EasyTier Virtual Network
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/opt/easytier/easytier-core -c /opt/easytier/config/default.conf
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now easytier.service
sleep 5

if ! systemctl is-active --quiet easytier.service; then
  journalctl -u easytier.service --no-pager -n 120 || true
  exit 1
fi

/opt/easytier/easytier-cli --rpc-portal 127.0.0.1:15888 node || true

echo "Debian EasyTier bootstrap completed."
