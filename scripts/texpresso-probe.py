#!/usr/bin/env python3
"""Probe TeXpresso's editor protocol without changing TeXLocal's build path.

Example:
  python3 scripts/texpresso-probe.py main.tex --find 'Hello' --replace 'Hi'

The edit lives only in TeXpresso's virtual file system. This script never
writes the source file or imports TeXpresso into the application.
"""

import argparse
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import threading
import time


def stop_tree(child):
    if os.name == "nt":
        if child.poll() is None:
            subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           check=False)
    else:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            child.kill()
        else:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        child.wait(timeout=2)


def probe(command, root, find, replace, startup_timeout, edit_timeout):
    source = root.read_text(encoding="utf-8")
    if not find or source.count(find) != 1:
        raise ValueError("--find must occur exactly once in the root file")
    byte_offset = len(source[:source.index(find)].encode("utf-8"))
    byte_length = len(find.encode("utf-8"))
    events = queue.Queue()
    stderr_tail = []
    creation_flags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
    child = subprocess.Popen(
        [*command, "-json", "-lines", str(root)], cwd=root.parent,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace", bufsize=1,
        start_new_session=os.name != "nt", creationflags=creation_flags,
    )

    def read_stdout():
        for line in child.stdout:
            try:
                event = json.loads(line)
                if isinstance(event, list) and event:
                    events.put((time.monotonic(), event[0]))
            except json.JSONDecodeError:
                events.put((time.monotonic(), "invalid-json"))
        events.put((time.monotonic(), "eof"))

    def read_stderr():
        for line in child.stderr:
            stderr_tail.append(line.rstrip())
            if len(stderr_tail) > 12:
                stderr_tail.pop(0)

    output_reader = threading.Thread(target=read_stdout, daemon=True)
    error_reader = threading.Thread(target=read_stderr, daemon=True)
    output_reader.start()
    error_reader.start()

    def send(message):
        child.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
        child.stdin.flush()

    def until_flush(timeout):
        deadline = time.monotonic() + timeout
        seen = []
        while True:
            try:
                event = events.get(timeout=max(0, deadline - time.monotonic()))
            except queue.Empty:
                raise TimeoutError("no flush received before the deadline") from None
            seen.append(event)
            if event[1] == "eof":
                raise RuntimeError(f"TeXpresso exited with code {child.poll()}")
            if event[1] == "flush":
                return seen

    try:
        started = time.monotonic()
        initial = until_flush(startup_timeout)
        # Discard events already read; asynchronous events may still be in flight.
        while not events.empty():
            events.get_nowait()
        # The root exists in TeXpresso's file table after the initial pass.
        send(["open", str(root), source])
        edited_at = time.monotonic()
        send(["change", str(root), byte_offset, byte_length, replace])
        changed = until_flush(edit_timeout)
        first_output = next((at for at, verb in changed
                             if verb in ("append", "append-lines", "truncate", "truncate-lines")), None)
        return {
            "launch_to_first_flush_ms": round((initial[-1][0] - started) * 1000),
            "after_send_next_output_ms": round((first_output - edited_at) * 1000) if first_output else None,
            "after_send_next_flush_ms": round((changed[-1][0] - edited_at) * 1000),
            "events_after_send": [verb for _, verb in changed],
            "note": "Asynchronous events are not correlated to the edit; PDF correctness and RSS are not measured.",
        }
    except Exception as error:
        raise RuntimeError(f"{error}; stderr tail: {' | '.join(stderr_tail)}") from error
    finally:
        stop_tree(child)
        child.stdin.close()
        output_reader.join(timeout=1)
        error_reader.join(timeout=1)
        child.stdout.close()
        child.stderr.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--binary", default="texpresso")
    parser.add_argument("--provider", choices=("texlive", "tectonic"))
    parser.add_argument("--find", required=True)
    parser.add_argument("--replace", required=True)
    parser.add_argument("--startup-timeout", type=float, default=120)
    parser.add_argument("--edit-timeout", type=float, default=15)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    binary = str(Path(args.binary).resolve()) if os.path.dirname(args.binary) else args.binary
    command = [binary] + ([f"-{args.provider}"] if args.provider else [])
    try:
        print(json.dumps(probe(command, root, args.find, args.replace,
                               args.startup_timeout, args.edit_timeout), indent=2))
    except (OSError, ValueError, RuntimeError) as error:
        print(f"TeXpresso probe failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
