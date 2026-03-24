#!/bin/zsh

set -u

INTERVAL_SECONDS=15
WRAPPER_PID=$$
STOP_FILE="/tmp/claude_reset_loop.${WRAPPER_PID}.stop"

typeset -i ROUND=1
typeset -i STOP_REQUESTED=0

CURRENT_PIDFILE=""
CURRENT_REASON_FILE=""
CURRENT_WATCHER_PID=""

log() {
  print -r -- "$*"
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

  if [[ -n "$watcher_pid" ]] && is_alive "$watcher_pid"; then
    kill "$watcher_pid" 2>/dev/null || true
  fi

  if [[ -n "$watcher_pid" ]]; then
    wait "$watcher_pid" 2>/dev/null || true
  fi

  CURRENT_WATCHER_PID=""

  if [[ -n "${CURRENT_PIDFILE:-}" && -e "$CURRENT_PIDFILE" ]]; then
    rm -f "$CURRENT_PIDFILE"
  fi

  if [[ -n "${CURRENT_REASON_FILE:-}" && -e "$CURRENT_REASON_FILE" ]]; then
    rm -f "$CURRENT_REASON_FILE"
  fi

  CURRENT_PIDFILE=""
  CURRENT_REASON_FILE=""
}

on_wrapper_signal() {
  STOP_REQUESTED=1
  log ""
  log "收到停止信号，正在结束当前 Claude 会话..."
  kill_current_child
}

final_cleanup() {
  STOP_REQUESTED=1
  kill_current_child
  cleanup_round
  rm -f "$STOP_FILE"
}

start_watcher() {
  local pidfile="$1"
  local reason_file="$2"
  local wrapper_pid="$3"

  (
    local child_pid=""
    typeset -i ticks=0
    typeset -i max_ticks=$((INTERVAL_SECONDS * 10))

    while [[ ! -s "$pidfile" ]]; do
      if ! is_alive "$wrapper_pid"; then
        exit 0
      fi
      sleep 0.1
    done

    IFS= read -r child_pid < "$pidfile"
    [[ -n "$child_pid" ]] || exit 0

    while (( ticks < max_ticks )); do
      if ! is_alive "$child_pid"; then
        exit 0
      fi

      if ! is_alive "$wrapper_pid"; then
        print -r -- "wrapper_exit" > "$reason_file"
        terminate_target "$child_pid"
        exit 0
      fi

      sleep 0.1
      (( ticks += 1 ))
    done

    if is_alive "$child_pid"; then
      print -r -- "timeout" > "$reason_file"
      terminate_target "$child_pid"
    fi
  ) &

  CURRENT_WATCHER_PID=$!
}

if ! command -v claude >/dev/null 2>&1; then
  log "未找到 claude 命令，脚本退出。"
  exit 1
fi

rm -f "$STOP_FILE"

trap 'on_wrapper_signal' INT TERM HUP
trap 'final_cleanup' EXIT

log "Claude 15 秒自动重启 wrapper 已启动"
log "wrapper PID: $WRAPPER_PID"
log "停止文件: $STOP_FILE"
log "说明: 手动 /exit 只结束当前轮，wrapper 会继续重启。"
log "即将启动第 ${ROUND} 轮 Claude，会在 ${INTERVAL_SECONDS} 秒后自动重启。"

while true; do
  round_reason=""

  CURRENT_PIDFILE="$(mktemp "/tmp/claude_reset_loop.${WRAPPER_PID}.round${ROUND}.pid.XXXXXX")"
  CURRENT_REASON_FILE="${CURRENT_PIDFILE}.reason"

  start_watcher "$CURRENT_PIDFILE" "$CURRENT_REASON_FILE" "$WRAPPER_PID"

  env PIDFILE="$CURRENT_PIDFILE" zsh -c 'print -r -- $$ > "$PIDFILE"; exec claude'

  if [[ -r "$CURRENT_REASON_FILE" ]]; then
    IFS= read -r round_reason < "$CURRENT_REASON_FILE"
  fi

  cleanup_round

  if (( STOP_REQUESTED == 1 )) || [[ -e "$STOP_FILE" ]]; then
    log "wrapper 已停止，不再启动新的 Claude 会话。"
    break
  fi

  clear
  if [[ "$round_reason" == "timeout" ]]; then
    log "Claude 已重启，第 $((ROUND + 1)) 轮，${INTERVAL_SECONDS} 秒后再次重启。"
  else
    log "Claude 会话已结束，正在启动第 $((ROUND + 1)) 轮，${INTERVAL_SECONDS} 秒后再次重启。"
  fi
  (( ROUND += 1 ))
done
