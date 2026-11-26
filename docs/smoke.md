# End-to-end verification

HubSmoke creates a temporary application database and Git repository containing only synthetic files. It imports the committed repository, creates a task through HubStore and starts HubEngine. CLI subprocesses run in linked Git worktrees. The harness closes the engine, reopens the SQLite store with its exclusive lock, compares the original checkout and HEAD with their baseline, and checks the integrated files independently. Every run prints the location of its database, `result.json`, and `integrated.patch`. Failed checks remain inspectable.

## Reproduce

Run these from the source checkout on a Mac with the Swift toolchain, Git and Python 3. The verification runner uses macOS Seatbelt. Nested sandbox policies can prevent startup of that sandbox or its local HTTP listener. In that case HubSmoke records a blocked verification.

```sh
scripts/smoke.sh --fixture gallery
scripts/smoke.sh --fixture repair
scripts/smoke.sh --fixture restart
```

Other offline scenarios are `single`, `stalled`, `auth`, `protocol`, `pause`, `cancel` and `quota`. Each uses the production adapters and subprocess supervisor with explicitly injected fixture executables. The DSH fixture uses a dummy value supplied in memory. The executables implement finite, documented behavior and make no network calls. The sample site's preview accepts loopback connections only.

The live command runs one model attempt on a synthetic “pending” → “verified” file. It uses provider discovery, the configured account and an independently executed exact-line check. Optional live modes require a configured connection and may consume the account's quota. CI executes offline fixtures.

```sh
scripts/smoke.sh --live codex
scripts/smoke.sh --live antigravity
scripts/smoke.sh --live dsh
```

For the two-provider acceptance, run `scripts/smoke.sh --live-team`. This separately opt-in mode requires the official Codex and Antigravity subscription connections. It allows one Codex planning attempt and two independent worker attempts in a new repository, disables DSH, fallback, repair and retry, and checks both output files against the same final commit. While the workers run, the harness records an overlap only after the supervisor verifies each worker’s persisted identity against the live process. No account tokens or private files are copied into the repository.

## Real CLI observations

Observed on Apple Silicon, macOS 26.6.2 (25G83), on 26 November 2026 Singapore time. The implementation was running from the working tree before its first project commit. The commit IDs below refer to the synthetic repositories. Production CLI tokens measure what the CLI reported; subscription balance, request price, and account-wide usage were unavailable from these responses.

| Tool and route | Observation |
|---|---|
| Codex 0.170.0, ChatGPT login, direct CLI | `codex exec --ignore-user-config --ephemeral --sandbox workspace-write` with the official provider and ChatGPT login enforced. API key environment variables were removed. The CLI returned 0 with seven JSONL records, including a command completion and `turn.completed`. Read-back returned exact bytes `verified\n` in the linked worktree. The original retained `pending\n` and clean Git status. It reported 52,552 input tokens (39,680 cached) and 162 output tokens. |
| Antigravity 1.5.18, official account, HubEngine | Task `7390E701-5E47-4D1D-87A7-4604D7196039` recorded one successful attempt and a session ID. The seed at `bd8b7a8fc773be0138f87d761605c354394bf08f` failed the exact-line check (exit 1). The integrated commit `e8c0cb624dea1d30caebb77c0dcfcd12492f7f2e` changed only `status.txt`, passed (exit 0), and contained the expected bytes. The original checkout stayed clean and the reopened database retained `completed`. Antigravity reported 21,334 input and 2,790 output tokens for the session. The run preceded the subsequent addition of explicit per-invocation Antigravity `--settings` overrides. |
| Antigravity 1.5.18, final scoped adapter | A second independent task exercised the final `accept-edits` and workspace-specific `--settings` configuration on the official subscription. It used one model attempt, reported 20,257 input and 2,361 output tokens, and persisted the session. Task `0CD0FA0E-ACA8-4AD5-B325-1054A55B5B7C` integrated only `status.txt` at `2b2585581c92fc5642197ef65c87ab16392375ff`. Baseline grep returned 1 and final grep returned 0. The harness initially reached the SQLite owner lock before its prior owner released it. The separate `--recheck-live` invocation opened the saved task, verified the expected bytes, Git diff and original checkout, and exited 0 without contacting a model. |
| Codex + Antigravity, real concurrent team | Task `CCD0267C-388B-45DE-8661-378E6C8E5EFA` completed with three successful sessions. Codex planned two disjoint assignments, changed only `backend.txt`, and Antigravity changed only `frontend.txt`. At 2026-11-26T15:25:11Z the supervisor matched both live worker PIDs to their persisted kernel identities. The interval between the later kernel start and earlier observed CLI completion was 18.28 s. Commit `4dc265e82cb6718ef80b6e61915f91c2580ac813` contained exactly the two requested edits. Both checks failed at baseline and passed against that same final commit. Exact bytes, clean source and reopened SQLite were independently verified. |
| DSH 0.2.0-rc.2, Agent Hub Keychain | The normal host-permissions probe found no saved Agent Hub DeepSeek key and returned `signedOut`. Live inference was skipped with zero model attempts. A restricted sandbox had previously returned an unknown credential status. |

