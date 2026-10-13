#!/usr/bin/env bash
# terminal-only/canvas-watchdog.sh — 画布看门狗（BUG-001 后续，核实报告 §6.2）
#
# 职责（由 uu-canvas-watchdog.timer 每 10 分钟触发一次）：
#   1) 画布重启感知：比对 uu-canvas-session 的 ExecMainStartTimestamp，
#      变化即写 watchdog.log——自愈/人工干预皆有痕可查（BUG-001 前无任何通道）。
#   2) 链路自检：运行 verify-terminal-only.sh；失败时 ✗ 摘要落 watchdog.log
#      并以非零码退出，journal 留下 "Failed with result" 高亮行。
# 日志：~/.local/state/uu-remote-bridge/watchdog.log（超 512KB 截断保留尾部）。
# 首次运行只建立基线，不产生日志；后续成功运行静默。

set -u

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/uu-remote-bridge"
log_file="$state_dir/watchdog.log"
state_file="$state_dir/canvas-watchdog.state"

mkdir -p "$state_dir"
log_line() { printf '[watchdog] %s %s\n' "$(date '+%F %T')" "$*" >>"$log_file"; }

# 日志封顶：512KB 后保留尾部 400 行（看门狗日志无审计要求）
if [[ -f "$log_file" ]] && (( $(stat -c%s "$log_file" 2>/dev/null || echo 0) > 524288 )); then
    tail -n 400 "$log_file" >"$log_file.tmp" && mv "$log_file.tmp" "$log_file"
fi

# ── 1) 画布重启感知 ─────────────────────────────────────────
main_ts="$(systemctl --user show uu-canvas-session.service \
    --property=ExecMainStartTimestamp --value 2>/dev/null)"
prev_ts="$(cat "$state_file" 2>/dev/null || true)"
if [[ -n "$main_ts" && "$main_ts" != "$prev_ts" ]]; then
    if [[ -n "$prev_ts" ]]; then
        log_line "画布发生重启：[$prev_ts] → [$main_ts]（自愈或人工干预；journalctl --user -u uu-canvas-session -n 30 查因）"
    fi
    printf '%s' "$main_ts" >"$state_file"
fi

# ── 2) 链路自检（verify 失败时自身 exit 1）──────────────────
out="$("$repo_dir/terminal-only/verify-terminal-only.sh" 2>&1)"
rc=$?
if (( rc != 0 )); then
    fail_n="$(grep -c '✗' <<<"$out" || true)"
    log_line "verify-terminal-only 失败（rc=$rc，$fail_n 项失败），摘要："
    grep '✗' <<<"$out" | sed 's/^/    /' >>"$log_file"
    exit "$rc"
fi
