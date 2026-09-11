#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# skipjackscn/cst - Tailscale Linux AMD64 Exit Node installer
# ============================================================
#
# One-command install:
#   curl -fsSL https://raw.githubusercontent.com/skipjackscn/cst/main/scripts/install-tailscale-exit.sh | sudo bash -s -- 'tskey-auth-xxxxxxxx'
#
# GitHub Actions / existing convention in this repository:
#   TAILSCALE_AUTHKEY='tskey-auth-xxxxxxxx' ...
#
# Optional environment variables:
#   TAILSCALE_AUTHKEY   Auth key (preferred repository convention)
#   TAILSCALE_AUTH_KEY  Alias for TAILSCALE_AUTHKEY
#   TAILSCALE_TAG       Default: tag:exit-node
#   TAILSCALE_HOSTNAME  Default: <system-hostname>-exit
#
# Tailnet policy (one-time setup) for automatic Exit Node approval:
#   "autoApprovers": {
#     "exitNode": ["tag:exit-node"]
#   }
#
# If your Tailnet already uses a different tag, set TAILSCALE_TAG
# accordingly. Do not put the Auth Key into this repository.
# ============================================================

VERSION="2.0.0"
TAG="${TAILSCALE_TAG:-tag:exit-node}"
AUTH_KEY="${1:-${TAILSCALE_AUTHKEY:-${TAILSCALE_AUTH_KEY:-}}}"

log()  { printf '\n[INFO] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

trap 'fail "Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

[[ "$EUID" -eq 0 ]] || fail "Please run as root (normally: sudo bash ...)."

ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] || fail "This installer targets Linux AMD64/x86_64. Detected: $ARCH"

[[ -n "$AUTH_KEY" ]] || fail "Tailscale Auth Key is required. Example: sudo bash install-tailscale-exit.sh 'tskey-auth-xxxxx'"

# Generate a safe default hostname unless the caller supplied one.
if [[ -z "${TAILSCALE_HOSTNAME:-}" ]]; then
  BASE_HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo linux)"
  BASE_HOST="$(printf '%s' "$BASE_HOST" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/^-*//; s/-*$//')"
  [[ -n "$BASE_HOST" ]] || BASE_HOST="linux"
  TAILSCALE_HOSTNAME="${BASE_HOST}-exit"
fi

log "skipjackscn/cst Tailscale Exit Node installer v${VERSION}"
printf '  OS       : %s\n' "$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}" || printf 'unknown')"
printf '  Arch     : %s\n' "$ARCH"
printf '  Hostname : %s\n' "$TAILSCALE_HOSTNAME"
printf '  Tag      : %s\n' "$TAG"

# ------------------------------------------------------------
# 1. Install basic dependencies
# ------------------------------------------------------------
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
ok "Basic dependencies installed."

# ------------------------------------------------------------
# 2. Install/update Tailscale using the official installer
# ------------------------------------------------------------
log "Installing/updating Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
command -v tailscale >/dev/null 2>&1 || fail "tailscale command was not installed."
ok "Tailscale installed: $(tailscale version | head -n1)"

# ------------------------------------------------------------
# 3. Enable and persist IP forwarding for Exit Node
# ------------------------------------------------------------
log "Enabling persistent IPv4/IPv6 forwarding..."
cat >/etc/sysctl.d/99-tailscale-cst-exit.conf <<'EOF'
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
# 4. Start tailscaled and enable it at boot
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
# 5. Join Tailnet and advertise this machine as Exit Node
# ------------------------------------------------------------
log "Configuring Tailnet and advertising this machine as an Exit Node..."

if tailscale ip -4 >/dev/null 2>&1 || tailscale ip -6 >/dev/null 2>&1; then
  # Already authenticated: preserve node identity and only update settings.
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

# Do not keep the Auth Key in the shell environment.
unset AUTH_KEY

# ------------------------------------------------------------
# 6. Wait for Tailscale address and verify
# ------------------------------------------------------------
TS4=""
TS6=""
for _ in $(seq 1 30); do
  TS4="$(tailscale ip -4 2>/dev/null || true)"
  TS6="$(tailscale ip -6 2>/dev/null || true)"
  [[ -n "$TS4" || -n "$TS6" ]] && break
  sleep 1
done

[[ -n "$TS4" || -n "$TS6" ]] || {
  tailscale status || true
  fail "Tailscale joined but no Tailscale IP was assigned."
}

# Verify the local preference where available.
PREFS="$(tailscale debug prefs 2>/dev/null || true)"
if grep -qi 'AdvertiseExitNode.*true' <<<"$PREFS"; then
  EXIT_STATE="enabled"
else
  EXIT_STATE="advertised/configured"
fi

# ------------------------------------------------------------
# Final output - never print the Auth Key
# ------------------------------------------------------------
log "Installation complete."
printf '\n%-18s %s\n' 'Tailscale IPv4:' "${TS4:-N/A}"
printf '%-18s %s\n' 'Tailscale IPv6:' "${TS6:-N/A}"
printf '%-18s %s\n' 'Hostname:' "$TAILSCALE_HOSTNAME"
printf '%-18s %s\n' 'Exit Node:' "$EXIT_STATE"
printf '%-18s %s\n' 'Tag:' "$TAG"
printf '%-18s %s\n' 'IPv4 forwarding:' "$(sysctl -n net.ipv4.ip_forward)"
printf '%-18s %s\n' 'IPv6 forwarding:' "$(sysctl -n net.ipv6.conf.all.forwarding)"

echo
echo '--- tailscale status ---'
tailscale status || true

echo
echo '--- exit-node related preferences ---'
grep -Ei 'AdvertiseExitNode|AdvertiseRoutes|Hostname' <<<"$PREFS" || true

echo
echo '============================================================'
echo ' TAILSCALE EXIT NODE READY'
echo '============================================================'
echo "Node: $TAILSCALE_HOSTNAME"
echo "Tag : $TAG"
echo
echo 'Automatic Exit Node approval requires this one-time Tailnet policy:'
echo '  "autoApprovers": {'
echo '    "exitNode": ["tag:exit-node"]'
echo '  }'
echo
echo 'If your Tailnet uses a different tag, make the policy match TAILSCALE_TAG.'
echo '============================================================'
