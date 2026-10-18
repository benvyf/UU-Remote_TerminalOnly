#!/usr/bin/env bash
# terminal-only/install-terminal-only.sh — UU 远程终端专用裁剪安装（编排上游 install.sh）
# 用法：./terminal-only/install-terminal-only.sh
#   以普通用户运行；apt 等特权步骤由脚本按需调用 sudo（上游 install.sh 拒绝 root）。
# 原理：vnc relay 连自建 Xvfb 画布（先于上游安装启动）；终端桥与上游完全一致；
#   首次 UU 账号登录改由 noVNC console（:6080）完成。
# 对上游的唯一偏离：install.sh 内 vnc 模式跳过 GNOME RDP 配置段（见 install.sh
#   "Terminal-only / headless deployment" 注释），其余零修改。
# 回退：terminal-only/rollback-desktop.sh + 上游 uninstall.sh

set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
self_dir="$repo_dir/terminal-only"
CANVAS_DISPLAY="${CANVAS_DISPLAY:-:50}"
CANVAS_RESOLUTION="${CANVAS_RESOLUTION:-1280x800}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

log()  { printf '\033[1;32m[terminal-only]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[terminal-only]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[terminal-only]\033[0m %s\n' "$*" >&2; exit 1; }

# ── 0. 特权模型：普通用户 + 可用 sudo ─────────────────────────
(( EUID != 0 )) || die "请用普通用户运行（上游 install.sh 拒绝 root，本脚本会按需调用 sudo）"
command -v sudo >/dev/null 2>&1 || die "未找到 sudo"
sudo -n true 2>/dev/null || warn "sudo 需要密码：安装过程中终端会提示输入"

# ── 1. 前置检查 ─────────────────────────────────────────────
command -v lsb_release >/dev/null 2>&1 || die "未找到 lsb_release，请确认 Ubuntu 系统"
ubu="$(lsb_release -rs)"
case "$ubu" in
    24.04|26.04) log "Ubuntu $ubu 检测通过（上游验证版本）" ;;
    22.04|24.10|25.04) warn "Ubuntu $ubu 非上游主验证版本，继续；失败时先换 24.04/26.04" ;;
    *) warn "Ubuntu $ubu 未在上游支持列表，继续但风险自负" ;;
esac

bridge_user="$(id -un)"
log "bridge 用户 = $bridge_user（上游约定：谁安装谁运行）"

free_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
(( free_mb >= 1800 )) || die "可用内存 ${free_mb}MB < 1800MB，至少需要 2GB 空闲"
disk_gb=$(df -P "$repo_dir" | tail -1 | awk '{print int($4/1024)}')
(( disk_gb >= 5 )) || die "磁盘可用 ${disk_gb}GB < 5GB"

curl -sfI --max-time 8 "https://api.nrd.nie.163.com/api/v1/release/dl/1?channel=gwqd" -o /dev/null \
    || die "无法访问网易 UU 下载接口（api.nrd.nie.163.com）"
log "资源与网络检查通过（内存 ${free_mb}MB / 磁盘 ${disk_gb}GB）"

# ── 2. 画布先行：装 Xvfb 并启动用户单元 ────────────────────────
# 先于上游安装启动画布，保证桥首启时 vnc relay 立即有像素源可用。
log "安装 Xvfb 与 mingw 交叉编译器（画布依赖 + conpty shim 编译链）"
# gcc-mingw-w64-x86-64 必须在此提前安装：第 3 步编译 shim 需要它，而此前它只由
# 上游 install.sh 安装（执行顺序在本编译之后），干净主机上一键安装必然失败
sudo apt-get install -y --no-install-recommends xvfb x11-utils gcc-mingw-w64-x86-64

case "$CANVAS_DISPLAY" in
    :[0-9]) ;;
    :[1-9][0-9]) ;;
    :[1-9][0-9][0-9]) ;;
    *) die "CANVAS_DISPLAY 必须形如 :N（例如 :50），当前为 $CANVAS_DISPLAY" ;;
esac
case "$CANVAS_RESOLUTION" in
    [1-9][0-9]*x[1-9][0-9]*) ;;
    *) die "CANVAS_RESOLUTION 必须形如 宽x高（例如 1280x800），当前为 $CANVAS_RESOLUTION" ;;
