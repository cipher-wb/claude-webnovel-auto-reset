#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Optional


TRACE_EVENT_TASK_STARTED = "task_started"
TRACE_EVENT_TASK_REENTERED = "task_reentered"
TRACE_EVENT_TASK_COMPLETED = "task_completed"
TRACE_EVENT_TASK_FAILED = "task_failed"

TARGET_COMMAND = "webnovel-write"
STATE_IDLE = "idle"
STATE_TRACKING = "tracking"
STATE_COOLDOWN = "cooldown"


def log(message: str) -> None:
    log_file = os.environ.get("WEBNOVEL_AUTO_RESET_LOG_FILE")
    if log_file:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        try:
            with open(log_file, "a", encoding="utf-8") as fh:
                fh.write(f"[{timestamp}] [watcher] {message}\n")
        except OSError:
            pass
    print(message, file=sys.stderr, flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="监听 webnovel-write 完成状态")
    parser.add_argument("--project-root", required=True, help="小说项目根目录")
    parser.add_argument("--claude-pid-file", required=True, help="当前 Claude PID 文件")
    parser.add_argument("--wrapper-pid", required=True, type=int, help="wrapper PID")
    parser.add_argument("--reason-file", required=True, help="结果原因文件")
    parser.add_argument("--stop-file", required=True, help="停止文件路径")
    parser.add_argument("--poll-interval", type=float, default=2.0, help="轮询间隔秒数")
    parser.add_argument("--cooldown-seconds", type=float, default=60.0, help="成功后保底等待秒数")
    return parser.parse_args()


def is_alive(pid: Optional[int]) -> bool:
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(read_text(path))


def parse_iso_to_ts(value: Optional[str]) -> Optional[float]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value).timestamp()
    except ValueError:
        return None


def read_pid_file(path: Path) -> Optional[int]:
    try:
        text = read_text(path).strip()
    except OSError:
        return None
    if not text:
        return None
    try:
        return int(text)
    except ValueError:
        return None


def safe_mtime(path: Path) -> Optional[float]:
    try:
        return path.stat().st_mtime
    except OSError:
        return None


def append_reason(path: Path, reason: str) -> None:
    path.write_text(reason + "\n", encoding="utf-8")


def terminate_pid(pid: Optional[int]) -> None:
    if not is_alive(pid):
        return

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
        if not is_alive(pid):
            return
        try:
            os.kill(pid, sig)
        except OSError:
            return
        if sig != signal.SIGKILL:
            time.sleep(2)


def read_trace_events(path: Path, offset: int) -> tuple[list[dict[str, Any]], int]:
    if not path.exists():
        return [], offset

    events: list[dict[str, Any]] = []
    new_offset = offset

    with path.open("rb") as f:
        f.seek(offset)
        chunk = f.read()

    if not chunk:
        return events, offset

    lines = chunk.splitlines(keepends=True)
    consumed = 0
    for raw_line in lines:
        if not raw_line.endswith(b"\n"):
            break
        consumed += len(raw_line)
        line = raw_line.decode("utf-8", errors="ignore").strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue

    new_offset += consumed
    return events, new_offset


def latest_history_entry(state: dict[str, Any]) -> Optional[dict[str, Any]]:
    history = state.get("history") or []
    if not history:
        return None
    return history[-1]


def find_chapter_file(project_root: Path, chapter_num: int) -> Optional[Path]:
    chapter_dir = project_root / "正文"
    if not chapter_dir.exists():
        return None

    matches = sorted(chapter_dir.glob(f"第{chapter_num:04d}章*.md"))
    for match in matches:
        try:
            if match.is_file() and match.stat().st_size > 0:
                return match
        except OSError:
            continue
    return None


def fallback_artifacts_ready(project_root: Path, chapter_num: int, started_ts: float) -> bool:
    tolerance_ts = started_ts - 1.0
    chapter_file = find_chapter_file(project_root, chapter_num)
    summary_file = project_root / ".webnovel" / "summaries" / f"ch{chapter_num:04d}.md"
    state_file = project_root / ".webnovel" / "state.json"
    index_file = project_root / ".webnovel" / "index.db"

    if chapter_file is None:
        return False

    if not summary_file.exists() or not state_file.exists() or not index_file.exists():
        return False

    try:
        if summary_file.stat().st_size <= 0:
            return False
    except OSError:
        return False

    chapter_mtime = safe_mtime(chapter_file)
    summary_mtime = safe_mtime(summary_file)
    state_mtime = safe_mtime(state_file)
    index_mtime = safe_mtime(index_file)

    mtimes = [chapter_mtime, summary_mtime, state_mtime, index_mtime]
    if any(ts is None for ts in mtimes):
        return False

    return all(ts is not None and ts >= tolerance_ts for ts in mtimes)


@dataclass
class WatchState:
    phase: str = STATE_IDLE
    tracked_chapter: Optional[int] = None
    task_started_ts: Optional[float] = None
    cooldown_started_monotonic: Optional[float] = None
    cooldown_notified: bool = False
    child_exit_during_cooldown_logged: bool = False


