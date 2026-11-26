#!/usr/bin/env python3
"""Offline provider double. Invoked only through copies installed by HubSmoke."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid


def emit(data):
    print(json.dumps(data, ensure_ascii=False), flush=True)


def complete(text):
    if provider == "codex":
        emit({"type": "item.completed", "item": {"id": "answer", "type": "agent_message", "text": text}})
        emit({"type": "turn.completed", "usage": {"input_tokens": 33, "output_tokens": 12}})
    elif provider == "agy":
        emit({"event": "result", "result": {"conversation_id": session_id, "status": "SUCCESS",
                                           "response": text, "usage": {"input_tokens": 33, "output_tokens": 12}}})
    else:
        emit({"type": "status", "phase": "turn_end", "reason": {"kind": "completed"}})
        emit({"type": "final", "text": text})


def item(identifier, role, filename, dependencies=()):
    return {"id": identifier, "title": identifier, "role": role,
            "dependencies": list(dependencies), "inputs": ["Field Notes API contract in README.md"],
            "deliverables": [filename], "readScope": ["."], "writeScope": [filename]}


bin_dir = Path(__file__).resolve().parent
root = bin_dir.parent.parent
config = json.loads((bin_dir.parent / "fixture.json").read_text())
cwd = Path.cwd().resolve()
if not cwd.is_relative_to((root / "managed").resolve()) or not (cwd / ".git").is_file():
    sys.exit("Fixture CLI requires a HubSmoke-managed linked worktree")
provider = Path(sys.argv[0]).name
scenario = config["scenario"]
raw = sys.stdin.read()
prompt = json.loads(raw)["message"]["content"] if provider == "agy" else raw
session_id = str(uuid.uuid4())
if provider == "codex":
    emit({"type": "thread.started", "thread_id": session_id})
elif provider == "agy":
    emit({"event": "init", "conversation_id": session_id})
else:
    emit({"type": "session", "sessionId": "session-" + session_id})

if "You are the planning lead" in prompt:
    plan = {"goal": "Add photo category filters, pagination and an empty state.",
            "interfaces": ["Filter before paginating. Return items, page, pages and total."],
            "checks": ["Run the Python suite."], "questions": [], "acceptance": [],
            "items": [item("catalogue", "backend", "catalog.py"), item("filters", "frontend", "page.py"),
                      item("contract-tests", "test", "tests/test_filter.py", ["catalogue", "filters"])]}
    complete(json.dumps(plan))
elif scenario == "gallery":
    targets = {"codex": "catalog.py", "agy": "page.py", "dsh": "tests/test_filter.py"}
    path = targets[provider]
    # The test worker checks that both dependency changes reached its own baseline.
    if provider == "dsh" and ("selected[start:" not in Path("catalog.py").read_text()
                              or "Apply filter" not in Path("page.py").read_text()):
        sys.exit("The test worker received an incomplete dependency baseline")
    if provider in {"codex", "agy"}:
        rendezvous = bin_dir.parent
        (rendezvous / ("ready-" + provider)).touch()
        other = "agy" if provider == "codex" else "codex"
        deadline = time.monotonic() + 15
        while not (rendezvous / ("ready-" + other)).exists():
            if time.monotonic() > deadline:
                sys.exit("Parallel workers never overlapped")
            time.sleep(.05)
    shutil.copyfile(bin_dir.parent / "solution" / path, cwd / path)
    complete("Offline fixture wrote " + path)
elif scenario in {"cancel", "restart", "pause"} and not (bin_dir.parent / "interrupted").exists():
    Path("status.txt").write_text("partial\n")
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(45)"])
    (bin_dir.parent / "interrupted").write_text(str(child.pid))
    child.wait()
    complete("Late fixture result")
elif scenario == "auth":
    print("Unauthenticated: sign in before continuing", file=sys.stderr)
    sys.exit(1)
elif scenario == "protocol":
    print('{"type":"item.started",broken', flush=True)
elif scenario == "quota" and provider == "codex":
    Path("status.txt").write_text("partial-quota\n")
    print("429 rate limit; retry later", file=sys.stderr)
    sys.exit(1)
else:
    if scenario in {"pause", "restart", "quota"}:
        required = "partial-quota\n" if scenario == "quota" else "partial\n"
        if Path("status.txt").read_text() != required:
            sys.exit("Saved partial file was missing in the replacement attempt")
    should_fail = scenario == "stalled" or (scenario == "repair" and
        not (bin_dir.parent / "first-edit").exists())
    result = "wrong" if should_fail else "verified"
    Path("status.txt").write_text(result + "\n")
    (bin_dir.parent / "first-edit").touch()
    complete("Fixture reports that the task is complete")
