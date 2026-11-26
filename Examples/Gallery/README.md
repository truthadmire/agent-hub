# Photography catalogue example

`seed/` contains the existing site. Copy it into a fresh Git repository to try a genuine model on a public, synthetic dataset. The task and API contract are in its README. The preview command accepts an allocated port and binds to loopback.

`solution/` contains the three worker contributions used by the offline fixture. HubSmoke copies these fixtures outside the managed Git repository; workers copy only the file assigned to their role. The DSH test double checks that both dependencies were integrated before writing its tests. Actual Python and Git processes validate the result.

Run `scripts/smoke.sh --fixture gallery` from a source checkout. The command prints the task ID, repository location, integrated snapshot, checks and preview command.