class CompletionWatcher:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.project_root = Path(args.project_root).resolve()
        self.pid_file = Path(args.claude_pid_file)
        self.reason_file = Path(args.reason_file)
        self.stop_file = Path(args.stop_file)
        self.workflow_state_path = self.project_root / ".webnovel" / "workflow_state.json"
        self.call_trace_path = self.project_root / ".webnovel" / "observability" / "call_trace.jsonl"
        self.started_wall_ts = time.time()
        self.started_monotonic = time.monotonic()
        self.trace_offset = self.call_trace_path.stat().st_size if self.call_trace_path.exists() else 0
        self.baseline_history_len = self._initial_history_len()
        self.child_pid: Optional[int] = None
        self.state = WatchState()
        self.failure_reason: Optional[str] = None

    def _initial_history_len(self) -> int:
        state = self._load_workflow_state()
        history = state.get("history") or []
        return len(history)

    def _load_workflow_state(self) -> dict[str, Any]:
        if not self.workflow_state_path.exists():
            return {"current_task": None, "history": []}
        try:
            state = load_json(self.workflow_state_path)
        except (OSError, json.JSONDecodeError):
            return {"current_task": None, "history": []}
        state.setdefault("current_task", None)
        state.setdefault("history", [])
        return state

    def _wait_for_child_pid(self) -> bool:
        while True:
            if self.stop_file.exists():
                append_reason(self.reason_file, "stopped")
                return False

            pid = read_pid_file(self.pid_file)
            if pid:
                self.child_pid = pid
                return True

            if not is_alive(self.args.wrapper_pid):
                return False

            time.sleep(0.1)

    def _enter_tracking(self, chapter_num: Optional[int], started_ts: Optional[float], source: str) -> None:
        if not chapter_num:
            return

        if self.state.phase == STATE_IDLE:
            self.state.phase = STATE_TRACKING
            self.state.tracked_chapter = chapter_num
            self.state.task_started_ts = started_ts or time.time()
            if source == "workflow_state_existing":
                log(f"检测到已有运行中的 /webnovel-write {chapter_num}，开始接管监听完成信号。")
            else:
                log(f"检测到 /webnovel-write {chapter_num} 已启动，开始监听完成信号。")
            return

        if self.state.tracked_chapter is None:
            self.state.tracked_chapter = chapter_num
        if self.state.task_started_ts is None:
            self.state.task_started_ts = started_ts or time.time()

        if source == TRACE_EVENT_TASK_REENTERED and self.state.phase == STATE_TRACKING:
            log(f"检测到 /webnovel-write {chapter_num} 重入，继续跟踪当前章节。")

    def _enter_cooldown(self, source: str) -> None:
        if self.state.phase == STATE_COOLDOWN:
            return

        if self.state.phase != STATE_TRACKING or self.state.tracked_chapter is None:
            return

        self.state.phase = STATE_COOLDOWN
        self.state.cooldown_started_monotonic = time.monotonic()
        self.state.cooldown_notified = True
        log(
            f"检测到第 {self.state.tracked_chapter} 章写作完成，"
            f"进入 {int(self.args.cooldown_seconds)} 秒保底等待，时间到后会自动重启 Claude。"
        )

    def _mark_failure(self, reason: str) -> int:
        if not self.failure_reason:
            self.failure_reason = reason
            append_reason(self.reason_file, reason)
            if reason == "failed":
                log("检测到 /webnovel-write 执行失败，本次不会自动重启。")
            elif reason == "manual_exit":
                log("在成功完成前检测到 Claude 已退出，本次不会自动重启。")
            elif reason == "no_tracked_task":
                log("本轮未检测到新的 /webnovel-write，本次不会自动重启。")
            elif reason == "stopped":
                log("检测到停止请求，本次不会自动重启。")
            else:
                log(f"检测结束，原因: {reason}")
        return 0

    def _handle_trace_events(self) -> Optional[int]:
        events, new_offset = read_trace_events(self.call_trace_path, self.trace_offset)
        self.trace_offset = new_offset

        for row in events:
            event = row.get("event")
            payload = row.get("payload") or {}
            timestamp = parse_iso_to_ts(row.get("timestamp")) or time.time()

            if event == TRACE_EVENT_TASK_STARTED and payload.get("command") == TARGET_COMMAND:
                args = payload.get("args") or {}
                self._enter_tracking(args.get("chapter_num"), timestamp, event)
                continue

            if event == TRACE_EVENT_TASK_REENTERED and payload.get("command") == TARGET_COMMAND:
                self._enter_tracking(payload.get("chapter"), timestamp, event)
                continue

            if event == TRACE_EVENT_TASK_COMPLETED and payload.get("command") == TARGET_COMMAND:
                chapter = payload.get("chapter")
                if self.state.tracked_chapter is None:
                    self._enter_tracking(chapter, timestamp, event)
                if chapter == self.state.tracked_chapter:
                    self._enter_cooldown("call_trace")
                continue

            if event == TRACE_EVENT_TASK_FAILED and payload.get("command") == TARGET_COMMAND:
                chapter = payload.get("chapter")
                if self.state.tracked_chapter is None or chapter == self.state.tracked_chapter:
                    return self._mark_failure("failed")

        return None

    def _handle_workflow_state(self) -> Optional[int]:
        state = self._load_workflow_state()
        current_task = state.get("current_task")
        history = state.get("history") or []

        if current_task and current_task.get("command") == TARGET_COMMAND:
            started_ts = parse_iso_to_ts(current_task.get("started_at"))
            last_heartbeat_ts = parse_iso_to_ts(current_task.get("last_heartbeat"))
            task_status = current_task.get("status")
            chapter_num = (current_task.get("args") or {}).get("chapter_num")

            if task_status == "running":
                if (
                    started_ts is not None and started_ts >= self.started_wall_ts - 1.0
                ) or (
                    last_heartbeat_ts is not None and last_heartbeat_ts >= self.started_wall_ts - 1.0
                ):
                    self._enter_tracking(chapter_num, started_ts or last_heartbeat_ts, "workflow_state")
                elif self.state.phase == STATE_IDLE:
                    reference_ts = started_ts or last_heartbeat_ts or self.started_wall_ts
                    self._enter_tracking(chapter_num, reference_ts, "workflow_state_existing")

            if task_status == "failed":
                if self.state.tracked_chapter is None or chapter_num == self.state.tracked_chapter:
                    return self._mark_failure("failed")

        if len(history) > self.baseline_history_len:
            last = latest_history_entry(state)
            if last:
                completed_at_ts = parse_iso_to_ts(last.get("completed_at"))
                if last.get("command") == TARGET_COMMAND and last.get("status") == "completed" and current_task is None:
                    if self.state.phase == STATE_IDLE:
                        if completed_at_ts is not None and completed_at_ts >= self.started_wall_ts - 2.0:
                            self._enter_tracking(last.get("chapter"), self.started_wall_ts, "workflow_state_completed")
                            self._enter_cooldown("workflow_state_completed")
                    elif self.state.phase == STATE_TRACKING:
                        expected_start = self.state.task_started_ts or self.started_wall_ts
                        if (
                            last.get("chapter") == self.state.tracked_chapter
                            and completed_at_ts is not None
                            and completed_at_ts >= expected_start - 1.0
                        ):
                            self._enter_cooldown("workflow_state")

        return None

    def _handle_artifact_fallback(self) -> None:
        if self.state.phase != STATE_TRACKING:
            return
        if self.state.tracked_chapter is None or self.state.task_started_ts is None:
            return

        workflow_state = self._load_workflow_state()
        current_task = workflow_state.get("current_task")
        if (
            current_task
            and current_task.get("command") == TARGET_COMMAND
            and current_task.get("status") == "running"
        ):
            current_chapter = (current_task.get("args") or {}).get("chapter_num")
            if current_chapter == self.state.tracked_chapter:
                return

        if fallback_artifacts_ready(self.project_root, self.state.tracked_chapter, self.state.task_started_ts):
            self._enter_cooldown("artifact_fallback")

    def _handle_stop_request(self) -> Optional[int]:
        if not self.stop_file.exists():
            return None

        if is_alive(self.child_pid):
            terminate_pid(self.child_pid)
        return self._mark_failure("stopped")

    def _handle_wrapper_exit(self) -> bool:
        if is_alive(self.args.wrapper_pid):
            return False
        if is_alive(self.child_pid):
            terminate_pid(self.child_pid)
        return True

    def _handle_child_exit(self) -> Optional[int]:
        if is_alive(self.child_pid):
            return None

        if self.state.phase == STATE_COOLDOWN:
            if not self.state.child_exit_during_cooldown_logged:
                self.state.child_exit_during_cooldown_logged = True
                log("Claude 已在保底等待期间退出，等待剩余时间后会自动拉起新会话。")
            return None

        if self.state.phase == STATE_TRACKING:
            return self._mark_failure("manual_exit")

        if self.state.phase == STATE_IDLE:
            return self._mark_failure("no_tracked_task")

        return None

    def _handle_cooldown(self) -> Optional[int]:
        if self.state.phase != STATE_COOLDOWN or self.state.cooldown_started_monotonic is None:
            return None

        elapsed = time.monotonic() - self.state.cooldown_started_monotonic
        if elapsed < self.args.cooldown_seconds:
            return None

        append_reason(self.reason_file, "completed")
        if is_alive(self.child_pid):
            terminate_pid(self.child_pid)
        return 0

    def run(self) -> int:
        if not self._wait_for_child_pid():
            return 0

        while True:
            if self._handle_wrapper_exit():
                return 0

            result = self._handle_stop_request()
            if result is not None:
                return result

            result = self._handle_trace_events()
            if result is not None:
                return result

            result = self._handle_workflow_state()
            if result is not None:
                return result

            self._handle_artifact_fallback()

            result = self._handle_cooldown()
            if result is not None:
                return result

            result = self._handle_child_exit()
            if result is not None:
                return result

            time.sleep(self.args.poll_interval)


def main() -> int:
    args = parse_args()
    watcher = CompletionWatcher(args)
    return watcher.run()


if __name__ == "__main__":
    raise SystemExit(main())
