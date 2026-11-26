import Darwin
import Foundation
import XCTest
@testable import HubProcess

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func change(_ update: (inout Value) -> Void) { lock.withLock { update(&value) } }
    func get() -> Value { lock.withLock { value } }
}

final class ProcessRunnerTests: XCTestCase {
    private let temporary = FileManager.default.temporaryDirectory
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func directory() throws -> URL {
        let result = temporary.appendingPathComponent("Hub 中文 fixture " + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    func testArgvCwdControlledEnvironmentAndFastExit() async throws {
        let cwd = try directory()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let value = "literal ; $(touch injected) ' 中文"
        let source = ["HUB_TEST_SECRET": "sentinel", "DEEPSEEK_API_KEY": "sentinel",
                      "DYLD_INSERT_LIBRARIES": "untrusted", "PATH": ":.:/bin"]
        let env = ProcessEnvironment.clean(inheriting: source)
        XCTAssertNil(env["DEEPSEEK_API_KEY"])
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(ProcessEnvironment.resolve("sh", environment: env)?.path, "/bin/sh")
        XCTAssertNil(ProcessEnvironment.resolve("bin/sh", environment: env))
        let script = #"printf '%s' "$1"; test -z "${HUB_TEST_SECRET+x}" && : > here"#
        let request = ProcessRequest(executable: shell, arguments: ["-c", script, "fixture", value],
                                     workingDirectory: cwd, environment: env)
        let result = try await ProcessRunner.run(request)
        XCTAssertEqual(result.stdout, Data(value.utf8))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.outputDrainIncomplete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("here").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("injected").path))
    }

