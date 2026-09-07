# syntax=docker/dockerfile:1
#
# Railway / Docker 通用远程桌面镜像
#   OS      : Ubuntu 22.04 (Jammy)
#   Desktop : XFCE4
#   Protocol: RDP (xrdp + xorgxrdp)
#   VPN     : EasyTier (可选, --no-tun 模式, 不需要 TUN 设备)
#
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=Asia/Shanghai \
    RDP_USER=rdpuser \
    RDP_UID=1000 \
    RDP_PORT=3389

# ------------------------------------------------------------------
# 1) 基础系统包
# ------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg2 apt-utils locales tzdata \
      sudo dbus dbus-x11 xauth x11-utils \
      supervisor netcat-openbsd net-tools iputils-ping dnsutils \
      procps htop vim nano git unzip zip xclip xdg-utils \
      fonts-noto-cjk fonts-noto-color-emoji fonts-wqy-zenhei \
      thunar-archive-plugin file-roller gvfs \
      python3 python3-pip; \
    ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime; \
    echo "${TZ}" > /etc/timezone; \
    sed -i 's/^# *\(en_US.UTF-8\)/\1/; s/^# *\(zh_CN.UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen; \
    rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------
# 2) 桌面环境 + XRDP
# ------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      xrdp xorgxrdp xserver-xorg-core xserver-xorg-input-all \
      xfce4 xfce4-goodies xfce4-terminal xfce4-screenshooter; \
    rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------
# 3) Google Chrome（下载失败不阻断构建）
# ------------------------------------------------------------------
RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
    if wget -q -O /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_${ARCH}.deb"; then \
      apt-get update; \
      apt-get install -y /tmp/chrome.deb || echo "chrome deps missing, skipped"; \
      rm -f /tmp/chrome.deb; \
    fi; \
    rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------
# 4) EasyTier（去中心化组网，用于私网接入）
#    优先下载固定版本，失败则回退到 latest 自动发现
# ------------------------------------------------------------------
ARG EASYTIER_VERSION=2.6.4
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) ET_ARCH=x86_64 ;; \
      arm64) ET_ARCH=aarch64 ;; \
      *)     ET_ARCH=x86_64 ;; \
    esac; \
    V="${EASYTIER_VERSION#v}"; \
    URL="https://github.com/EasyTier/EasyTier/releases/download/v${V}/easytier-linux-${ET_ARCH}-v${V}.zip"; \
    if ! curl -fsSL --retry 3 --retry-delay 2 -o /tmp/et.zip "$URL"; then \
      echo "[warn] 固定版本下载失败，回退到 latest"; \
      URL="$(curl -fsSL https://api.github.com/repos/EasyTier/EasyTier/releases/latest \
             | grep -o "https://[^\"]*linux-${ET_ARCH}-[^\"]*\.zip" | head -n1)"; \
      curl -fsSL --retry 3 -o /tmp/et.zip "$URL"; \
    fi; \
    unzip -o -q /tmp/et.zip -d /tmp/et; \
    find /tmp/et -type f -name 'easytier-core' -exec install -m 0755 {} /usr/local/bin/ \; ; \
    find /tmp/et -type f -name 'easytier-cli'  -exec install -m 0755 {} /usr/local/bin/ \; ; \
    rm -rf /tmp/et /tmp/et.zip; \
    easytier-core --version || true

# ------------------------------------------------------------------
# 5) 配置文件
# ------------------------------------------------------------------
COPY config/supervisord.conf      /etc/supervisor/supervisord.conf
COPY config/xrdp.ini              /etc/xrdp/xrdp.ini
COPY config/startwm.sh            /etc/xrdp/startwm.sh
COPY config/45-xrdp-desktop.pkla  /etc/polkit-1/localauthority/50-local.d/45-xrdp-desktop.pkla
COPY scripts/entrypoint.sh        /usr/local/bin/entrypoint.sh
COPY scripts/healthcheck.sh       /usr/local/bin/healthcheck.sh

RUN set -eux; \
    chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /etc/xrdp/startwm.sh; \
    mkdir -p /run/xrdp /var/log/xrdp /run/dbus /etc/easytier; \
    dbus-uuidgen --ensure=/etc/machine-id

# 用户数据建议挂载卷做持久化
VOLUME ["/home"]

EXPOSE 3389

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
