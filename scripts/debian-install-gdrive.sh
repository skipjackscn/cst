#!/usr/bin/env bash
# Debian 一键安装 / 登录 / 挂载 Google 网盘（Google Drive）
#
# 说明：
#   Google 没有官方 Linux 桌面客户端。本脚本用 rclone 把网盘挂到 ~/GoogleDrive，
#   用法接近“网盘文件夹”，支持浏览、复制、上传。
#
# 一键（安装 + 登录 + 挂载）：
#   curl -fsSL https://raw.githubusercontent.com/skipjackscn/cst/main/scripts/debian-install-gdrive.sh | bash
#   或：
#   bash debian-install-gdrive.sh
#
# 子命令：
#   bash debian-install-gdrive.sh install    # 只安装 rclone / fuse
#   bash debian-install-gdrive.sh login      # 只登录 Google 账号
#   bash debian-install-gdrive.sh mount      # 挂载到 ~/GoogleDrive
#   bash debian-install-gdrive.sh umount     # 卸载
#   bash debian-install-gdrive.sh status     # 状态
#   bash debian-install-gdrive.sh uninstall  # 卸载服务与挂载（保留 rclone）
#
# 可选环境变量：
#   GDRIVE_REMOTE=gdrive
#   GDRIVE_MOUNT=$HOME/GoogleDrive
#   RCLONE_DRIVE_CLIENT_ID=xxxx.apps.googleusercontent.com
#   RCLONE_DRIVE_CLIENT_SECRET=GOCSPX-xxxx
#
# SSH 无桌面登录（推荐）：
#   在你自己的电脑先开端口转发，再运行本脚本 login：
#     ssh -L 53682:127.0.0.1:53682 USER@DEBIAN_HOST
#   然后在电脑浏览器打开 http://127.0.0.1:53682/auth 完成 Google 授权。

set -euo pipefail

REMOTE="${GDRIVE_REMOTE:-gdrive}"
MOUNT_DIR="${GDRIVE_MOUNT:-${HOME}/GoogleDrive}"
CLIENT_ID="${RCLONE_DRIVE_CLIENT_ID:-}"
CLIENT_SECRET="${RCLONE_DRIVE_CLIENT_SECRET:-}"
UNIT_NAME="gdrive-rclone.service"
UNIT_PATH="${HOME}/.config/systemd/user/${UNIT_NAME}"
CACHE_DIR="${HOME}/.cache/rclone-gdrive"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info()   { printf '\033[36m==>\033[0m %s\n' "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif need_cmd sudo; then
    sudo "$@"
  else
    red "需要 root 权限执行: $*"
    exit 1
  fi
}

real_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s' "${SUDO_USER}"
  else
    printf '%s' "$(id -un)"
  fi
}

if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  # 用 sudo 跑脚本时，网盘配置挂到原用户家目录，而不是 /root
  HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
  export HOME
  MOUNT_DIR="${GDRIVE_MOUNT:-${HOME}/GoogleDrive}"
  UNIT_PATH="${HOME}/.config/systemd/user/${UNIT_NAME}"
  CACHE_DIR="${HOME}/.cache/rclone-gdrive"
  export XDG_CONFIG_HOME="${HOME}/.config"
  export XDG_CACHE_HOME="${HOME}/.cache"
fi

rclone_as_user() {
  local u
  u="$(real_user)"
  if [[ "$(id -un)" == "$u" ]]; then
    env HOME="$HOME" rclone "$@"
  else
    as_root -u "$u" env HOME="$HOME" XDG_CONFIG_HOME="${HOME}/.config" rclone "$@"
  fi
}

detect_rclone_arch() {
  local dpkg_arch
  dpkg_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$dpkg_arch" in
    amd64|x86_64) echo linux-amd64 ;;
    arm64|aarch64) echo linux-arm64 ;;
    armhf|armv7l) echo linux-arm-v7 ;;
    i386|x86) echo linux-386 ;;
    *)
      red "不支持的架构: ${dpkg_arch}"
      exit 1
      ;;
  esac
}

ensure_fuse_dev() {
  if [[ ! -e /dev/fuse ]]; then
    info "创建 /dev/fuse（容器环境常见）"
    as_root mknod /dev/fuse c 10 229 || true
    as_root chmod 666 /dev/fuse || true
  fi
  if [[ -f /etc/fuse.conf ]]; then
    if ! grep -qE '^[[:space:]]*user_allow_other' /etc/fuse.conf; then
      echo 'user_allow_other' | as_root tee -a /etc/fuse.conf >/dev/null
    fi
  fi
}

install_pkgs() {
  info "安装系统依赖"
  export DEBIAN_FRONTEND=noninteractive
  as_root apt-get update -y
  as_root apt-get install -y --no-install-recommends \
    ca-certificates curl unzip fuse3 procps dbus systemd
  ensure_fuse_dev
}