esac
log "部署画布用户单元（Xvfb $CANVAS_DISPLAY，$CANVAS_RESOLUTION）"
install -d -m 0755 "$HOME/.config/systemd/user"
# 记录重装前单元内容：分辨率/显示号变更时 enable --now 幂等无操作，运行中的
# 画布拿不到新参数（审查 2026-10-18），下方据此 try-restart。
canvas_unit_was_installed=false
canvas_unit_old_hash=""
if [[ -f "$HOME/.config/systemd/user/uu-canvas-session.service" ]]; then
    canvas_unit_was_installed=true
    canvas_unit_old_hash="$(sha256sum "$HOME/.config/systemd/user/uu-canvas-session.service" | awk '{print $1}')"
fi
sed -e "s/:50/$CANVAS_DISPLAY/g" -e "s/1280x800/$CANVAS_RESOLUTION/g" \
    "$self_dir/uu-canvas-session.service" \
    > "$HOME/.config/systemd/user/uu-canvas-session.service"
systemctl --user daemon-reload
# BUG-001(2026-10-13)：画布单元必须是 Restart=always——Xvfb 干净退出(exit 0)
# 同样是断服，on-failure 对其无效。上方已无条件按仓库模板生成，此处只断言
# 生成结果，防仓库模板未来回归（此前的"兜底同步"块因上方无条件覆盖而永不执行）。
if ! grep -q '^Restart=always' "$HOME/.config/systemd/user/uu-canvas-session.service" 2>/dev/null; then
    die "BUG-001 防回归：生成的画布单元不是 Restart=always（检查 terminal-only/uu-canvas-session.service）"
fi
systemctl --user enable --now uu-canvas-session.service

# 重装且单元内容变化 → 重启画布使新分辨率/显示号生效（首次安装无需）
if [[ "$canvas_unit_was_installed" == true ]] && \
   [[ "$canvas_unit_old_hash" != "$(sha256sum "$HOME/.config/systemd/user/uu-canvas-session.service" | awk '{print $1}')" ]]; then
    log "画布单元参数变化，重启画布使新参数生效"
    systemctl --user try-restart uu-canvas-session.service
fi

canvas_ready=false
for _ in {1..30}; do
    if xdpyinfo -display "$CANVAS_DISPLAY" >/dev/null 2>&1; then
        canvas_ready=true
        break
    fi
    sleep 0.5
done
$canvas_ready || die "画布 $CANVAS_DISPLAY 未就绪（systemctl --user status uu-canvas-session）"
log "画布 $CANVAS_DISPLAY 就绪"

# ── 3. 上游安装（vnc relay + 精确 target + 跳过首次登录）───────
log "编译 conpty shim（mingw；绕开 build-compat.sh 的 FreeRDP 配方锁）"
mkdir -p build/compat
command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 \
    || die "未找到 x86_64-w64-mingw32-gcc（gcc-mingw-w64-x86-64 应已随第 2 步安装）"
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror \
    -Wl,--no-insert-timestamp -shared -I src \
    -o build/compat/uu-conpty.dll \
    src/uu_conpty_shim.c src/uu_conpty_shim.def -lws2_32
x86_64-w64-mingw32-strip build/compat/uu-conpty.dll

# keyboard-route 必须显式 x11：vnc relay 模式没有 GNOME RDP 会话，默认 rdp 路由
# 是死路（控制端键鼠有去无回＝"不能输入/鼠标消失"）。x11 让 uu-x11-input helper
# 以 XTEST 直注画布（键盘+指针），手机文字粘贴（semantic）也随之激活。
log "调用上游 install.sh（target=$CANVAS_DISPLAY relay=vnc $CANVAS_RESOLUTION keyboard=x11，登录后置，桥由本脚本拉起）"
cd "$repo_dir"
./install.sh \
    --desktop-target "$CANVAS_DISPLAY" \
    --desktop-relay vnc \
    --resolution "$CANVAS_RESOLUTION" \
    --keyboard-route x11 \
    --skip-account-login \
    --no-start

# 持久化画布参数：systemd 用户单元不继承安装 shell 的环境，verify/watchdog/
# canvas-resolution 都以环境文件为准——不落盘则自定义 display/分辨率会被这些
# 工具静默回落为 :50/1280x800（看门狗永远探测错 display；切档会重绑 ExecStart）
runtime_env="$HOME/.config/uu-remote-bridge/environment"
if [[ ! -f "$runtime_env" ]]; then
    mkdir -p "$(dirname "$runtime_env")"
    chmod 0700 "$(dirname "$runtime_env")"
    install -m 0600 /dev/null "$runtime_env"
