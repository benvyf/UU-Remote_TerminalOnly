#!/usr/bin/env bash
# terminal-only 虚拟桌面会话(:50):openbox + tint2 面板 + 纯色壁纸
# 由 uu-virtual-desktop.service(用户单元)拉起;崩溃由 systemd 重启。
# 非 login 会话:不加载 /etc/profile.d(避免向桌面流注入私有序列)。
set -u

DISPLAY="${VIRTUAL_DESKTOP_DISPLAY:-:50}"
export DISPLAY
XAUTHORITY="${XAUTHORITY:-/run/user/$(id -u)/uu-remote-bridge/Xauthority}"
export XAUTHORITY

xdpyinfo >/dev/null 2>&1 || {
    echo "virtual-desktop: display $DISPLAY 不可达" >&2
    exit 1
}

# 壁纸与光标(纯色,零依赖)
xsetroot -solid "#1a1b26" -cursor_name left_ptr

# 面板(后台常驻;openbox 前台作为会话主体,随单元退出)
tint2 >/dev/null 2>&1 &

exec openbox