The direct Codex run kept the raw JSONL privately in the local temporary directory `agent-hub-live-codex.DH24NHMD` (SHA-256 `c3a4e76c022f4f7fd4013df4e23319bcb9882ed0dcb8391db85ba8c6344b3b68`). The Antigravity run used temporary directory `agent-hub-smoke-5589A056-AE0E-4782-BFE8-8810BA225D8E`. The final scoped run used `agent-hub-smoke-71C923D2-E857-49F0-B6CF-36AD4F540F64`. To repeat its read-back without a model request, run `scripts/smoke.sh --recheck-live <printed-run-directory>`. Local temporary files may be reclaimed by macOS. The installed-app observations are tracked in [desktop verification](desktop-verification.md).

## Offline engine and real process observations

| Scenario | Observed result |
|---|---|
| Single worker | One attempt, baseline exit 1, final exit 0, expected file bytes, retained session identifier and clean source. |
| Gallery | The Codex planning double emitted an explicit dependency graph. Codex and Antigravity worker doubles waited for one another at a rendezvous, demonstrating overlap before they contributed `catalog.py` and `page.py`; the DSH double checked that both upstream changes were on its baseline before adding `tests/test_filter.py`. The integrated diff contained precisely those three files. The real Python suite passed all four tests. A managed loopback preview returned `Last Ferry` as the sole result for Coast page 2 (three matching entries) and rendered the empty-state text for Portraits. |
| Repair | An agent reported completion while independently executed grep failed. One repair then passed. Both failed and successful checks were retained. |
| Repeated failure | Two attempts including one repair. The second failed check led to `needs_user` and no further launches. |
| Authentication and invalid JSON | Separate runs ended in `needs_user`, with classification `authentication` or `protocolError`. Each launched once. |
| Pause and continue | An active worker wrote a partial file. The engine stopped it, persisted paused state, and launched a linked replacement attempt on resume. The replacement had to recover the partial file before it could complete. |
| Crash and restart | A separate hub process exited abruptly with code 86 after a worker wrote its partial file and started a child. The new engine recovered one interrupted attempt and awaited explicit resume. The replacement required the inherited partial bytes, the real check passed, and the prior child PID was gone. |
| Cancel | The active attempt retained its partial contents in its own worktree. The integrated branch stayed at baseline; the reopened task stayed cancelled. |
| Quota | Two offline Codex attempts returned rate-limit failures. The allowed Antigravity fixture completed after a persisted handoff. Its replacement worker required the previous provider’s partial file before making its edit. The database contained three attempts and one provider switch. |

A portable [redacted evidence index](../Examples/Evidence/2026-11-26.json) records example task IDs, checks, Git commits and run times.

The gallery site can also be run directly from the resulting task worktree with `python3 -B server.py --port 8765`. Source, role contributions and the contract are in [Examples/Gallery](../Examples/Gallery/). The harness's actual HTTP probes use the preview manager's dynamically allocated task port. The conflict and PID-reuse cases have separate Git and process tests in [the verification report](verification.md).
