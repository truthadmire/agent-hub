import Foundation
import HubProcess
@testable import HubProviders
import XCTest

final class ProviderTests: XCTestCase {
    private let sid = "02b84acf-a7f3-40fd-aae1-5288077ed126"
    private func record(_ value: [String:Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject:value)
        data.append(10)
        return data
    }

    func testCodexSnapshotsUTF8FramingAndUsage() throws {
        var parser = ProviderStreamDecoder(.codex)
        var lines = try record(["type":"thread.started","thread_id":sid])
        for text in ["你","你好","你好"] {
            lines += try record(["type":"item.completed","item":["id":"a","type":"agent_message","text":text]])
        }
        lines += try record(["type":"extra-event","extra-field":"ignored"])
        lines += try record(["type":"turn.completed","usage":["input_tokens":42,"output_tokens":6]])
        let events = lines.flatMap { parser.feed(Data([$0])) }
        XCTAssertEqual(events.filter { $0.kind == .text }.map(\.text),["你","你好"])
        XCTAssertEqual(events.first { $0.kind == .usage }?.inputTokens,42)
        XCTAssertEqual(parser.sessionID,sid)
        XCTAssertFalse(parser.succeeded)
        XCTAssertEqual(parser.finish(exitCode:0).last?.kind,.completed)
        XCTAssertTrue(parser.succeeded)
        XCTAssertEqual(parser.finish(exitCode:0),[])
    }

    func testAntigravityDeltasTerminalSnapshotAndSoftDenial() throws {
        var data = try record(["event":"init","conversation_id":sid])
        for delta in ["a","a","b"] {
            data += try record(["event":"step_update","step_update":["conversation_id":sid,"step_index":3,
                "step_type":"agent_response","state":"ACTIVE","text_delta":delta]])
        }
        data += try record(["event":"result","result":["conversation_id":sid,"response":"aab","status":"SUCCESS",
                                                      "usage":["input_tokens":123,"output_tokens":5]]])
        var parser = ProviderStreamDecoder(.antigravity)
        let events = parser.feed(data)
        XCTAssertEqual(events.filter { $0.kind == .text }.map(\.text),["a","aa","aab"])
        XCTAssertEqual(events.first { $0.kind == .usage }?.inputTokens,123)
        var denied = parser
        _ = denied.feed(Data("tool requires approval in headless mode\n".utf8),stderr:true)
        _ = denied.finish(exitCode:0)
        XCTAssertEqual(denied.failure,.permission)
        XCTAssertFalse(denied.succeeded)
        XCTAssertEqual(parser.finish(exitCode:0).last?.kind,.completed)
    }

    func testDSHCommitAndReason() throws {
        var parser = ProviderStreamDecoder(.dsh)
        var data = try record(["type":"session","sessionId":"session-" + sid])
        for step in 1...2 {
            data += try record(["type":"status","phase":"step_start","turn":1,"step":step])
            data += try record(["type":"text","text":"回答 \(step)"])
            let end = try record(["type":"status","phase":"step_end","turn":1,"step":step,"usage":["inputTokens":7,"outputTokens":2]])
            data += end + end
        }
        data += try record(["type":"status","phase":"turn_end","reason":["kind":"completed"]])
        data += try record(["type":"final","text":"回答 2"])
        let events = parser.feed(data)
        XCTAssertEqual(events.filter { $0.kind == .text }.count,2)
        XCTAssertEqual(events.first { $0.kind == .usage }?.inputTokens,14)
        XCTAssertEqual(parser.finalText,"回答 2")
        XCTAssertEqual(parser.finish(exitCode:0).last?.kind,.completed)
        var missing = ProviderStreamDecoder(.dsh)
        _ = missing.feed(try record(["type":"final","text":"looks finished"]))
        _ = missing.finish(exitCode:0)
        XCTAssertEqual(missing.failure,.protocolError)
        var failed = ProviderStreamDecoder(.dsh)
        _ = failed.feed(try record(["type":"status","phase":"step_end","turn":1,"step":1,
                                    "usage":["inputTokens":13,"outputTokens":4]]))
        _ = failed.feed(try record(["type":"status","phase":"turn_end","reason":["kind":"error"]]))
        XCTAssertEqual(failed.finish(exitCode:1).first { $0.kind == .usage }?.inputTokens,13)
    }

