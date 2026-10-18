#!/usr/bin/env bash
# terminal-only/verify-terminal-only.sh — 终端-only 部署自检
# 用法：以 bridge 用户（或可读其 runtime 的用户）运行：./terminal-only/verify-terminal-only.sh

set -uo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# 画布 display 优先级：调用者显式指定 > 安装时持久化值 > 默认 :50
saved_display="$(sed -n 's/^UURB_CANVAS_DISPLAY=//p' \
    "$HOME/.config/uu-remote-bridge/environment" 2>/dev/null | tail -n 1)"
CANVAS_DISPLAY="${CANVAS_DISPLAY:-${saved_display:-:50}}"
pass=0; fail=0; warn_n=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; warn_n=$((warn_n+1)); }

echo "── 1. 画布（vnc relay 像素源）──"
canvas_alive=false
if DISPLAY="$CANVAS_DISPLAY" timeout 5 xset q >/dev/null 2>&1; then
    canvas_alive=true
    ok "Xvfb $CANVAS_DISPLAY 在线"
else
    bad "Xvfb $CANVAS_DISPLAY 无响应（systemctl --user status uu-canvas-session）"
fi
# BUG-001 附带修复：SSH 无 DBUS 时 systemctl --user is-active 可能误报，
# 画布存活以上方 xset 实测为准（只探一次），单元状态仅作提示。
if [[ "$canvas_alive" == true ]]; then
    if systemctl --user is-active --quiet uu-canvas-session.service 2>/dev/null; then
        ok "uu-canvas-session.service active"
    else
        warn "Xvfb $CANVAS_DISPLAY 有响应但单元非 active（SSH 无 DBUS 时 systemctl 可能误报；画布本身可用）"
    fi
elif systemctl --user is-active --quiet uu-canvas-session.service 2>/dev/null; then
    warn "uu-canvas-session.service active 但 Xvfb 无响应（画布异常，查 journal）"
fi
# BUG-001(2026-10-13)：画布干净退出(exit 0)同样是断服，单元必须是 Restart=always。
# on-failure 对干净退出无效，曾导致本次客户端下线后桥空转无法自愈。
if systemctl --user show uu-canvas-session.service --property=Restart 2>/dev/null | grep -q 'Restart=always'; then
    ok "uu-canvas-session Restart=always（干净退出亦自愈）"
else
    bad "uu-canvas-session 非 Restart=always（干净退出不自愈，见 BUG-001；重跑 install-terminal-only.sh 同步）"
fi

echo "── 2. 上游桥服务 ──"
if systemctl --user is-active --quiet uu-remote-bridge.service 2>/dev/null; then
    ok "uu-remote-bridge.service active"
else
    bad "uu-remote-bridge.service 未运行（journalctl --user -u uu-remote-bridge -n 50）"
fi
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/uu-remote-bridge"
if [[ -f "$runtime_dir/private-display" ]]; then
    ok "bridge 私有画布 display 已注册（$(cat "$runtime_dir/private-display")）"
else
    warn "未找到 private-display runtime（bridge 未完成启动或路径不同）"
fi
# 键鼠直注路由：vnc relay 无 GNOME RDP 会话，route=rdp 时控制端键鼠有去无回
saved_route="$(sed -n 's/^UURB_KEYBOARD_ROUTE=//p' "$HOME/.config/uu-remote-bridge/environment" 2>/dev/null | tail -n 1)"
if [[ "$saved_route" == x11 || "$saved_route" == auto ]]; then
    ok "environment UURB_KEYBOARD_ROUTE=$saved_route"
else
    bad "environment UURB_KEYBOARD_ROUTE=${saved_route:-<未设>}（vnc relay 下 rdp 是输入死路；重装应带 --keyboard-route x11）"
fi
if [[ -s "$runtime_dir/x11-input.port" ]] && pgrep -x uu-x11-input >/dev/null 2>&1; then
    ok "x11-input helper 在线（XTEST 直注画布，port $(cat "$runtime_dir/x11-input.port")）"
else
    bad "x11-input helper 未运行——控制端键鼠不可用（桥日志应有 'direct X11 injection' 一行）"
fi
# 无 linger：SSH 断开 10s 后用户单元全部停止，重启也不自启（无头部署生命线）
if [[ -e "/var/lib/systemd/linger/$(id -un)" ]]; then
    ok "linger 已启用（断连/重启后用户单元存活）"
else
    bad "linger 未启用（sudo loginctl enable-linger $(id -un)）——SSH 断开/重启后服务不会存活"
fi

echo "── 3. UU 进程与在线态 ──"
if pgrep -f 'C:.*GameViewerServer\.exe' >/dev/null 2>&1; then
    ok "UU GameViewerServer 进程存在（Wine 内）"
else
    bad "未发现 UU 进程（Wine prefix 未启动或安装未完成）"
fi
connection_status="$("$repo_dir/scripts/uu_connection_status.py" 2>/dev/null |
    sed -n 's/^status=//p')"
if [[ "$connection_status" == "recent" ]]; then
    ok "UU 有近期的控制会话"
elif [[ "$connection_status" == "stale" ]]; then
    warn "UU 会话记录已过期（超过 5 分钟未连接）"
else
    warn "UU 在线态未确认——未登录？浏览器走 noVNC 扫码：ssh -L 6080:127.0.0.1:6080 后开 http://127.0.0.1:6080"
fi

echo "── 4. 终端桥组件 ──"
wine_prefix="${UURB_WINEPREFIX:-${WINEPREFIX:-$HOME/.local/share/wineprefixes/uu-remote}}"
if [[ -f "$wine_prefix/compat/uu-terminal-proxy.exe" ]]; then
    ok "uu-terminal-proxy.exe 已安装"
else
    warn "未定位到 uu-terminal-proxy.exe（应在 $wine_prefix/compat/）"
fi
shim_dll="$wine_prefix/compat/uu-conpty.dll"
conpty_dll="$wine_prefix/drive_c/Program Files/Netease/GameViewer/bin/conpty.dll"
if [[ -f "$shim_dll" && -f "$conpty_dll" ]] && cmp -s "$shim_dll" "$conpty_dll"; then
    ok "conpty.dll shim 已部署"
else
    warn "conpty.dll shim 未部署/不一致（broker 启动时会重新部署；无 shim 则终端不可用）"
fi

echo "── 5. 资源画像 ──"
free -h | awk 'NR<=2{printf "  %s\n",$0}'
wine_rss=$(ps -eo rss,comm --sort=-rss | awk '/wine|GameViewer/{s+=$1} END{print int(s/1024)}')
[[ -n "$wine_rss" && "$wine_rss" -gt 0 ]] 2>/dev/null && warn "Wine/UU 相关内存约 ${wine_rss}MB（基线记录用）" || true

echo
echo "══ 结果：$pass 通过 / $fail 失败 / $warn_n 提示 ══"
(( fail == 0 )) || exit 1
echo "终端功能最终确认：PC UU 控制端 → 设备 → Terminal → PowerShell 入口 → 应得到 Ubuntu shell"
