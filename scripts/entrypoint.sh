#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 容器入口：创建/更新 RDP 账号、按注入端口配置 xrdp、按需拉起 EasyTier
# ---------------------------------------------------------------------------
set -Eeuo pipefail

log()  { echo -e "\033[1;36m[entrypoint]\033[0m $*"; }
warn() { echo -e "\033[1;33m[entrypoint]\033[0m $*"; }

# ---------------------------- 环境变量 -------------------------------------
RDP_USER="${RDP_USER:-rdpuser}"
RDP_UID="${RDP_UID:-1000}"
RDP_PASSWORD="${RDP_PASSWORD:-}"
SUDO_NOPASSWD="${SUDO_NOPASSWD:-true}"
XRDP_SECURITY_LAYER="${XRDP_SECURITY_LAYER:-negotiate}"

# Railway / Heroku 风格：平台注入的 PORT 优先
RDP_PORT="${PORT:-${RDP_PORT:-3389}}"
export RDP_PORT

# EasyTier 组网（全部可选；填了 name+secret 即启用）
EASYTIER_NETWORK_NAME="${EASYTIER_NETWORK_NAME:-}"
EASYTIER_NETWORK_SECRET="${EASYTIER_NETWORK_SECRET:-}"
EASYTIER_IPV4="${EASYTIER_IPV4:-}"
EASYTIER_HOSTNAME="${EASYTIER_HOSTNAME:-railway-rdp}"
EASYTIER_PEERS="${EASYTIER_PEERS:-}"
EASYTIER_LISTENERS="${EASYTIER_LISTENERS:-}"
EASYTIER_PROXY_NETWORKS="${EASYTIER_PROXY_NETWORKS:-}"
EASYTIER_RPC_PORTAL="${EASYTIER_RPC_PORTAL:-127.0.0.1:15888}"
EASYTIER_NO_TUN="${EASYTIER_NO_TUN:-true}"
EASYTIER_EXTRA_ARGS="${EASYTIER_EXTRA_ARGS:-}"

# ---------------------------- 时区 -----------------------------------------
if [[ -n "${TZ:-}" && -f "/usr/share/zoneinfo/${TZ}" ]]; then
  ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
  echo "${TZ}" > /etc/timezone
fi

# ---------------------------- 密码 -----------------------------------------
if [[ -z "${RDP_PASSWORD}" ]]; then
  if [[ -f /run/secrets/RDP_PASSWORD ]]; then
    RDP_PASSWORD="$(cat /run/secrets/RDP_PASSWORD)"
  else
    RDP_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 12)"
    warn "未设置 RDP_PASSWORD，已随机生成（请登录后尽快修改）"
  fi
fi

# ---------------------------- 账号 -----------------------------------------
if ! id -u "${RDP_USER}" >/dev/null 2>&1; then
  log "创建用户 ${RDP_USER} (uid=${RDP_UID})"
  useradd -m -s /bin/bash -u "${RDP_UID}" "${RDP_USER}"
fi

echo "${RDP_USER}:${RDP_PASSWORD}" | chpasswd
usermod -aG sudo,adm "${RDP_USER}" 2>/dev/null || true
mkdir -p "/home/${RDP_USER}/"{Desktop,Downloads,Documents}
chown -R "${RDP_USER}:${RDP_USER}" "/home/${RDP_USER}"

if [[ "${SUDO_NOPASSWD}" == "true" ]]; then
  echo "${RDP_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${RDP_USER}"
  chmod 0440 "/etc/sudoers.d/90-${RDP_USER}"
fi

cat > "/home/${RDP_USER}/.xsession" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session startxfce4
EOF
cat > "/home/${RDP_USER}/.xsessionrc" <<'EOF'
export DESKTOP_SESSION=xfce
export XDG_SESSION_DESKTOP=xfce
export XDG_CURRENT_DESKTOP=XFCE
EOF
chmod +x "/home/${RDP_USER}/.xsession"
chown "${RDP_USER}:${RDP_USER}" "/home/${RDP_USER}/.xsession" "/home/${RDP_USER}/.xsessionrc"

# ---------------------------- xrdp 配置 -------------------------------------
mkdir -p /run/xrdp /var/log/xrdp /run/dbus
chown -R xrdp:xrdp /run/xrdp /var/log/xrdp 2>/dev/null || true
echo "${RDP_PORT}" > /run/xrdp/runtime_port

if [[ ! -f /etc/xrdp/rsakeys.ini ]] && command -v xrdp-keygen >/dev/null 2>&1; then
  xrdp-keygen xrdp auto >/dev/null 2>&1 || true
fi

# 只替换 [Globals] 段里的第一个 port=（[Xorg]/[Xvnc] 段也有 port=-1，不能动）
sed -i "0,/^port=.*$/s//port=${RDP_PORT}/"                     /etc/xrdp/xrdp.ini
sed -i "s/^security_layer=.*/security_layer=${XRDP_SECURITY_LAYER}/" /etc/xrdp/xrdp.ini

