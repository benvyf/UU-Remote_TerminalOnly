#!/usr/bin/env bash
# terminal-only/canvas-resolution.sh — :50 画布分辨率预设
#
# 背景（HANDOFF §19 / 评估报告行动清单）：UU 协议在 Linux 侧不暴露控制端
# 分辨率事件，"按客户端动态适配"不可实现；近似方案 = 预设档位。Xvfb 是单模式
# 显示（RANDR 运行时加模式不可靠），切档需改画布单元 ExecStart 的 -screen
# 参数（systemd drop-in），并同步 UURB_RESOLUTION——bridge 私有画布 :20 的
# 尺寸，relay 中继窗（vncviewer -RemoteResize=0）与画布 1:1 的前提。
#
# 用法（以 bridge 用户运行）：
#   ./terminal-only/canvas-resolution.sh status        # 当前档位与实测尺寸
#   ./terminal-only/canvas-resolution.sh 1080p         # 预设档位
#   ./terminal-only/canvas-resolution.sh 1600x900      # 任意合法 WxH
#   ./terminal-only/canvas-resolution.sh reset         # 恢复单元默认 1280x800
#
# 注意：切换会重启 uu-canvas-session 与 uu-remote-bridge；进行中的终端会话
# 将结束（跨桥重启不保留锚定会话，重连即开新 shell）。>1440p 会明显增加
# relay 像素量与 Wine 侧 CPU 开销，按需选用。

set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
canvas_unit="uu-canvas-session.service"
unit_file="$HOME/.config/systemd/user/$canvas_unit"
dropin_dir="$HOME/.config/systemd/user/$canvas_unit.d"
dropin_file="$dropin_dir/10-canvas-resolution.conf"
environment_file="$HOME/.config/uu-remote-bridge/environment"
canvas_display="${CANVAS_DISPLAY:-:50}"
default_geometry="1280x800"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法：canvas-resolution.sh [status|reset|<预设名|WxH>]

  status             显示当前档位（drop-in / 环境文件 / 实测尺寸）
  reset              恢复单元默认 1280x800
  预设名：default(1280x800) 1080p(1920x1080) 1440p(2560x1440) 4k(3840x2160)
  或任意合法 WxH（宽 640-16384，高 480-16384）

切换会重启画布与桥服务；进行中的终端会话将结束（重连开新 shell）。
大尺寸（>1440p）会增加 relay 像素量与 Wine 侧 CPU 开销。
EOF
}

# 预设名 → WxH；非预设返回非零
preset_geometry() {
    case "$1" in
        default|svga) echo 1280x800 ;;
        1080p|fhd)    echo 1920x1080 ;;
        1440p|qhd)    echo 2560x1440 ;;
        4k|uhd)       echo 3840x2160 ;;
        *)            return 1 ;;
    esac
}

valid_geometry() {
    [[ "$1" =~ ^([0-9]{3,5})x([0-9]{3,5})$ ]] || return 1
    local w="${BASH_REMATCH[1]}" h="${BASH_REMATCH[2]}"
    (( w >= 640 && w <= 16384 && h >= 480 && h <= 16384 ))
}

# 画布内存上限：帧缓冲 w*h*4 字节 + Xvfb 固定开销（实测 ~19MB）留一倍余量
memory_limit_mb() {
    local w="$1" h="$2" fb_mib mem
    fb_mib=$(( (w * h * 4 + 1048575) / 1048576 ))
    mem=$(( fb_mib * 2 + 64 ))
    (( mem < 128 )) && mem=128
    echo $(( (mem + 31) / 32 * 32 ))
}

current_geometry() {
    local mode=""
    if [[ -f "$dropin_file" ]]; then
        mode="$(sed -n 's/^ExecStart=\/usr\/bin\/Xvfb .*-screen 0 \([0-9]*x[0-9]*\)x24 .*/\1/p' \
            "$dropin_file" | head -1)"
    fi
    echo "${mode:-$default_geometry}"
}

env_resolution() {
    [[ -f "$environment_file" ]] || return 0
    sed -n 's/^UURB_RESOLUTION=//p' "$environment_file" | tail -1
}

actual_geometry() {
    DISPLAY="$canvas_display" timeout 3 xdpyinfo 2>/dev/null |
        sed -n 's/^  dimensions: *\([0-9]*x[0-9]*\) pixels.*/\1/p' | head -1
}

write_dropin() {
    local geometry="$1" mem="$2"
    mkdir -p "$dropin_dir"
    local tmp="$dropin_file.tmp.$$"
    {
        echo "# 由 terminal-only/canvas-resolution.sh 生成于 $(date '+%F %T')"
        echo "# 删除本文件或运行 reset 恢复单元默认 ${default_geometry}"
        echo "[Service]"
        echo "ExecStart="
        echo "ExecStart=/usr/bin/Xvfb $canvas_display -screen 0 ${geometry}x24 -nolisten tcp -noreset"
        echo "MemoryMax=${mem}M"
    } >"$tmp"
    mv "$tmp" "$dropin_file"
}

