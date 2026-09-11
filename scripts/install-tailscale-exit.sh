#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# skipjackscn/cst - Tailscale Linux AMD64 Exit Node installer
# ============================================================
# One-command usage:
#   curl -fsSL https://raw.githubusercontent.com/skipjackscn/cst/main/scripts/install-tailscale-exit.sh \
#     | sudo bash -s -- 'tskey-auth-xxxxxxxx'
#
# Optional environment variables:
#   TAILSCALE_TAG=tag:exit-node
#   TAILSCALE_HOSTNAME=custom-name
#   TAILSCALE_AUTH_KEY=tskey-auth-xxxxxxxx
#
# The Tailnet policy should contain:
#   "tagOwners": {
#     "tag:exit-node": ["autogroup:admin"]
#   },
#   "autoApprovers": {
#     "exitNode": ["tag:exit-node"]
#   }
#
# This makes the device's exit-node advertisement automatically approved.
# ============================================================

VERSION="1.1.0"
TAG="${TAILSCALE_TAG:-tag:exit-node}"
AUTH_KEY="${1:-${TAILSCALE_AUTH_KEY:-}}"

log()  { printf '\n[INFO] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

trap 'fail "Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

[[ "$EUID" -eq 0 ]] || fail "Please run as root (normally: sudo bash ...)."

ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] || fail "This installer targets Linux AMD64/x86_64. Detected: $ARCH"

[[ -n "$AUTH_KEY" ]] || fail "Tailscale Auth Key is required. Example: sudo bash install-tailscale-exit.sh 'tskey-auth-xxxxx'"

if [[ -z "${TAILSCALE_HOSTNAME:-}" ]]; then
  base="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo linux)"
  base="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/^-*//; s/-*$//')"
  [[ -n "$base" ]] || base="linux"
  TAILSCALE_HOSTNAME="${base}-exit"
fi

log "skipjackscn/cst Tailscale Exit Node installer v${VERSION}"
printf '  OS       : %s\n' "$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}" || printf 'unknown')"
printf '  Arch     : %s\n' "$ARCH"
printf '  Hostname : %s\n' "$TAILSCALE_HOSTNAME"
printf '  Tag      : %s\n' "$TAG"

# ------------------------------------------------------------
# Basic dependencies
# ------------------------------------------------------------
install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates iproute2 procps
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates iproute procps
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates iproute procps
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install curl ca-certificates iproute2 procps
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm curl ca-certificates iproute2 procps
  else
    fail "Unsupported package manager."
  fi
}

install_deps
ok "Basic dependencies installed."

# ------------------------------------------------------------
# Install/update Tailscale using the official installer.
# ------------------------------------------------------------
log "Installing/updating Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
command -v tailscale >/dev/null 2>&1 || fail "tailscale command was not installed."
ok "Tailscale installed: $(tailscale version | head -n1)"

# ------------------------------------------------------------
# Persistent IP forwarding required by Exit Node.
# ------------------------------------------------------------
log "Enabling persistent IPv4/IPv6 forwarding..."
cat >/etc/sysctl.d/99-tailscale-exit-node.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

sysctl --system >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || fail "IPv4 forwarding could not be enabled."
[[ "$(sysctl -n net.ipv6.conf.all.forwarding)" == "1" ]] || fail "IPv6 forwarding could not be enabled."
ok "IP forwarding enabled and persisted."

# ------------------------------------------------------------
# Start tailscaled and enable it at boot when systemd exists.
# ------------------------------------------------------------
log "Starting tailscaled..."
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files tailscaled.service >/dev/null 2>&1; then
  systemctl daemon-reload || true
  systemctl enable tailscaled >/dev/null 2>&1 || true
  systemctl restart tailscaled
  sleep 2
  systemctl is-active --quiet tailscaled || {
    systemctl status tailscaled --no-pager || true
    fail "tailscaled did not start."
  }
else
  if ! pgrep -x tailscaled >/dev/null 2>&1; then
    mkdir -p /var/lib/tailscale
    nohup tailscaled >/var/log/tailscaled.log 2>&1 &
    sleep 3
  fi
  pgrep -x tailscaled >/dev/null 2>&1 || {
    cat /var/log/tailscaled.log 2>/dev/null || true
    fail "tailscaled did not start."
  }
fi
ok "tailscaled is running."

# ------------------------------------------------------------
# Join the Tailnet / configure the existing node.
# ------------------------------------------------------------
log "Configuring Tailnet and advertising this machine as an Exit Node..."

if tailscale ip -4 >/dev/null 2>&1 || tailscale ip -6 >/dev/null 2>&1; then
  # Existing authenticated node: do not unnecessarily re-authenticate it.
  tailscale set \
    --hostname="$TAILSCALE_HOSTNAME" \
    --advertise-exit-node \
    --advertise-tags="$TAG"
else
  tailscale up \
    --auth-key="$AUTH_KEY" \
    --hostname="$TAILSCALE_HOSTNAME" \
    --advertise-exit-node \
    --advertise-tags="$TAG"
fi

# Never keep the Auth Key in the environment longer than necessary.
unset AUTH_KEY

# ------------------------------------------------------------
# Wait for Tailscale addresses.
# ------------------------------------------------------------
TS4=""
TS6=""
for _ in $(seq 1 30); do
  TS4="$(tailscale ip -4 2>/dev/null || true)"
  TS6="$(tailscale ip -6 2>/dev/null || true)"
  [[ -n "$TS4" || -n "$TS6" ]] && break
  sleep 1
done

[[ -n "$TS4" || -n "$TS6" ]] || fail "Tailscale joined but no Tailscale IP was assigned."

# ------------------------------------------------------------
# Final diagnostics.
# ------------------------------------------------------------
log "Installation complete."
printf '\n'
printf '%-18s %s\n' 'Tailscale IPv4:' "${TS4:-N/A}"
printf '%-18s %s\n' 'Tailscale IPv6:' "${TS6:-N/A}"
printf '%-18s %s\n' 'Hostname:' "$TAILSCALE_HOSTNAME"
printf '%-18s %s\n' 'Exit Node:' 'advertised'
printf '%-18s %s\n' 'Tag:' "$TAG"
printf '%-18s %s\n' 'IPv4 forwarding:' "$(sysctl -n net.ipv4.ip_forward)"
printf '%-18s %s\n' 'IPv6 forwarding:' "$(sysctl -n net.ipv6.conf.all.forwarding)"

echo
echo '--- tailscale status ---'
tailscale status || true

echo
echo '--- exit-node related preferences ---'
tailscale debug prefs 2>/dev/null | grep -Ei 'AdvertiseExitNode|AdvertiseRoutes|Hostname' || true

echo
echo '============================================================'
echo ' DONE'
echo '============================================================'
echo 'This node advertises itself as a Tailscale Exit Node.'
echo
echo 'For automatic approval, configure your Tailnet policy with:'
echo '  "autoApprovers": {'
echo '    "exitNode": ["tag:exit-node"]'
echo '  }'
echo
echo 'If you use a custom grants/ACL policy, clients also need access to:'
echo '  autogroup:internet'
echo '============================================================'