# ---------------------------- EasyTier --------------------------------------
# 填了 network-name + network-secret 就自动启用；也可 EASYTIER_ENABLE=true/false 强制开关
EASYTIER_ENABLE="${EASYTIER_ENABLE:-auto}"
if [[ "$EASYTIER_ENABLE" == "auto" ]]; then
  if [[ -n "${EASYTIER_NETWORK_NAME:-}" && -n "${EASYTIER_NETWORK_SECRET:-}" ]]; then
    EASYTIER_ENABLE="true"
  else
    EASYTIER_ENABLE="false"
  fi
fi

ET_TIP="未启用"

if [[ "$EASYTIER_ENABLE" == "true" ]]; then
  if [[ -z "${EASYTIER_NETWORK_NAME:-}" || -z "${EASYTIER_NETWORK_SECRET:-}" ]]; then
    log "⚠️  EasyTier 已开启但缺少 EASYTIER_NETWORK_NAME / EASYTIER_NETWORK_SECRET，跳过"
  elif ! command -v easytier-core >/dev/null 2>&1; then
    log "⚠️  镜像里没有 easytier-core，跳过"
  else
    log "启用 EasyTier（network=${EASYTIER_NETWORK_NAME}）"

    ET_CMD=()
    # 容器里通常没有 /dev/net/tun：无 TUN 模式下本节点可被虚拟 IP 访问，只是不能主动外访
    # —— 作为 RDP 服务端正好够用
    [[ "${EASYTIER_NO_TUN:-true}" == "true" ]] && ET_CMD+=(--no-tun)

    if [[ -n "${EASYTIER_IPV4:-}" ]]; then
      ET_CMD+=(--ipv4 "$EASYTIER_IPV4")
      ET_TIP="$EASYTIER_IPV4"
    else
      ET_CMD+=(--dhcp)
      ET_TIP="DHCP 自动分配（easytier-cli node 查看）"
    fi

    ET_CMD+=(--network-name   "$EASYTIER_NETWORK_NAME")
    ET_CMD+=(--network-secret "$EASYTIER_NETWORK_SECRET")
    ET_CMD+=(--rpc-portal     "${EASYTIER_RPC_PORTAL:-127.0.0.1:15888}")
    [[ -n "${EASYTIER_HOSTNAME:-}" ]] && ET_CMD+=(--hostname "$EASYTIER_HOSTNAME")

    # 逗号分隔，可填多个
    for key in peers listeners proxy_networks; do
      case "$key" in
        peers)          var="${EASYTIER_PEERS:-}";          flag="--peers" ;;
        listeners)      var="${EASYTIER_LISTENERS:-}";      flag="--listeners" ;;
        proxy_networks) var="${EASYTIER_PROXY_NETWORKS:-}"; flag="--proxy-networks" ;;
      esac
      [[ -z "$var" ]] && continue
      IFS=',' read -r -a items <<< "$var"
      for it in "${items[@]}"; do
        it="${it// /}"
        [[ -n "$it" ]] && ET_CMD+=("$flag" "$it")
      done
    done

    # 额外参数原样追加，例如 "--enable-encryption false"
    if [[ -n "${EASYTIER_EXTRA_ARGS:-}" ]]; then
      read -r -a _extra <<< "$EASYTIER_EXTRA_ARGS"
      ET_CMD+=("${_extra[@]}")
    fi

    # 参数逐行落盘，wrapper 用数组方式 exec，避开 supervisord 的引号地狱
    printf '%s\n' "${ET_CMD[@]}" > /etc/easytier/args
    cat > /usr/local/bin/easytier-start.sh <<'EOS'
#!/usr/bin/env bash
mapfile -t ARGS < /etc/easytier/args
exec /usr/local/bin/easytier-core "${ARGS[@]}"
EOS
    chmod +x /usr/local/bin/easytier-start.sh

    cat > /etc/supervisor/conf.d/easytier.conf <<'EOF'
[program:easytier]
command=/usr/local/bin/easytier-start.sh
priority=5
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF
    log "EasyTier 参数: ${ET_CMD[*]}"
  fi
else
  log "EasyTier 未启用（需要私网访问请设置 EASYTIER_NETWORK_NAME / EASYTIER_NETWORK_SECRET）"
fi

# ---------------------------- 连接信息 --------------------------------------
PUBLIC_HOST="${RAILWAY_PUBLIC_DOMAIN:-${RAILWAY_TCP_PROXY_DOMAIN:-${PUBLIC_HOST:-127.0.0.1}}}"
PUBLIC_PORT="${RAILWAY_TCP_PROXY_PORT:-${PUBLIC_PORT:-${RDP_PORT}}}"

echo
echo "=========================================================="
echo "  >>> REMOTE DESKTOP IS READY <<<"
echo "  监听端口     : ${RDP_PORT}"
echo "  登录用户     : ${RDP_USER}"
echo "  登录密码     : ${RDP_PASSWORD}"
echo "  公网地址     : ${PUBLIC_HOST}:${PUBLIC_PORT}"
if [[ -n "${EASYTIER_IPV4:-}" && "$EASYTIER_ENABLE" == "true" ]]; then
  echo "  EasyTier 地址 : ${EASYTIER_IPV4}:${RDP_PORT}"
else
  echo "  EasyTier      : ${ET_TIP}"
fi
echo "  (mstsc / Microsoft Remote Desktop 连接上面的地址)"
echo "=========================================================="
echo

exec "$@"