# 只改 UURB_RESOLUTION 一行；行数守恒 + 值校验，失败即中止不落盘
update_environment() {
    local geometry="$1"
    [[ -f "$environment_file" ]] || die "环境文件不存在：$environment_file"
    local tmp="$environment_file.tmp.$$" before after
    if grep -q '^UURB_RESOLUTION=' "$environment_file"; then
        sed "s/^UURB_RESOLUTION=.*/UURB_RESOLUTION=$geometry/" \
            "$environment_file" >"$tmp"
    else
        cp "$environment_file" "$tmp"
        printf 'UURB_RESOLUTION=%s\n' "$geometry" >>"$tmp"
    fi
    before=$(wc -l <"$environment_file")
    after=$(wc -l <"$tmp")
    if [[ "$after" -ne "$before" ]] ||
       ! grep -qx "UURB_RESOLUTION=$geometry" "$tmp"; then
        rm -f "$tmp"
        die "环境文件写入校验失败，已中止（原文件未动）"
    fi
    chmod --reference="$environment_file" "$tmp"
    mv "$tmp" "$environment_file"
}

reload_and_restart() {
    local geometry="$1" i dims="" line
    systemctl --user daemon-reload
    systemctl --user restart uu-canvas-session.service
    for i in $(seq 1 30); do
        dims="$(actual_geometry)"
        [[ "$dims" == "$geometry" ]] && break
        sleep 0.5
    done
    if [[ "$dims" == "$geometry" ]]; then
        ok "画布 $canvas_display 已切换到 $geometry"
    else
        warn "画布尺寸未确认（xdpyinfo=${dims:-无响应}）：journalctl --user -u uu-canvas-session -n 30"
    fi
    systemctl --user restart uu-remote-bridge.service
    for i in $(seq 1 60); do
        systemctl --user is-active --quiet uu-remote-bridge.service && break
        sleep 0.5
    done
    if systemctl --user is-active --quiet uu-remote-bridge.service; then
        ok "uu-remote-bridge.service 已重启"
    else
        warn "桥服务未激活：journalctl --user -u uu-remote-bridge -n 50"
    fi
    line="$(journalctl --user -u uu-remote-bridge --no-pager -n 60 2>/dev/null |
        grep -F 'Using private display' | tail -1 || true)"
    [[ -n "$line" ]] && printf '  %s\n' "$line"
    warn "桥已重启：进行中的终端会话已结束，重连将开新 shell"
}

cmd_status() {
    local geometry env_res dims unit_state
    geometry="$(current_geometry)"
    env_res="$(env_resolution)"
    dims="$(actual_geometry)"
    unit_state="$(systemctl --user is-active uu-canvas-session.service 2>/dev/null || true)"
    printf '画布单元状态: %s\n' "${unit_state:-unknown}"
    printf '画布模式(drop-in 或默认): %s\n' "$geometry"
    printf 'UURB_RESOLUTION(私有画布 :20): %s\n' "${env_res:-<未设>}"
    printf '实测尺寸(%s): %s\n' "$canvas_display" "${dims:-无响应}"
    if [[ -n "$dims" && "$dims" != "$geometry" ]]; then
        warn "实测尺寸与配置不一致——重跑一次目标档位或 reset"
    fi
    if [[ -n "$env_res" && "$env_res" != "$geometry" ]]; then
        warn "UURB_RESOLUTION 与画布模式不一致——中继窗将非 1:1 缩放"
    fi
}

cmd_apply() {
    local spec="$1" geometry
    geometry="$(preset_geometry "$spec" || true)"
    if [[ -z "$geometry" ]]; then
        valid_geometry "$spec" ||
            die "无法识别的档位或非法尺寸：$spec（预设 default/1080p/1440p/4k，或合法 WxH）"
        geometry="$spec"
    fi
    [[ -f "$unit_file" ]] || die "未找到画布单元 $unit_file（terminal-only 未安装？）"
    systemctl --user is-active --quiet uu-canvas-session.service ||
        warn "画布单元当前未激活（仍将写入配置并尝试重启）"
    local w="${geometry%x*}" h="${geometry#*x}" mem
    mem="$(memory_limit_mb "$w" "$h")"
    if (( w * h > 2560 * 1440 )); then
        warn "$geometry 超过 1440p：relay 像素量与 Wine 侧 CPU 开销将明显上升"
    fi
    write_dropin "$geometry" "$mem"
    update_environment "$geometry"
    ok "配置已写入（画布 ${geometry}x24 / MemoryMax=${mem}M / UURB_RESOLUTION=$geometry）"
    reload_and_restart "$geometry"
    echo
    cmd_status
}

cmd_reset() {
    rm -f "$dropin_file"
    rmdir "$dropin_dir" 2>/dev/null || true
    update_environment "$default_geometry"
    ok "已移除 drop-in，恢复单元默认 $default_geometry"
    reload_and_restart "$default_geometry"
    echo
    cmd_status
}

case "${1:-status}" in
    status)              cmd_status ;;
    reset)               cmd_reset ;;
    -h|--help|help)      usage ;;
    *)                   cmd_apply "$1" ;;
esac