    func testProtocolExitAndCredentialRedaction() throws {
        var malformed = ProviderStreamDecoder(.codex,maxLineBytes:128)
        _ = malformed.feed(Data(repeating:120,count:5000))
        _ = malformed.feed(Data([10]))
        _ = malformed.feed(try record(["type":"turn.completed"]))
        _ = malformed.finish(exitCode:0)
        XCTAssertEqual(malformed.failure,.protocolError)
        for data in [Data("{bad}\n".utf8),Data([0xff,10]),Data("{\"extra\":1}\n".utf8)] {
            var parser = ProviderStreamDecoder(.codex)
            _ = parser.feed(data)
            _ = parser.finish(exitCode:0)
            XCTAssertEqual(parser.failure,.protocolError)
        }
        var parser = ProviderStreamDecoder(.codex,sensitiveValues:["probe_value"])
        _ = parser.feed(try record(["type":"turn.completed"]))
        let diagnostic = parser.feed(Data("\u{1b}[31mHTTP 401 invalid API key probe_value\u{1b}[0m".utf8),stderr:true)
        let events = diagnostic + parser.finish(exitCode:9)
        XCTAssertEqual(parser.failure,.authentication)
        XCTAssertTrue(events.allSatisfy { !$0.text.contains("probe_value") && !$0.text.contains("\u{1b}") })
        var unfinished = ProviderStreamDecoder(.codex)
        _ = unfinished.finish(exitCode:0)
        XCTAssertEqual(unfinished.failure,.protocolError)
    }

    func testUnexpectedSessionAndStructuredErrors() throws {
        var p = ProviderStreamDecoder(.antigravity)
        _ = p.feed(try record(["event":"init","conversation_id":"one"]))
        _ = p.feed(try record(["event":"result","result":["status":"SUCCESS","response":"ok","conversation_id":"two"]]))
        _ = p.finish(exitCode:0)
        XCTAssertEqual(p.failure,.protocolError)
        for (reason,kind) in [("quota exceeded",ProviderFailureKind.quota),("network unavailable",.network),
                              ("permission denied",.permission),("unknown option",.incompatible)] {
            var failed = ProviderStreamDecoder(.dsh)
            _ = failed.feed(try record(["type":"error","message":reason]))
            _ = failed.finish(exitCode:1)
            XCTAssertEqual(failed.failure,kind)
        }
    }

