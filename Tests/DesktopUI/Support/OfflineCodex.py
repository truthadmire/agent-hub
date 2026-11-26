#!/usr/bin/env python3
"""A local-only Codex protocol fixture for the packaged app's orchestration path."""
import json
import sys
import time
import uuid
from pathlib import Path

args = sys.argv[1:]
if args == ["--version"]:
    print("codex-cli 0.178.0-ui.fixture")
elif args == ["exec", "--help"]:
    print("Offline UI fixture: exec --json --sandbox --ignore-user-config resume")
elif args == ["login", "status"]:
    print("Logged in using ChatGPT (simulated for offline UI tests)")
elif "exec" in args and "--json" in args:
    managed = Path(__file__).resolve().parents[1] / "data" / "Managed"
    cwd = Path.cwd().resolve()
    if not cwd.is_relative_to(managed.resolve()) or not (cwd / ".git").is_file():
        sys.exit("This fixture can edit only its isolated app-managed Git worktree.")
    prompt = sys.stdin.read()
    if "Observe incoming history" in prompt:
        inbox = Path((Path(__file__).parent / "history-inbox").read_text().strip())
        def output(identifier, text):
            print(json.dumps({"type": "item.completed", "item": {"id": identifier,
                  "type": "agent_message", "text": text}}), flush=True)
        for index in range(100):
            output("history-" + str(index), "UI history entry %03d" % index)
        deadline = time.monotonic() + 55
        while not (inbox / "history-release").is_file():
            if time.monotonic() > deadline:
                sys.exit("Timed out while waiting for the history reader.")
            time.sleep(.1)
        output("incoming", "New controlled provider message reached the feed")
        time.sleep(1)

    status = cwd / "status.txt"
    if status.read_bytes() != b"pending\n":
        sys.exit("Unexpected project baseline.")
    status.write_bytes(b"verified\n")
    for record in [
        {"type": "thread.started", "thread_id": str(uuid.uuid4())},
        {"type": "item.completed", "item": {"id": "answer", "type": "agent_message",
          "text": "Offline UI fixture wrote verified to status.txt."}},
        {"type": "turn.completed", "usage": {"input_tokens": 3, "output_tokens": 2}},
    ]:
        print(json.dumps(record), flush=True)
else:
    sys.exit("Unsupported offline fixture command.")
