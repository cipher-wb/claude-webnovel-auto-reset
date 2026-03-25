#!/bin/zsh

set -u

print_usage() {
  print -r -- "用法:"
  print -r -- "  zsh /Users/cipher/AI/连续写作方案测试/webnovel_auto_reset.zsh"
  print -r -- "  zsh /Users/cipher/AI/连续写作方案测试/webnovel_auto_reset.zsh 3"
  print -r -- ""
  print -r -- "说明:"
  print -r -- "  不带参数: 无限循环"
  print -r -- "  带一个正整数: 成功完成指定章节数后自动停止"
}

if [[ $# -gt 1 ]]; then
  print_usage
  exit 1
fi

if [[ $# -eq 1 ]]; then
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    print_usage
    exit 0
  fi

  if [[ ! "$1" =~ '^[1-9][0-9]*$' ]]; then
    print -r -- "循环次数必须是正整数。"
    print_usage
    exit 1
  fi
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
WATCHER_SCRIPT="${SCRIPT_DIR}/webnovel_completion_watcher.py"
WRAPPER_PID=$$
STOP_FILE="/tmp/webnovel_auto_reset.${WRAPPER_PID}.stop"
PROJECT_ROOT="$PWD"
PROJECT_STATE_FILE="${PROJECT_ROOT}/.webnovel/state.json"
MAX_SUCCESS_CYCLES="${1:-}"
LOG_FILE="/tmp/webnovel_auto_reset.${WRAPPER_PID}.log"
SCRIPT_TTY="$(tty 2>/dev/null || true)"

POLL_INTERVAL_SECONDS="${WEBNOVEL_AUTO_RESET_POLL_INTERVAL_SECONDS:-2}"
COOLDOWN_SECONDS="${WEBNOVEL_AUTO_RESET_COOLDOWN_SECONDS:-60}"
CLAUDE_CMD="${WEBNOVEL_AUTO_RESET_CLAUDE_CMD:-claude}"
AUTO_COMMAND="${WEBNOVEL_AUTO_RESET_AUTO_COMMAND:-/webnovel-write}"
AUTO_COMMAND_DELAY_SECONDS="${WEBNOVEL_AUTO_RESET_AUTO_COMMAND_DELAY_SECONDS:-1}"
AUTO_COMMAND_PICK_DELAY_SECONDS="${WEBNOVEL_AUTO_RESET_AUTO_COMMAND_PICK_DELAY_SECONDS:-0.5}"
AUTO_COMMAND_CONFIRM_DELAY_SECONDS="${WEBNOVEL_AUTO_RESET_AUTO_COMMAND_CONFIRM_DELAY_SECONDS:-1.2}"
AUTO_COMMAND_FOCUS_DELAY_SECONDS="${WEBNOVEL_AUTO_RESET_AUTO_COMMAND_FOCUS_DELAY_SECONDS:-0.2}"
AUTOTYPE_LOCK_DIR="/tmp/webnovel_auto_reset.autotype.lock"

typeset -i ROUND=1
typeset -i STOP_REQUESTED=0
typeset -i COMPLETED_CYCLES=0
typeset -i REMAINING_CYCLES=0

CURRENT_PIDFILE=""
CURRENT_REASON_FILE=""
CURRENT_WATCHER_PID=""
CURRENT_AUTOTYPE_PID=""
CURRENT_AUTOTYPE_STATUS_FILE=""

log() {
  local message="$*"
  local timestamp=""
  print -r -- "$message"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  print -r -- "[${timestamp}] [wrapper] ${message}" >> "$LOG_FILE"
}

is_alive() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

read_pidfile() {
  local pidfile="${1:-}"
  local pid=""

  if [[ -n "$pidfile" && -r "$pidfile" ]]; then
    IFS= read -r pid < "$pidfile"
    print -r -- "$pid"
  fi
}

terminate_target() {
  local pid="${1:-}"
  local signal_name
  local -a signal_chain=(INT TERM KILL)

  [[ -n "$pid" ]] || return 0

  for signal_name in "${signal_chain[@]}"; do
    if ! is_alive "$pid"; then
      return 0
    fi

    kill -s "$signal_name" "$pid" 2>/dev/null || true

    if [[ "$signal_name" != "KILL" ]]; then
      sleep 2
    fi
  done
}

kill_current_child() {
  local child_pid=""

  child_pid="$(read_pidfile "${CURRENT_PIDFILE:-}")"
  if [[ -n "$child_pid" ]]; then
    terminate_target "$child_pid"
  fi
}

cleanup_round() {
  local watcher_pid="${CURRENT_WATCHER_PID:-}"
  local autotype_pid="${CURRENT_AUTOTYPE_PID:-}"

  if [[ -n "$watcher_pid" ]] && is_alive "$watcher_pid"; then
    wait "$watcher_pid" 2>/dev/null || true
  fi

  CURRENT_WATCHER_PID=""

  if [[ -n "$autotype_pid" ]] && is_alive "$autotype_pid"; then
    kill "$autotype_pid" 2>/dev/null || true
    wait "$autotype_pid" 2>/dev/null || true
  fi

  CURRENT_AUTOTYPE_PID=""

  if [[ -n "${CURRENT_PIDFILE:-}" && -e "$CURRENT_PIDFILE" ]]; then
    rm -f "$CURRENT_PIDFILE"
  fi

  CURRENT_PIDFILE=""
}

capture_terminal_target() {
  [[ -n "$SCRIPT_TTY" ]] || return 1

  TARGET_TTY_VALUE="$SCRIPT_TTY" osascript <<'EOF'
set targetTty to system attribute "TARGET_TTY_VALUE"
tell application "Terminal"
  repeat with targetWindow in windows
    repeat with i from 1 to (count tabs of targetWindow)
      try
        if tty of tab i of targetWindow is targetTty then
          return (id of targetWindow as text) & ":" & (i as text)
        end if
      end try
    end repeat
  end repeat
end tell
return ""
EOF
}

acquire_autotype_lock() {
  local lock_pid=""

  while true; do
    if mkdir "$AUTOTYPE_LOCK_DIR" 2>/dev/null; then
      print -r -- "$$" > "${AUTOTYPE_LOCK_DIR}/pid"
      return 0
    fi

    lock_pid=""
    if [[ -r "${AUTOTYPE_LOCK_DIR}/pid" ]]; then
      IFS= read -r lock_pid < "${AUTOTYPE_LOCK_DIR}/pid"
    fi

    if [[ -n "$lock_pid" ]] && ! is_alive "$lock_pid"; then
      rm -rf "$AUTOTYPE_LOCK_DIR"
      continue
    fi

    sleep 0.2
  done
}

release_autotype_lock() {
  if [[ -d "$AUTOTYPE_LOCK_DIR" ]]; then
    rm -f "${AUTOTYPE_LOCK_DIR}/pid"
    rmdir "$AUTOTYPE_LOCK_DIR" 2>/dev/null || rm -rf "$AUTOTYPE_LOCK_DIR"
  fi
}

schedule_auto_command() {
  local terminal_target=""
  local terminal_window_id=""
  local terminal_tab_index=""

  CURRENT_AUTOTYPE_STATUS_FILE=""
  CURRENT_AUTOTYPE_PID=""

  [[ -n "$AUTO_COMMAND" ]] || return 0

  terminal_target="$(capture_terminal_target 2>/dev/null || true)"
  if [[ -z "$terminal_target" || "$terminal_target" != *:* ]]; then
    log "无法获取当前 Terminal 窗口信息，自动输入功能已跳过。"
    return 0
  fi

  terminal_window_id="${terminal_target%%:*}"
  terminal_tab_index="${terminal_target##*:}"
  CURRENT_AUTOTYPE_STATUS_FILE="$(mktemp "/tmp/webnovel_auto_reset.${WRAPPER_PID}.round${ROUND}.autotype.XXXXXX")"

  (
    local autotype_result="failed"
    acquire_autotype_lock
    trap 'release_autotype_lock' EXIT
    sleep "$AUTO_COMMAND_DELAY_SECONDS"
    TERMINAL_WINDOW_ID_VALUE="$terminal_window_id" \
    TERMINAL_TAB_INDEX_VALUE="$terminal_tab_index" \
    AUTO_COMMAND_VALUE="$AUTO_COMMAND" \
    AUTO_COMMAND_FOCUS_DELAY_VALUE="$AUTO_COMMAND_FOCUS_DELAY_SECONDS" \
    AUTO_COMMAND_PICK_DELAY_VALUE="$AUTO_COMMAND_PICK_DELAY_SECONDS" \
    AUTO_COMMAND_CONFIRM_DELAY_VALUE="$AUTO_COMMAND_CONFIRM_DELAY_SECONDS" \
    osascript <<'EOF' >/dev/null 2>&1
set terminalWindowId to (system attribute "TERMINAL_WINDOW_ID_VALUE") as integer
set terminalTabIndex to (system attribute "TERMINAL_TAB_INDEX_VALUE") as integer
set autoCommand to system attribute "AUTO_COMMAND_VALUE"
set focusDelay to (system attribute "AUTO_COMMAND_FOCUS_DELAY_VALUE") as real
set pickDelay to (system attribute "AUTO_COMMAND_PICK_DELAY_VALUE") as real
set confirmDelay to (system attribute "AUTO_COMMAND_CONFIRM_DELAY_VALUE") as real
set originalClipboard to missing value

tell application "Terminal"
  activate
  set index of window id terminalWindowId to 1
  set selected of tab terminalTabIndex of window id terminalWindowId to true
end tell

delay focusDelay

try
  set originalClipboard to the clipboard
end try

set the clipboard to autoCommand

tell application "System Events"
  delay pickDelay
  keystroke "v" using command down
  delay pickDelay
  delay confirmDelay
  key code 36
  delay confirmDelay
  key code 36
end tell

if originalClipboard is not missing value then
  try
    set the clipboard to originalClipboard
  end try
end if
EOF
    if [[ $? -eq 0 ]]; then
      autotype_result="success"
    fi

    if [[ -n "$CURRENT_AUTOTYPE_STATUS_FILE" ]]; then
      print -r -- "$autotype_result" > "$CURRENT_AUTOTYPE_STATUS_FILE"
    fi
  ) &

  CURRENT_AUTOTYPE_PID=$!
}

run_claude_session() {
  schedule_auto_command
  zsh -lic "print -r -- \$\$ > \"$CURRENT_PIDFILE\"; exec \"$CLAUDE_CMD\""
}

on_wrapper_signal() {
  STOP_REQUESTED=1
  touch "$STOP_FILE"
  log ""
  log "收到停止信号，正在结束当前 Claude 会话并停止自动重启..."
  kill_current_child
}

final_cleanup() {
  STOP_REQUESTED=1
  touch "$STOP_FILE"
  kill_current_child
  cleanup_round

  if [[ -n "${CURRENT_REASON_FILE:-}" && -e "$CURRENT_REASON_FILE" ]]; then
    rm -f "$CURRENT_REASON_FILE"
  fi

  if [[ -n "${CURRENT_AUTOTYPE_STATUS_FILE:-}" && -e "$CURRENT_AUTOTYPE_STATUS_FILE" ]]; then
    rm -f "$CURRENT_AUTOTYPE_STATUS_FILE"
  fi

  rm -f "$STOP_FILE"
}

if [[ ! -f "$PROJECT_STATE_FILE" ]]; then
  log "当前目录不是有效的小说项目根目录。"
  log "请先 cd 到包含 .webnovel/state.json 的目录，再运行本脚本。"
  exit 1
fi

if [[ ! -f "$WATCHER_SCRIPT" ]]; then
  log "未找到 watcher 脚本: $WATCHER_SCRIPT"
  exit 1
fi

if [[ -z "$SCRIPT_TTY" ]]; then
  log "当前会话没有可识别的 TTY。请直接在 macOS Terminal 的交互式标签页里运行本脚本。"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  log "未找到 python3，无法启动完成检测器。"
  exit 1
fi

if ! command -v osascript >/dev/null 2>&1; then
  log "未找到 osascript，无法自动向 Claude 发送 /webnovel-write。"
  exit 1
fi

if ! command -v "$CLAUDE_CMD" >/dev/null 2>&1; then
  log "未找到 $CLAUDE_CMD 命令，脚本退出。"
  exit 1
fi

rm -f "$STOP_FILE"

trap 'on_wrapper_signal' INT TERM HUP
trap 'final_cleanup' EXIT

log "webnovel 自动重启 wrapper 已启动"
log "当前小说目录: $PROJECT_ROOT"
log "当前终端 TTY: $SCRIPT_TTY"
log "wrapper PID: $WRAPPER_PID"
log "停止文件: $STOP_FILE"
log "日志文件: $LOG_FILE"
log "说明: 只会在 /webnovel-write 成功完成并额外等待 ${COOLDOWN_SECONDS} 秒后重启。"
log "说明: 成功前手动 /exit 或任务失败，不会自动重启。"
log "说明: 每轮 Claude 启动后会自动发送: ${AUTO_COMMAND}"
log "说明: 如果是第一次使用，请确认 macOS 已允许“终端/系统事件”辅助功能权限。"
if [[ -n "$MAX_SUCCESS_CYCLES" ]]; then
  REMAINING_CYCLES=$MAX_SUCCESS_CYCLES
  log "说明: 本次最多自动完成 ${MAX_SUCCESS_CYCLES} 轮成功章节，达到后自动停止。"
else
  log "说明: 未设置循环次数，将无限循环。"
fi

while true; do
  round_reason=""
  autotype_status=""

  CURRENT_PIDFILE="$(mktemp "/tmp/webnovel_auto_reset.${WRAPPER_PID}.round${ROUND}.pid.XXXXXX")"
  CURRENT_REASON_FILE="${CURRENT_PIDFILE}.reason"

  WEBNOVEL_AUTO_RESET_LOG_FILE="$LOG_FILE" \
  python3 "$WATCHER_SCRIPT" \
    --project-root "$PROJECT_ROOT" \
    --claude-pid-file "$CURRENT_PIDFILE" \
    --wrapper-pid "$WRAPPER_PID" \
    --reason-file "$CURRENT_REASON_FILE" \
    --stop-file "$STOP_FILE" \
    --poll-interval "$POLL_INTERVAL_SECONDS" \
    --cooldown-seconds "$COOLDOWN_SECONDS" &
  CURRENT_WATCHER_PID=$!

  log "第 ${ROUND} 轮 Claude 已启动。稍后会自动发送 ${AUTO_COMMAND}。"
  run_claude_session

  cleanup_round

  if [[ -r "$CURRENT_REASON_FILE" ]]; then
    IFS= read -r round_reason < "$CURRENT_REASON_FILE"
  fi

  if [[ -r "${CURRENT_AUTOTYPE_STATUS_FILE:-}" ]]; then
    IFS= read -r autotype_status < "$CURRENT_AUTOTYPE_STATUS_FILE"
  fi

  if [[ -n "${CURRENT_REASON_FILE:-}" && -e "$CURRENT_REASON_FILE" ]]; then
    rm -f "$CURRENT_REASON_FILE"
  fi
  CURRENT_REASON_FILE=""

  if [[ -n "${CURRENT_AUTOTYPE_STATUS_FILE:-}" && -e "$CURRENT_AUTOTYPE_STATUS_FILE" ]]; then
    rm -f "$CURRENT_AUTOTYPE_STATUS_FILE"
  fi
  CURRENT_AUTOTYPE_STATUS_FILE=""

  case "${round_reason:-}" in
    completed)
      (( COMPLETED_CYCLES += 1 ))
      if [[ -n "$MAX_SUCCESS_CYCLES" ]]; then
        REMAINING_CYCLES=$((MAX_SUCCESS_CYCLES - COMPLETED_CYCLES))
        log "进度: 已成功完成 ${COMPLETED_CYCLES}/${MAX_SUCCESS_CYCLES} 轮，剩余 ${REMAINING_CYCLES} 轮。"
      else
        log "进度: 已成功完成 ${COMPLETED_CYCLES} 轮，当前为无限循环模式。"
      fi

      if [[ -n "$MAX_SUCCESS_CYCLES" ]] && (( COMPLETED_CYCLES >= MAX_SUCCESS_CYCLES )); then
        log "已完成 ${COMPLETED_CYCLES} 轮成功章节，达到设定循环次数，wrapper 自动停止。"
        break
      fi

      if (( STOP_REQUESTED == 1 )) || [[ -e "$STOP_FILE" ]]; then
        log "检测到停止请求，不再重启新的 Claude 会话。"
        break
      fi
      clear
      log "第 $((ROUND + 1)) 轮 Claude 已拉起。上一章已完成，上下文已清空。"
      if [[ -n "$MAX_SUCCESS_CYCLES" ]]; then
        log "当前还可继续自动完成 ${REMAINING_CYCLES} 轮成功章节。"
      fi
      (( ROUND += 1 ))
      ;;
    failed)
      log "第 ${ROUND} 轮检测到 /webnovel-write 执行失败，wrapper 自动停止。"
      break
      ;;
    manual_exit)
      log "第 ${ROUND} 轮在成功完成前检测到 Claude 已退出，wrapper 自动停止。"
      break
      ;;
    no_tracked_task)
      log "第 ${ROUND} 轮未检测到新的 /webnovel-write，wrapper 自动停止。"
      if [[ "$autotype_status" == "failed" ]]; then
        log "自动输入 /webnovel-write 失败。请到“系统设置 -> 隐私与安全性 -> 辅助功能”里确认 Terminal 和 System Events 已获授权。"
      fi
      break
      ;;
    stopped)
      log "第 ${ROUND} 轮检测到停止请求，wrapper 自动停止。"
      break
      ;;
    "")
      if (( STOP_REQUESTED == 1 )) || [[ -e "$STOP_FILE" ]]; then
        log "收到停止请求，wrapper 已停止。"
      else
        log "未收到完成检测结果。为了安全起见，本次不会自动重启。"
      fi
      break
      ;;
    *)
      log "检测器返回未知状态: ${round_reason}。为了安全起见，本次不会自动重启。"
      break
      ;;
  esac
done
