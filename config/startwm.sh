#!/bin/sh
# xrdp 会话启动脚本：拉起 XFCE4 桌面
if [ -r /etc/default/locale ]; then
  . /etc/default/locale
  export LANG LANGUAGE
fi

unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

exec dbus-launch --exit-with-session startxfce4