fi
persist_env_kv() {
    if grep -q "^$1=" "$runtime_env"; then
        sed -i "s|^$1=.*|$1=$2|" "$runtime_env"
    else
        printf '%s=%s\n' "$1" "$2" >>"$runtime_env"
    fi
}
persist_env_kv UURB_CANVAS_DISPLAY "$CANVAS_DISPLAY"
persist_env_kv UURB_CANVAS_RESOLUTION "$CANVAS_RESOLUTION"
chmod 0600 "$runtime_env"
log "画布参数已持久化（UURB_CANVAS_DISPLAY=$CANVAS_DISPLAY UURB_CANVAS_RESOLUTION=$CANVAS_RESOLUTION）"
log "部署 conpty shim 到 prefix compat"
wine_prefix="${UURB_WINEPREFIX:-${WINEPREFIX:-$HOME/.local/share/wineprefixes/uu-remote}}"
/usr/bin/install -m 0644 build/compat/uu-conpty.dll \
    "$wine_prefix/compat/uu-conpty.dll"

# ── 4. 部署后自检 ───────────────────────────────────────────
log "启动桥并自检"
systemctl --user restart uu-remote-bridge.service
runtime_file="/run/user/$(id -u)/uu-remote-bridge/terminal.port"
for _ in {1..60}; do
    systemctl --user is-active --quiet uu-remote-bridge.service || break
    [[ -s "$runtime_file" ]] && break
    sleep 0.5
done
if systemctl --user is-active --quiet uu-remote-bridge.service; then
    log "✓ uu-remote-bridge active"
else
    warn "✗ uu-remote-bridge 未运行：journalctl --user -u uu-remote-bridge -n 50"
    journalctl --user -u uu-remote-bridge -n 20 --no-pager | tail -10
fi
systemctl --user is-active --quiet uu-canvas-session.service \
    && log "✓ uu-canvas-session active" \
    || warn "✗ uu-canvas-session 未激活"
# 登录通道：noVNC console 直接看 UU 私有画布（上游仅在部分路径启用它）
systemctl --user enable --now uu-remote-console.service \
    && log "✓ noVNC console 已启用（http://127.0.0.1:6080）" \
    || warn "✗ uu-remote-console 启用失败：journalctl --user -u uu-remote-console"

# BUG-001 看门狗（核实报告 §6.2）：10 分钟周期链路自检 + 画布重启感知。
# 失败/重启事件落 ~/.local/state/uu-remote-bridge/watchdog.log，
# 自检失败以非零码退出，journal 留下 Failed with result 高亮行。
log "部署画布看门狗（uu-canvas-watchdog.timer，10 分钟周期）"
# ExecStart 按实际仓库路径重写：模板占位 %h/UU-Remote_TerminalOnly 只在默认克隆
# 位置碰巧可用，其余路径每次触发 exit 203 且 enable 仍报成功（静默失效）
[[ "$repo_dir" =~ [[:space:]] ]] && die "仓库路径含空白，无法写入 systemd ExecStart：$repo_dir"
sed "s|%h/UU-Remote_TerminalOnly|${repo_dir}|" "$self_dir/uu-canvas-watchdog.service" \
    > "$HOME/.config/systemd/user/uu-canvas-watchdog.service"
install -m 0644 "$self_dir/uu-canvas-watchdog.timer" "$HOME/.config/systemd/user/uu-canvas-watchdog.timer"
systemctl --user daemon-reload
systemctl --user enable --now uu-canvas-watchdog.timer \
    && log "✓ 画布看门狗已启用（journalctl --user -u uu-canvas-watchdog.service）" \
    || warn "✗ 画布看门狗启用失败"

# 无 linger：SSH 会话结束 10s 后（UserStopDelaySec 默认值）用户管理器停止，
# 画布/桥/console 全部终止，重启后也不会自启——无头部署的生命线
log "启用 linger（SSH 断开/重启后用户单元存活）"
sudo loginctl enable-linger "$bridge_user" \
    || die "loginctl enable-linger 失败——无头部署缺少它，服务会在会话结束后停止"
[[ -e "/var/lib/systemd/linger/$bridge_user" ]] \
    || die "linger 未生效（/var/lib/systemd/linger/$bridge_user 缺失）"
log "✓ linger 已启用（$bridge_user）"

cat <<'EOF'

════════════════════════════════════════════════════════
 安装完成。下一步（UU 账号登录，一次性）：
   方式 A（本机有桌面）：终端运行  uu-remote open  → 手机 UU App 扫码
   方式 B（无头/SSH）：  ssh -L 6080:127.0.0.1:6080 <user>@<server>
                         浏览器打开 http://127.0.0.1:6080 → 扫码
   登录态持久保存在 wineprefix 注册表，重启/升级后无需重登。
 验证：
   ./terminal-only/verify-terminal-only.sh
   ./scripts/test-terminal-bridge.sh
 说明与回退： terminal-only/README.md
════════════════════════════════════════════════════════
EOF
