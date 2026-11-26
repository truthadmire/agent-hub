import Foundation
import HubProviders

/// The export is built from a small allowlist. Provider messages, arguments, project names,
/// environment dictionaries, user text and raw diagnostics never enter the exported object.
public enum TaskDiagnostics {
    public static func data(for task: HubTask, recentEvents: [HubEvent], appVersion: String,
                            versions: [ProviderID: String]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        let knownRoles: Set<String> = ["lead", "frontend", "backend", "test", "review"]
        let failures: Set<String> = ["authentication", "permission", "rateLimit", "rate_limit", "network",
            "execution", "protocolError", "protocol_error", "cancelled", "interrupted", "switch", "timeout"]
        let publicTools: Set<String> = ["git", "swift", "swiftc", "xcodebuild", "cargo", "node", "npm", "pnpm",
            "yarn", "python", "python3", "pytest", "grep", "make", "go", "env"]
        func version(_ text: String) -> String {
            text.range(of: #"^\d{1,4}(\.\d{1,4}){1,3}(-[a-zA-Z]{1,8}\.\d{1,4})?$"#,
                       options: .regularExpression) != nil ? text : "unknown"
        }
        func snapshot(_ value: String) -> String {
            value.range(of: #"^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$"#, options: .regularExpression) != nil
                ? String(value.prefix(12)) : "unknown"
        }
        let attempts: [[String: Any]] = task.attempts.suffix(40).map { attempt in
            var item: [String: Any] = [
                "role": knownRoles.contains(attempt.role) ? attempt.role : "custom",
                "provider": attempt.provider.rawValue, "state": attempt.state.rawValue,
                "requirementRevision": attempt.requirementRevision, "planRevision": attempt.planRevision,
                "startedAt": formatter.string(from: attempt.startedAt)
            ]
            if let end = attempt.endedAt { item["endedAt"] = formatter.string(from: end) }
            if let failure = attempt.failureKind { item["failureCategory"] = failures.contains(failure) ? failure : "other" }
            return item
        }
        let checks: [[String: Any]] = task.verifications.suffix(40).map { check in
            let name = check.command.first.map { URL(fileURLWithPath: $0).lastPathComponent }
            var item: [String: Any] = [
                "required": check.required, "state": check.state.rawValue,
                "requirementRevision": check.requirementRevision,
                "snapshot": snapshot(check.snapshot), "startedAt": formatter.string(from: check.startedAt)
            ]
            if let name { item["tool"] = publicTools.contains(name) ? name : "project-command" }
            if let exitCode = check.exitCode { item["exitCode"] = Int(exitCode) }
            if let end = check.endedAt { item["endedAt"] = formatter.string(from: end) }
            return item
        }
        let categories: Set<String> = ["task", "requirements", "plan", "attempt", "workspace", "provider",
            "verification", "repair", "queue", "message", "handoff", "decision", "result", "preview"]
        let timeline: [[String: Any]] = recentEvents.suffix(80).map { event in
            let category = event.kind.split(separator: ".").first.map(String.init) ?? "event"
            return ["sequence": event.sequence, "category": categories.contains(category) ? category : "event",
                    "at": formatter.string(from: event.createdAt), "generation": event.generation,
                    "requirementRevision": event.requirementRevision]
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let object: [String: Any] = [
            "schemaVersion": 1, "appVersion": version(appVersion),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": architecture,
            "exportedAt": formatter.string(from: Date()),
            "providers": Dictionary(uniqueKeysWithValues: versions.map { ($0.key.rawValue, version($0.value)) }),
            "taskID": UUID(uuidString: task.id)?.uuidString ?? "local",
            "state": task.state.rawValue, "phase": task.phase.rawValue,
            "requirementRevision": task.requirementRevision, "planRevision": task.planRevision,
            "attemptCount": task.attempts.count, "repairs": task.repairCount, "retries": task.retryCount,
            "attempts": attempts, "checks": checks, "timeline": timeline
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