    func testInvocationAndCleanEnvironment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-工作 \(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let prompt = "line one\n'$HOME' \"工作\""
        for id in ProviderID.allCases {
            let adapter = ProviderAdapter(id,stateDirectory:root,deepSeekKey:{ "sentinel" })
            let command = try adapter.command(executable:URL(fileURLWithPath:"/usr/bin/true"),workspace:root,
                                              prompt:prompt,sessionID:id == .dsh ? "session-" + sid : sid,readOnly:true)
            XCTAssertFalse(command.arguments.contains(prompt))
            XCTAssertFalse(command.description.contains("sentinel"))
            XCTAssertEqual(command.workingDirectory,root)
            if id == .antigravity {
                let object = try XCTUnwrap(try JSONSerialization.jsonObject(with:command.stdin) as? [String:Any])
                XCTAssertEqual((object["message"] as? [String:String])?["content"],prompt)
                let settingsIndex = try XCTUnwrap(command.arguments.firstIndex(of:"--settings"))
                let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(command.arguments[settingsIndex + 1].utf8)) as? [String:Any])
                let denied = (settings["permissions"] as? [String:Any])?["deny"] as? [String]
                XCTAssertTrue(denied?.contains("write_file(*)") == true)
                XCTAssertTrue(denied?.contains("command(*)") == true)
                XCTAssertEqual(settings["trustedWorkspaces"] as? [String],[root.path])
            } else { XCTAssertEqual(String(decoding:command.stdin,as:UTF8.self),prompt) }
            XCTAssertTrue(command.arguments.contains(id == .dsh ? "session-" + sid : sid))
            XCTAssertEqual(command.environment["DEEPSEEK_API_KEY"] != nil,id == .dsh)
            XCTAssertNil(command.environment["OPENAI_API_KEY"])
            if id == .dsh {
                XCTAssertTrue(command.environment["DSH_HOME"]?.hasPrefix(root.path) == true)
                let policy = try String(contentsOfFile:command.arguments[3],encoding:.utf8)
                XCTAssertFalse(policy.contains("sentinel"))
                XCTAssertTrue(policy.contains("read-only"))
            }
            XCTAssertThrowsError(try adapter.command(executable:command.executable,workspace:root,prompt:prompt,sessionID:"--last"))
        }
        XCTAssertThrowsError(try ProviderAdapter(.dsh,stateDirectory:root,deepSeekKey:{nil}).command(
            executable:URL(fileURLWithPath:"/usr/bin/true"),workspace:root,prompt:"test"))
    }

    func testFinderManualSelectionAndDetectionWithoutModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("finder 安装 \(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let cli = root.appendingPathComponent("fixture codex")
        try """
        #!/bin/sh
        case "$1 $2" in
            "--version ") echo 'codex-cli 0.170.0' ;;
            "exec --help") echo '--json --sandbox --ignore-user-config resume' ;;
            "login status") echo 'Logged in using ChatGPT' >&2 ;;
            *) exit 19 ;;
        esac
        """.write(to:cli,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        let connection = await ProviderDiscovery.detect(.codex,override:cli)
        XCTAssertEqual(connection.executable,cli)
        XCTAssertEqual(connection.version,"0.170.0")
        XCTAssertEqual(connection.auth,.subscription)
        XCTAssertTrue(connection.configured,connection.detail)
        XCTAssertNil(ProviderDiscovery.executable(.codex,override:root))
        XCTAssertNil(ProviderDiscovery.executable(.codex,override:root.appendingPathComponent("missing")))
    }

    /// Opt-in no-inference probe for the installed release. An unknown session fails before a model call.
    func testInstalledDSHProfileCanBoot() async throws {
        guard ProcessInfo.processInfo.environment["AGENTHUB_PROBE_DSH"] == "1",
              let executable = ProviderDiscovery.executable(.dsh) else { throw XCTSkip("opt-in installed DSH profile check") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenthub-dsh-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let adapter = ProviderAdapter(.dsh,stateDirectory:root,deepSeekKey:{ "sentinel" })
        let request = try adapter.command(executable:executable,workspace:root,prompt:"synthetic test",
                                          sessionID:"session-" + UUID().uuidString)
        let result = try await ProcessRunner.run(ProcessRequest(executable:executable,arguments:request.arguments,
                          workingDirectory:root,environment:request.environment,stdin:request.stdin,timeout:12))
        XCTAssertEqual(result.exitCode,1)
        let events = String(decoding:result.stdout,as:UTF8.self)
        XCTAssertTrue(events.contains("does not exist"),String(decoding:result.stderr,as:UTF8.self).prefix(900).description)
        XCTAssertFalse(events.contains("sentinel"))
    }

    /// The official stream protocol rejects control requests locally, before any user turn.
    func testInstalledAntigravityAcceptsScopedSettings() async throws {
        guard ProcessInfo.processInfo.environment["AGENTHUB_PROBE_AGY"] == "1",
              let cli = ProviderDiscovery.executable(.antigravity) else { throw XCTSkip("opt-in installed agy protocol check") }
        let fs = FileManager.default
        let root = fs.temporaryDirectory.appendingPathComponent("agenthub-agy-\(UUID())")
        try fs.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fs.removeItem(at:root) }
        for readOnly in [true,false] {
            let cmd = try ProviderAdapter(.antigravity).command(executable:cli,workspace:root,prompt:"unused",readOnly:readOnly)
            let data = Data("{\"event\":\"control_request\"}\n".utf8)
            let run = try await ProcessRunner.run(ProcessRequest(executable:cli,arguments:cmd.arguments,workingDirectory:root,
                                                   environment:cmd.environment,stdin:data,timeout:20))
            XCTAssertEqual(run.exitCode,2)
            var parser = ProviderStreamDecoder(.antigravity)
            let events = parser.feed(run.stdout) + parser.finish(exitCode:run.exitCode ?? -1)
            XCTAssertEqual(parser.failure,.execution)
            XCTAssertTrue(events.contains { $0.text.lowercased().contains("control_request") })
        }
    }

    func testLaunchedToolCredentialSentinel() async throws {
        var source = ProcessEnvironment.clean()
        source["DEEPSEEK_API_KEY"] = "synthetic-sentinel"
        let result = try await ProcessRunner.run(ProcessRequest(executable:URL(fileURLWithPath:"/bin/sh"),
            arguments:["-c","test -z \"${DEEPSEEK_API_KEY+x}\""], workingDirectory:FileManager.default.temporaryDirectory,
            environment:ProcessEnvironment.clean(inheriting:source)))
        XCTAssertEqual(result.exitCode,0,"Hub-launched shell inherited a provider credential")
    }

    func testInstalledDSHSandboxedBashCredentialSentinel() async throws {
        guard ProcessInfo.processInfo.environment["AGENTHUB_PROBE_DSH"] == "1",
              let cli = ProviderDiscovery.executable(.dsh),
              let node = ProcessEnvironment.resolve("node") else { throw XCTSkip("opt-in installed DSH Bash tool check") }
        let package = cli.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let modules = package.appendingPathComponent("node_modules/@deepseek-ai")
        let script = #"""
        import { pathToFileURL } from 'node:url';
        import { join } from 'node:path';
        const packages = process.argv[2], cwd = process.argv[3];
        const load = (id) => import(pathToFileURL(join(packages,id,'lib','index.js')).href);
        const { Context } = await load('cordis');
        const ctx = new Context();
        try {
            for (const id of ['dsh-subprocess-local','dsh-sandbox-local','dsh-session-projection']) {
                await ctx.plugin((await load(id)).default);
            }
            await ctx.plugin((await load('dsh-sandbox-policy')).default,{mode:'read-only',workspaceRoot:cwd});
            await ctx.plugin((await load('dsh-bash-sandbox')).default);
            const shell = ctx.shell.resolve({workdir:cwd,command:'if /usr/bin/printenv DEEPSEEK_API_KEY >/dev/null; then exit 23; else exit 0; fi'});
            const handle = await ctx.shell.execute(shell);
            const result = await handle.result();
            if (![0,23].includes(result.exitCode)) throw Error('child probe did not complete');
            console.log(JSON.stringify({dshBashToolKeyPresent:result.exitCode===23}));
        } finally { await ctx.fiber.dispose(); }
        """#
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-shell-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        var env = ProcessEnvironment.clean()
        env["DEEPSEEK_API_KEY"] = "synthetic-sentinel"
        let result = try await ProcessRunner.run(ProcessRequest(executable:node,arguments:["--input-type=module","-",modules.path,root.path],
                                      workingDirectory:root,environment:env,stdin:Data(script.utf8),timeout:12))
        XCTAssertEqual(result.exitCode,0,String(decoding:result.stderr,as:UTF8.self))
        let observed = try JSONSerialization.jsonObject(with:result.stdout) as? [String:Bool]
        XCTAssertEqual(observed?["dshBashToolKeyPresent"],false)
    }
}