install_rclone() {
  if need_cmd rclone; then
    local ver
    ver="$(rclone version | head -n1 || true)"
    info "已安装 ${ver}"
    # Debian 仓库版往往过旧，Google Drive OAuth 可能不兼容，尽量升到官方包
    if rclone version 2>/dev/null | head -n1 | grep -qE 'v1\.([0-5][0-9]|60|61|62|63|64)\.'; then
      yellow "rclone 版本偏旧，改为安装官方最新版"
    else
      return 0
    fi
  fi

  info "下载官方 rclone"
  local arch zip_name tmp
  arch="$(detect_rclone_arch)"
  zip_name="rclone-current-${arch}.zip"
  tmp="$(mktemp -d)"
  trap 'rm -rf "'"$tmp"'"' RETURN
  curl -fsSL "https://downloads.rclone.org/${zip_name}" -o "${tmp}/rclone.zip"
  unzip -qo "${tmp}/rclone.zip" -d "${tmp}"
  local bin
  bin="$(find "${tmp}" -type f -name rclone | head -n1)"
  [[ -n "$bin" ]] || { red "压缩包里没有 rclone"; exit 1; }
  as_root install -m 0755 "$bin" /usr/local/bin/rclone
  if [[ -d /usr/share/man/man1 ]]; then
    local man
    man="$(find "${tmp}" -type f -name rclone.1 | head -n1 || true)"
    [[ -n "$man" ]] && as_root install -m 0644 "$man" /usr/share/man/man1/rclone.1 || true
  fi
  hash -r || true
  info "rclone 安装完成: $(rclone version | head -n1)"
}

remote_exists() {
  rclone_as_user listremotes 2>/dev/null | grep -qx "${REMOTE}:"
}

logged_in() {
  rclone_as_user lsd "${REMOTE}:" --max-depth 1 --retries 1 --low-level-retries 1 >/dev/null 2>&1
}

print_client_id_help() {
  cat << EOF

$(yellow "建议配置自己的 Google OAuth 客户端（rclone 公共 client_id 会在 2026 年停用）")
1. 打开 https://console.cloud.google.com/apis/credentials
2. 创建项目，启用 Google Drive API
3. 创建 OAuth 客户端 ID，类型选「桌面应用」
4. 再运行：
   export RCLONE_DRIVE_CLIENT_ID='你的客户端ID'
   export RCLONE_DRIVE_CLIENT_SECRET='你的客户端密钥'
   bash $0 login

EOF
}

print_ssh_help() {
  local user host
  user="$(real_user)"
  host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  host="${host:-本机IP}"
  cat << EOF

$(yellow "当前没有图形界面。用 SSH 端口转发在你自己的浏览器里登录：")

  1. 先在你的电脑新开一个终端，保持这个隧道开着：
       ssh -L 53682:127.0.0.1:53682 ${user}@${host}

  2. 等下面出现 Waiting for code / auth 链接后，在电脑浏览器打开：
       http://127.0.0.1:53682/auth

  3. 用 Google 账号授权。授权成功后本脚本会自动继续。

EOF
}

create_or_update_remote() {
  mkdir -p "${HOME}/.config/rclone"
  local extra=()
  if [[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]]; then
    extra+=(client_id "$CLIENT_ID" client_secret "$CLIENT_SECRET")
  else
    yellow "未设置 RCLONE_DRIVE_CLIENT_ID，暂用 rclone 默认客户端。"
    print_client_id_help
  fi

  if ! remote_exists; then
    info "创建远程 ${REMOTE}:"
    rclone_as_user config create "${REMOTE}" drive scope drive "${extra[@]}" --non-interactive >/dev/null
  elif [[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]]; then
    rclone_as_user config update "${REMOTE}" client_id "$CLIENT_ID" client_secret "$CLIENT_SECRET" scope drive --non-interactive >/dev/null || true
  fi

  info "打开 Google 授权（完成后会自动返回终端）"
  rclone_as_user config reconnect "${REMOTE}:"
}

login_drive() {
  if logged_in; then
    green "已经登录 ${REMOTE}: ，跳过授权"
    rclone_as_user about "${REMOTE}:" || true
    return 0
  fi

  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    print_ssh_help
    sleep 2
  else
    info "将打开浏览器完成 Google 登录"
  fi

  create_or_update_remote

  if logged_in; then
    green "Google 网盘登录成功"
    rclone_as_user about "${REMOTE}:" || true
  else
    red "登录未完成。若在 SSH 环境，请先开 -L 53682 隧道后再执行: bash $0 login"
    exit 1
  fi
}

write_unit() {
  mkdir -p "$(dirname "$UNIT_PATH")" "${CACHE_DIR}" "$MOUNT_DIR"
  cat > "$UNIT_PATH" << EOF
[Unit]
Description=Rclone mount Google Drive (${REMOTE})
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=/bin/mkdir -p ${MOUNT_DIR}
ExecStart=/usr/local/bin/rclone mount ${REMOTE}: ${MOUNT_DIR} \\
    --config ${HOME}/.config/rclone/rclone.conf \\
    --vfs-cache-mode full \\
    --vfs-cache-max-size 10G \\
    --vfs-cache-max-age 72h \\
    --dir-cache-time 1h \\
    --poll-interval 1m \\
    --umask 022 \\
    --allow-non-empty \\
    --cache-dir ${CACHE_DIR}
ExecStop=/bin/fusermount3 -u ${MOUNT_DIR}
Restart=on-failure
RestartSec=5
Environment=HOME=${HOME}

[Install]
WantedBy=default.target
EOF
  # rclone 可能装在 /usr/bin
  if [[ ! -x /usr/local/bin/rclone && -x /usr/bin/rclone ]]; then
    sed -i 's|/usr/local/bin/rclone|/usr/bin/rclone|' "$UNIT_PATH"
  fi
}