    func testKernelIdentityWhileSuspendedAndPIDReuseMismatch() async throws {
        let result = try await ProcessRunner.run(ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectory: temporary)) { identity in
            XCTAssertEqual(ProcessRunner.inspect(identity), .matching)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any])
            json["startSeconds"] = identity.startSeconds - 1
            let old = try JSONDecoder().decode(ProcessIdentity.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(ProcessRunner.inspect(old), .gone)
            json["startSeconds"] = identity.startSeconds
            json["kernelExecutablePath"] = "/unverified-image"
            let changed = try JSONDecoder().decode(ProcessIdentity.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(ProcessRunner.inspect(changed), .unverified)
            XCTAssertEqual(ProcessRunner.inspect(identity), .matching)
        } onOutput: { _, _ in }
        XCTAssertEqual(ProcessRunner.inspect(result.identity), .gone)
    }

    func testLaunchFailureAndJournalRefusalPreventWorkerCode() async throws {
        let cwd = try directory()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let missing = cwd.appendingPathComponent("missing executable")
        do {
            _ = try await ProcessRunner.run(ProcessRequest(executable: missing, workingDirectory: cwd))
            XCTFail("Expected launch error")
        } catch ProcessRunError.system(_, let code) { XCTAssertEqual(code, ENOENT) }
        enum JournalFailure: Error { case unavailable }
        do {
            let request = ProcessRequest(executable: shell, arguments: ["-c", "touch ran"], workingDirectory: cwd)
            _ = try await ProcessRunner.run(request, onStart: { _ in throw JournalFailure.unavailable })
            XCTFail("Expected journal error")
        } catch JournalFailure.unavailable {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("ran").path))
    }

    func testFullDuplexInputLargeStderrAndBoundedTails() async throws {
        // Write more than the stderr pipe capacity before reading much larger stdin.
        let fixture = "dd if=/dev/zero bs=65536 count=16 >&2 2>/dev/null; cat; printf 'end' >&2; exit 17"
        let input = Data(repeating: 0x78, count: 900_000) + Data("tail".utf8)
        let chunks = Locked([ProcessStream: Int]())
        let request = ProcessRequest(executable: shell, arguments: ["-c", fixture], workingDirectory: temporary,
                                     stdin: input, timeout: 5, captureLimit: 1024)
        let result = try await ProcessRunner.run(request, onOutput: { stream, chunk in
            chunks.change { $0[stream, default: 0] += chunk.count }
        })
        XCTAssertEqual(result.exitCode, 17)
        XCTAssertEqual(result.stdoutByteCount, UInt64(input.count))
        XCTAssertEqual(result.stderrByteCount, 1_048_579)
        XCTAssertEqual(chunks.get()[.stderr], 1_048_579)
        XCTAssertEqual(chunks.get()[.stdout], input.count)
        XCTAssertEqual(result.stdout, input.suffix(1024))
        XCTAssertEqual(result.stderr.suffix(3), Data("end".utf8))
        XCTAssertTrue(result.stdoutTruncated && result.stderrTruncated)
        XCTAssertFalse(result.outputDrainIncomplete)
    }

    func testCrashAndEarlyStdinClosureDoNotCrashHost() async throws {
        let result = try await ProcessRunner.run(ProcessRequest(executable: shell,
            arguments: ["-c", "exec 0<&-; printf last; kill -KILL $$"], workingDirectory: temporary,
            stdin: Data(repeating: 65, count: 800_000)))
        XCTAssertNil(result.exitCode)
        XCTAssertEqual(result.terminationSignal, SIGKILL)
        XCTAssertEqual(result.stdout, Data("last".utf8))
    }

    func testTimeoutEscalatesIgnoringGroupAndCleansDescendants() async throws {
        let cwd = try directory()
        defer { try? FileManager.default.removeItem(at: cwd) }
        // Both the shell and child ignore TERM. A surviving child would write 'late'.
        let script = "trap '' TERM; (sleep 0.7; touch late) & printf ready; wait"
        let result = try await ProcessRunner.run(ProcessRequest(executable: shell, arguments: ["-c", script],
            workingDirectory: cwd, timeout: 0.15, terminationGrace: 0.08))
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.terminationSignal, SIGKILL)
        XCTAssertEqual(result.stdout, Data("ready".utf8))
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("late").path))
    }

    func testCancellationAllowsTERMTrapToFlushFinalOutput() async throws {
        let ready = expectation(description: "Worker installed its TERM handler")
        let request = ProcessRequest(executable: shell,
            arguments: ["-c", #"trap 'printf stopped; exit 7' TERM; printf ready; while :; do sleep 1; done"#],
            workingDirectory: temporary, timeout: 5, terminationGrace: 1)
        let run = Task {
            try await ProcessRunner.run(request, onOutput: { stream, bytes in
                if stream == .stdout, String(decoding: bytes, as: UTF8.self).contains("ready") { ready.fulfill() }
            })
        }
        await fulfillment(of: [ready], timeout: 3)
        run.cancel()
        let result = try await run.value
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout, Data("readystopped".utf8))
    }

    func testCancellationInStartJournalNeverExecutesUserCode() async throws {
        let cwd = try directory()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let journalStarted = expectation(description: "Worker is suspended")
        let releaseJournal = DispatchSemaphore(value: 0)
        let request = ProcessRequest(executable: shell, arguments: ["-c", "touch ran"], workingDirectory: cwd)
        let run = Task {
            try await ProcessRunner.run(request, onStart: { _ in
                journalStarted.fulfill()
                _ = releaseJournal.wait(timeout: .now() + 2)
            })
        }
        await fulfillment(of: [journalStarted], timeout: 2)
        run.cancel()
        releaseJournal.signal()
        let result = try await run.value
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("ran").path))
    }

    func testCancellingOneConcurrentGroupLeavesTheOtherRunning() async throws {
        let cwd = try directory()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let firstReady = expectation(description: "First group is running")
        let secondReady = expectation(description: "Second group is running")
        let first = ProcessRequest(executable: shell, arguments: ["-c", "printf ready; sleep 4"],
                                   workingDirectory: temporary, timeout: 5)
        let waitForFile = "printf ready; while [ ! -f release ]; do sleep 0.02; done; printf done"
        let second = ProcessRequest(executable: shell, arguments: ["-c", waitForFile],
                                    workingDirectory: cwd, timeout: 5)
        let firstRun = Task { try await ProcessRunner.run(first, onOutput: { _, bytes in
            if bytes == Data("ready".utf8) { firstReady.fulfill() }
        }) }
        let secondRun = Task { try await ProcessRunner.run(second, onOutput: { _, bytes in
            if bytes == Data("ready".utf8) { secondReady.fulfill() }
        }) }
        await fulfillment(of: [firstReady, secondReady], timeout: 3)
        firstRun.cancel()
        let cancelled = try await firstRun.value
        try Data().write(to: cwd.appendingPathComponent("release"))
        let completed = try await secondRun.value
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertNotEqual(cancelled.identity.processGroup, completed.identity.processGroup)
        XCTAssertEqual(completed.stdout, Data("readydone".utf8))
        XCTAssertEqual(completed.exitCode, 0)
    }

    func testStartBudgetIncludesJournalBeforeExecution() async throws {
        let cwd = try directory()
        defer { try? FileManager.default.removeItem(at: cwd) }
        do {
            let request = ProcessRequest(executable: shell, arguments: ["-c", "touch ran"],
                                         workingDirectory: cwd, startupTimeout: 0.08)
            _ = try await ProcessRunner.run(request, onStart: { _ in Thread.sleep(forTimeInterval: 0.12) })
            XCTFail("Expected startup budget to expire")
        } catch ProcessRunError.startupTimedOut {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("ran").path))
    }

    func testTimeoutReapsDirectChildThatCreatesNewSession() async throws {
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        let script = #"setsid() >= 0 or die; $SIG{TERM} = 'IGNORE'; $|=1; print 'detached'; sleep 3;"#
        let request = ProcessRequest(executable: perl, arguments: ["-MPOSIX=setsid", "-e", script],
                                     workingDirectory: temporary, timeout: 0.3, terminationGrace: 0.05)
        let result = try await ProcessRunner.run(request)
        XCTAssertEqual(result.stdout, Data("detached".utf8))
        XCTAssertEqual(result.terminationSignal, SIGKILL)
        XCTAssertTrue(result.timedOut)
    }

    func testDetachedWriterReportsIncompleteDrainWithBoundedWait() async throws {
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        let script = #"""
        pipe(my $reader, my $writer) or die;
        my $pid = fork(); defined($pid) or die;
        if ($pid == 0) {
            close $reader; setsid() >= 0 or die;
            syswrite($writer, 'R'); close $writer;
            select(undef, undef, undef, 2.6); exit 0;
        }
        close $writer; sysread($reader, my $ready, 1); print 'finished';
        """#
        let request = ProcessRequest(executable: perl, arguments: ["-MPOSIX=setsid", "-e", script],
                                     workingDirectory: temporary, timeout: 5)
        let result = try await ProcessRunner.run(request)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, Data("finished".utf8))
        XCTAssertTrue(result.outputDrainIncomplete)
    }

    func testIdleWarningPreservesQuietWork() async throws {
        let warnings = Locked([Double]())
        let request = ProcessRequest(executable: shell, arguments: ["-c", "sleep 0.15; printf awake"],
            workingDirectory: temporary, timeout: 3, inactivityWarningAfter: 0.04)
        let result = try await ProcessRunner.run(request, onInactivity: { seconds in warnings.change { $0.append(seconds) } })
        XCTAssertEqual(warnings.get().count, 1)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testRootExitReapsGroupMembersHoldingBothPipes() async throws {
        let cwd = try directory()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let script = "(sleep 0.7; touch leaked) & printf out; printf err >&2"
        let result = try await ProcessRunner.run(ProcessRequest(executable: shell, arguments: ["-c", script],
            workingDirectory: cwd, timeout: 5))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, Data("out".utf8))
        XCTAssertEqual(result.stderr, Data("err".utf8))
        XCTAssertFalse(result.outputDrainIncomplete)
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("leaked").path))
    }

    // Launched by the next test in a distinct XCTest process. _exit bypasses
    // deinit and defer, accurately closing only the dead app's kernel-owned fds.
    func testAbruptParentFixture() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["HUB_EXPLICIT_CRASH_FIXTURE"] else { return }
        let cwd = URL(fileURLWithPath: fixture)
        let script = "(sleep 1; touch orphan-wrote) & printf 'ready'; wait"
        _ = try await ProcessRunner.run(ProcessRequest(executable: shell, arguments: ["-c", script],
            workingDirectory: cwd), onStart: { identity in
                try JSONEncoder().encode(identity).write(to: cwd.appendingPathComponent("identity"))
            }, onOutput: { stream, _ in
                if stream == .stdout { Darwin._exit(42) }
            })
        XCTFail("The subprocess fixture should have exited abruptly")
    }

    func testAbruptParentDeathClosesLifelineAndStopsOrphanWriters() async throws {
        let cwd = try directory()
        defer { try? FileManager.default.removeItem(at: cwd) }
        let bundle = Bundle(for: Self.self).bundleURL
        var env = ProcessEnvironment.clean()
        env["HUB_EXPLICIT_CRASH_FIXTURE"] = cwd.path
        let arguments = ["xctest", "-XCTest", "HubProcessTests.ProcessRunnerTests/testAbruptParentFixture", bundle.path]
        let result = try await ProcessRunner.run(ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: arguments, workingDirectory: cwd, environment: env, timeout: 10))
        XCTAssertEqual(result.exitCode, 42, String(decoding: result.stderr + result.stdout, as: UTF8.self))
        let data = try Data(contentsOf: cwd.appendingPathComponent("identity"))
        let recorded = try JSONDecoder().decode(ProcessIdentity.self, from: data)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(ProcessRunner.inspect(recorded), .gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("orphan-wrote").path))
    }
}