is_mounted() {
  if need_cmd findmnt; then
    findmnt -n "$MOUNT_DIR" >/dev/null 2>&1
  else
    grep -Eq "[[:space:]]${MOUNT_DIR}[[:space:]]" /proc/mounts 2>/dev/null
  fi
}

do_mount() {
  mkdir -p "$MOUNT_DIR" "$CACHE_DIR"
  if is_mounted; then
    green "已挂载: ${MOUNT_DIR}"
    return 0
  fi
  if ! logged_in; then
    red "尚未登录。请先运行: bash $0 login"
    exit 1
  fi

  write_unit
  local u
  u="$(real_user)"
  if need_cmd systemctl && systemctl --user show-environment >/dev/null 2>&1; then
    info "启用用户服务 ${UNIT_NAME}"
    systemctl --user daemon-reload
    systemctl --user enable --now "${UNIT_NAME}"
    as_root loginctl enable-linger "$u" >/dev/null 2>&1 || true
  else
    info "无 systemd 用户会话，前台守护挂载"
    local rclone_bin
    rclone_bin="$(command -v rclone)"
    nohup "$rclone_bin" mount "${REMOTE}:" "$MOUNT_DIR" \
      --vfs-cache-mode full \
      --vfs-cache-max-size 10G \
      --dir-cache-time 1h \
      --poll-interval 1m \
      --umask 022 \
      --allow-non-empty \
      --cache-dir "$CACHE_DIR" \
      >/tmp/gdrive-rclone.log 2>&1 &
    sleep 2
  fi

  local i
  for i in $(seq 1 20); do
    if is_mounted; then
      green "Google 网盘已挂载到 ${MOUNT_DIR}"
      ls -la "$MOUNT_DIR" | head -n 15 || true
      return 0
    fi
    sleep 1
  done
  red "挂载超时。看日志: journalctl --user -u ${UNIT_NAME} -e  或  tail -n 80 /tmp/gdrive-rclone.log"
  exit 1
}

do_umount() {
  if need_cmd systemctl; then
    systemctl --user stop "${UNIT_NAME}" 2>/dev/null || true
  fi
  if is_mounted; then
    fusermount3 -u "$MOUNT_DIR" 2>/dev/null || fusermount -u "$MOUNT_DIR" 2>/dev/null || umount "$MOUNT_DIR" || true
  fi
  green "已卸载 ${MOUNT_DIR}"
}

do_status() {
  echo "用户        : $(real_user)"
  echo "rclone      : $(command -v rclone || echo 未安装)"
  command -v rclone >/dev/null && rclone version | head -n1 || true
  echo "远程名      : ${REMOTE}:"
  echo "挂载点      : ${MOUNT_DIR}"
  echo "配置文件    : ${HOME}/.config/rclone/rclone.conf"
  if remote_exists; then echo "远程状态    : 已配置"; else echo "远程状态    : 未配置"; fi
  if logged_in; then echo "登录状态    : 已登录"; else echo "登录状态    : 未登录"; fi
  if is_mounted; then echo "挂载状态    : 已挂载"; else echo "挂载状态    : 未挂载"; fi
  if logged_in; then
    echo
    rclone_as_user about "${REMOTE}:" || true
  fi
}

do_uninstall() {
  do_umount || true
  if need_cmd systemctl; then
    systemctl --user disable --now "${UNIT_NAME}" 2>/dev/null || true
  fi
  rm -f "$UNIT_PATH"
  green "已停止挂载并删除用户服务。rclone 与登录配置仍保留在 ${HOME}/.config/rclone/"
}

usage() {
  sed -n '2,40p' "$0"
}

cmd="${1:-all}"
case "$cmd" in
  -h|--help|help) usage ;;
  install)
    install_pkgs
    install_rclone
    ;;
  login)
    need_cmd rclone || { install_pkgs; install_rclone; }
    login_drive
    ;;
  mount)
    need_cmd rclone || { install_pkgs; install_rclone; }
    do_mount
    ;;
  umount|unmount) do_umount ;;
  status) do_status ;;
  uninstall) do_uninstall ;;
  all)
    install_pkgs
    install_rclone
    login_drive
    do_mount
    echo
    green "完成。打开文件管理器或执行:  ls ${MOUNT_DIR}"
    echo "之后开机自动挂载（若 systemd 用户服务可用）。"
    echo "常用: bash $0 status | mount | umount | login"
    ;;
  *)
    red "未知命令: $cmd"
    usage
    exit 1
    ;;
esac
