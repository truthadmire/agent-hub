import Foundation
import CSQLite
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum HubStoreError: LocalizedError {
    case occupied, missing(String), invalid(String), database(String), incompatible(Int64)
    public var errorDescription: String? {
        switch self {
        case .occupied: return "另一个 Agent Hub 实例正在使用此数据目录。请先退出该实例。"
        case .missing(let object): return "未找到记录（\(object)）。"
        case .invalid(let reason): return reason
        case .database(let reason): return "本地数据库操作失败：\(reason)"
        case .incompatible(let version): return "数据版本 \(version) 高于当前应用支持的版本。请使用较新的 Agent Hub 打开。"
        }
    }
}

/// Removes common credential formats before bytes cross the persistence boundary.
public enum HubRedaction {
    private static let rules: [(NSRegularExpression, String)] = [
        (#"-----BEGIN [^\r\n]*PRIVATE KEY-----[\s\S]*?(?:-----END [^\r\n]*PRIVATE KEY-----|\z)"#, "[REDACTED PRIVATE KEY]"),
        (#"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9_+=/.~-]{4,}"#, "$1 [REDACTED]"),
        (#"(?i)([\"']?(?:[a-z0-9_]*api[_-]?key|[a-z0-9_]*access[_-]?token|[a-z0-9_]*refresh[_-]?token|authorization|token|password|passwd|secret|client_secret|cookie|set-cookie)[\"']?\s*[:=]\s*)(?:\"(?:[^\"\\]|\\.)*\"|'[^']*'|[^\s,;&}\]]+)"#, "$1[REDACTED]"),
        (#"(?i)(?:\bsk-[a-z0-9_-]{8,}|\bgh[pousr]_[A-Za-z0-9_]{12,}|\bgithub_pat_[a-z0-9_]{12,}|\bAIza[0-9A-Za-z_-]{20,}|\bxox[baprs]-[a-z0-9-]{10,}|\beyJ[a-zA-Z0-9_-]{6,}\.eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+)"#, "[REDACTED]"),
        (#"(?i)(https?://)[^/\s@]+:[^/\s@]+@"#, "$1[REDACTED]@")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func text(_ text: String) -> String {
        rules.reduce(text) { current, rule in
            rule.0.stringByReplacingMatches(in: current, range: NSRange(current.startIndex..., in: current),
                                            withTemplate: rule.1)
        }
    }
}

/// One serialized SQLite connection. Use a single owner for dispatch-capable application instances.
/// A change and its audit event commit together; errors leave both untouched.
public final class HubStore: @unchecked Sendable {
    private enum Value { case text(String), integer(Int64), real(Double), blob(Data), null }
    private let db: OpaquePointer
    private let ownerFD: Int32
    private let lock = NSRecursiveLock()
    private var inTransaction = false
    public var changeCounter: Int64 { synchronized { sqlite3_total_changes64(db) } }
    public let directory: URL
    private static let schemaVersion: Int64 = 3
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL, exclusiveOwner: Bool = true) throws {
        self.directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let owner = exclusiveOwner ? open(directory.appendingPathComponent("owner.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600) : -1
        if exclusiveOwner {
            guard owner >= 0 else { throw HubStoreError.database(String(cString: strerror(errno))) }
            guard flock(owner, LOCK_EX | LOCK_NB) == 0 else {
                let reason = errno
                close(owner)
                if reason == EWOULDBLOCK { throw HubStoreError.occupied }
                throw HubStoreError.database(String(cString: strerror(reason)))
            }
        }
        self.ownerFD = owner
        let file = directory.appendingPathComponent("agent-hub.sqlite3")
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let handle { sqlite3_close(handle) }
            if owner >= 0 { close(owner) }
            throw HubStoreError.database(reason)
        }
        self.db = handle
        sqlite3_busy_timeout(handle, 4000)
        try executeSQL("PRAGMA foreign_keys=ON")
        let version = try query("PRAGMA user_version") { sqlite3_column_int64($0, 0) }.first ?? 0
        guard version <= Self.schemaVersion else { throw HubStoreError.incompatible(version) }
        try executeSQL("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL")
        if version > 0 && version < Self.schemaVersion { try backup() }
        try migrate(from: version)
    }

    deinit {
        sqlite3_close(db)
        if ownerFD >= 0 { close(ownerFD) }
    }

    private func backup() throws {
        let file = directory.appendingPathComponent("before-v\(Self.schemaVersion)-\(UUID().uuidString).sqlite3")
        var output: OpaquePointer?
        let result = sqlite3_open_v2(file.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        defer { if let output { sqlite3_close(output) } }
        guard result == SQLITE_OK, let output,
              let copy = sqlite3_backup_init(output, "main", db, "main") else {
            throw HubStoreError.database("无法备份旧版本数据库。")
        }
        let status = sqlite3_backup_step(copy, -1)
        let finish = sqlite3_backup_finish(copy)
        guard status == SQLITE_DONE && finish == SQLITE_OK else {
            throw HubStoreError.database("升级前备份失败。可检查数据目录的可用空间。")
        }
    }

    private func migrate(from version: Int64) throws {
        guard version < Self.schemaVersion else { return }
        try transaction {
            if version < 1 {
                try executeSQL("""
                CREATE TABLE projects (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, payload BLOB NOT NULL);
                CREATE TABLE tasks (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id),
                  priority INTEGER NOT NULL, updated REAL NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX tasks_board ON tasks(project_id,priority DESC,updated DESC);
                CREATE TABLE config (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE requests (id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id), operation TEXT NOT NULL);
                CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                  task_id TEXT NOT NULL REFERENCES tasks(id), attempt_id TEXT, requirement INTEGER NOT NULL,
                  plan INTEGER NOT NULL, generation INTEGER NOT NULL, time REAL NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL);
                CREATE INDEX events_task ON events(task_id,seq);
                CREATE INDEX events_attempt ON events(task_id,attempt_id,seq);
                CREATE TABLE drafts (task_id TEXT NOT NULL REFERENCES tasks(id), recipient TEXT NOT NULL, text TEXT NOT NULL,
                  PRIMARY KEY(task_id,recipient));
                CREATE TABLE messages (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                  task_id TEXT NOT NULL REFERENCES tasks(id), sender TEXT NOT NULL, recipient TEXT NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX messages_recipient ON messages(task_id,recipient,seq);
                CREATE INDEX messages_sender ON messages(task_id,sender,seq);
                CREATE INDEX messages_task ON messages(task_id,seq);
                PRAGMA user_version=1;
                """)
            }
            if version < 2 {
                try executeSQL("""
                CREATE INDEX tasks_change ON tasks(id,updated);
                CREATE TABLE event_counters (task_id TEXT PRIMARY KEY REFERENCES tasks(id), seen INTEGER NOT NULL);
                INSERT INTO event_counters SELECT task_id, COUNT(*) FROM events GROUP BY task_id;
                CREATE TABLE requirements (task_id TEXT NOT NULL REFERENCES tasks(id), revision INTEGER NOT NULL, goal TEXT NOT NULL,
                  acceptance BLOB NOT NULL, PRIMARY KEY(task_id,revision));
                CREATE TABLE plans (task_id TEXT NOT NULL REFERENCES tasks(id), revision INTEGER NOT NULL, payload BLOB NOT NULL,
                  PRIMARY KEY(task_id,revision));
                PRAGMA user_version=2;
                """)
                if version > 0 {
                    for task in try tasks() { try saveRevisions(task, previous: nil) }
                }
            }
            if version < 3 {
                try executeSQL("""
                ALTER TABLE events ADD COLUMN provider_type TEXT;
                CREATE TABLE final_streams (
                    task_id TEXT NOT NULL REFERENCES tasks(id), attempt_id TEXT NOT NULL,
                    stream_id TEXT NOT NULL, message_id TEXT NOT NULL REFERENCES messages(id),
                    PRIMARY KEY(task_id,attempt_id,stream_id)
                );
                PRAGMA user_version=3;
                """)
                if version > 0 { try backfillFinalStreams() }
            }
        }
    }

    private func synchronized<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }

    private func transaction<T>(_ work: () throws -> T) throws -> T {
        try synchronized {
            guard !inTransaction else { throw HubStoreError.invalid("不能嵌套写事务。") }
            try executeSQL("BEGIN IMMEDIATE")
            inTransaction = true
            defer { inTransaction = false }
            do {
                let value = try work()
                try executeSQL("COMMIT")
                return value
            } catch {
                try? executeSQL("ROLLBACK")
                throw error
            }
        }
    }

    private func failure() -> HubStoreError {
        HubStoreError.database(String(cString: sqlite3_errmsg(db)))
    }

    private func executeSQL(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func query<T>(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let statement = pointer else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let value):
                status = sqlite3_bind_text(statement, index, value, Int32(value.utf8.count), Self.transient)
            case .integer(let value): status = sqlite3_bind_int64(statement, index, value)
            case .real(let value): status = sqlite3_bind_double(statement, index, value)
            case .blob(let value):
                status = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        var results: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return results
            case SQLITE_ROW: results.append(try row(statement))
            default: throw failure()
            }
        }
    }

    private func write(_ sql: String, _ values: [Value]) throws {
        _ = try query(sql, values) { _ in () }
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    private func decoded<T: Decodable>(_ type: T.Type, _ statement: OpaquePointer, _ column: Int32 = 0) throws -> T {
        guard let bytes = sqlite3_column_blob(statement, column) else { throw HubStoreError.database("记录为空。") }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw HubStoreError.database("无法读取 \(type) 记录：\(error.localizedDescription)") }
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Value {
        let data = try JSONEncoder().encode(value)
        // Redact string leaves, preserving JSON quoting, scalar types and entity structure.
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        func sanitized(_ object: Any) -> Any {
            switch object {
            case let text as String: return HubRedaction.text(text)
            case let array as [Any]: return array.map(sanitized)
            case let dictionary as [String: Any]: return dictionary.mapValues(sanitized)
            default: return object
            }
        }
        return .blob(try JSONSerialization.data(withJSONObject: sanitized(object), options: [.fragmentsAllowed]))
    }

    public func projects() throws -> [HubProject] {
        try synchronized { try query("SELECT payload FROM projects ORDER BY path") { try decoded(HubProject.self, $0) } }
    }

    public func project(_ id: String) throws -> HubProject {
        try synchronized {
            guard let value = try query("SELECT payload FROM projects WHERE id=?", [.text(id)], row: { try decoded(HubProject.self, $0) }).first
            else { throw HubStoreError.missing("项目") }
            return value
        }
    }

    public func saveProject(_ project: HubProject) throws {
        try transaction {
            guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  project.path.hasPrefix("/"), !project.id.isEmpty else { throw HubStoreError.invalid("项目需要名称和绝对路径。") }
            var value = project
            value.path = URL(fileURLWithPath: project.path).standardizedFileURL.resolvingSymlinksInPath().path
            try validate(value.configuration)
            try write("""
                INSERT INTO projects(id,path,payload) VALUES (?,?,?)
                ON CONFLICT(id) DO UPDATE SET path=excluded.path,payload=excluded.payload
                """, [.text(value.id), .text(value.path), try encoded(value)])
        }
    }

    public func globalConfiguration() throws -> HubConfiguration {
        try synchronized {
            try query("SELECT payload FROM config WHERE id='global'") { try decoded(HubConfiguration.self, $0) }.first ?? .balanced
        }
    }

    public func saveGlobalConfiguration(_ value: HubConfiguration) throws {
        try transaction {
            try validate(value)
            try write("INSERT INTO config(id,payload) VALUES ('global',?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                      [try encoded(value)])
        }
    }

    public func effectiveConfiguration(for task: HubTask) throws -> HubConfiguration {
        try synchronized {
            if let snapshot = task.runtimeConfig { return snapshot }
            return try HubConfiguration.balanced.overriding(with: globalConfiguration())
                .overriding(with: project(task.projectID).configuration).overriding(with: task.overrides)
        }
    }

    private func validate(_ config: HubConfiguration) throws {
        for (name, value) in config.commandEnvironment ?? [:] {
            guard name.range(of: #"(?i)(?:token|secret|passwd|password|api.?key|credential|private.?key|cookie|authorization)"#,
                             options: .regularExpression) == nil, HubRedaction.text(value) == value else {
                throw HubStoreError.invalid("项目环境设置只接受非敏感值。请在连接设置中存储凭据。")
            }
        }
        let positive = [config.maxConcurrent, config.maxSeconds].compactMap { $0 } + Array(config.providerConcurrency.values)
        let nonnegative = [config.maxAttempts, config.maxRetries, config.maxRepairs].compactMap { $0 }
        let costs = [config.maxCostUSD, config.reservedCostUSD].compactMap { $0 }
        guard positive.allSatisfy({ $0 > 0 }), nonnegative.allSatisfy({ $0 >= 0 }), costs.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw HubStoreError.invalid("预算或并发限制无效。")
        }
    }

    public func tasks(projectID: String? = nil) throws -> [HubTask] {
        try synchronized {
            let filter = projectID == nil ? "" : " WHERE project_id=?"
            let values = projectID.map { [Value.text($0)] } ?? []
            return try query("SELECT payload FROM tasks" + filter + " ORDER BY priority DESC,updated DESC,id", values) { try decoded(HubTask.self, $0) }
        }
    }

    /// A board refresh checks small index fields first and decodes only newly inserted or changed aggregates.
    public func taskUpdates(known: [String: Date]) throws -> [HubTask] {
        try synchronized {
            let ids = try query("SELECT id,updated FROM tasks") { row -> String? in
                let id = string(row, 0)
                return known[id]?.timeIntervalSince1970 == sqlite3_column_double(row, 1) ? nil : id
            }.compactMap { $0 }
            guard !ids.isEmpty else { return [] }
            let json = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
            return try query("SELECT payload FROM tasks WHERE id IN (SELECT value FROM json_each(?)) ORDER BY priority DESC,updated DESC,id",
                             [.text(json)]) { try decoded(HubTask.self, $0) }
        }
    }

    public func task(_ id: String) throws -> HubTask {
        try synchronized {
            guard let value = try query("SELECT payload FROM tasks WHERE id=?", [.text(id)], row: { try decoded(HubTask.self, $0) }).first
            else { throw HubStoreError.missing("任务") }
            return value
        }
    }

    private func priorRequest(_ id: String?, operation: String) throws -> String? {
        guard let id else { return nil }
        guard let previous = try query("SELECT task_id,operation FROM requests WHERE id=?", [.text(id)], row: { (string($0, 0), string($0, 1)) }).first else { return nil }
        guard previous.1 == operation else { throw HubStoreError.invalid("请求编号已由其他操作使用。") }
        return previous.0
    }

    private func recordRequest(_ id: String?, taskID: String, operation: String) throws {
        if let id { try write("INSERT INTO requests(id,task_id,operation) VALUES (?,?,?)", [.text(id), .text(taskID), .text(operation)]) }
    }

    @discardableResult
    public func createTask(_ task: HubTask, requestID: String? = nil) throws -> HubTask {
        try transaction {
            if let existing = try priorRequest(requestID, operation: "create") { return try self.task(existing) }
            guard task.state == .queued, !task.id.isEmpty, !task.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HubStoreError.invalid("新任务需要目标，且初始状态必须为待开始。")
            }
            try validate(task.overrides)
            try write("INSERT INTO tasks(id,project_id,priority,updated,payload) VALUES(?,?,?,?,?)",
                      [.text(task.id), .text(task.projectID), .integer(Int64(task.priority)), .real(task.updatedAt.timeIntervalSince1970), try encoded(task)])
            try saveRevisions(task, previous: nil)
            try insertEvent(task: task, kind: "task.created", detail: "", attemptID: nil)
            try recordRequest(requestID, taskID: task.id, operation: "create")
            return try self.task(task.id)
        }
    }

    @discardableResult
    public func updateTask(_ id: String, kind: String, detail: String = "", requestID: String? = nil,
                           _ mutate: (inout HubTask) throws -> Void) throws -> HubTask {
        try transaction {
            let operation = "update:" + kind
            if let existing = try priorRequest(requestID, operation: operation) {
                guard existing == id else { throw HubStoreError.invalid("请求编号已由另一个任务使用。") }
                return try task(id)
            }
            let old = try task(id)
            var next = old
            try mutate(&next)
            guard next.id == old.id, next.projectID == old.projectID, next.originalGoal == old.originalGoal,
                  next.requirementRevision >= old.requirementRevision, next.generation >= old.generation,
                  next.planRevision >= old.planRevision, old.state != .cancelled || next.state == .cancelled else {
                throw HubStoreError.invalid("任务身份、取消状态或修订号发生冲突。")
            }
            // The first dispatch fixes the effective settings even when a caller does not supply a snapshot.
            if old.runtimeConfig == nil && next.state == .running && next.runtimeConfig == nil {
                next.runtimeConfig = try effectiveConfiguration(for: next)
            }
            try validate(next.overrides)
            if let snapshot = next.runtimeConfig { try validate(snapshot) }
            let wasRunning = old.state == .running || old.state == .pausing
            let nowRunning = next.state == .running || next.state == .pausing
            if !wasRunning && nowRunning { next.runningSince = Date() }
            if wasRunning && !nowRunning {
                if let start = old.runningSince { next.elapsedSeconds += max(0, Date().timeIntervalSince(start)) }
                next.runningSince = nil
            }
            if next != old {
                next.updatedAt = Date()
                try saveRevisions(next, previous: old)
                try write("UPDATE tasks SET priority=?,updated=?,payload=? WHERE id=?",
                          [.integer(Int64(next.priority)), .real(next.updatedAt.timeIntervalSince1970), try encoded(next), .text(id)])
                try insertEvent(task: next, kind: kind, detail: detail, attemptID: nil)
            }
            try recordRequest(requestID, taskID: id, operation: operation)
            return try task(id)
        }
    }

    private func saveRevisions(_ task: HubTask, previous: HubTask?) throws {
        if previous?.requirementRevision != task.requirementRevision {
            try write("INSERT INTO requirements(task_id,revision,goal,acceptance) VALUES(?,?,?,?)",
                      [.text(task.id), .integer(Int64(task.requirementRevision)), .text(HubRedaction.text(task.goal)), try encoded(task.acceptance)])
        }
        if let plan = task.plan, previous?.plan?.revision != plan.revision {
            try write("INSERT INTO plans(task_id,revision,payload) VALUES(?,?,?)", [.text(task.id), .integer(Int64(plan.revision)), try encoded(plan)])
        }
    }

    public func planHistory(taskID: String) throws -> [PlanRevision] {
        try synchronized { try query("SELECT payload FROM plans WHERE task_id=? ORDER BY revision", [.text(taskID)]) { try decoded(PlanRevision.self, $0) } }
    }

    public func requirementHistory(taskID: String) throws -> [(revision: Int, goal: String, acceptance: [String])] {
        try synchronized {
            try query("SELECT revision,goal,acceptance FROM requirements WHERE task_id=? ORDER BY revision", [.text(taskID)]) {
                (Int(sqlite3_column_int64($0, 0)), string($0, 1), try decoded([String].self, $0, 2))
            }
        }
    }

    /// Subsequent events for a superseded attempt keep that attempt's original revision and generation.
    public func appendEvent(taskID: String, kind: String, detail: String, attemptID: String? = nil,
                            eventID: String = UUID().uuidString, providerEventType: String? = nil) throws {
        try transaction {
            let task = try task(taskID)
            try insertEvent(task: task, kind: kind, detail: detail, attemptID: attemptID, eventID: eventID, providerEventType: providerEventType)
        }
    }

    private func insertEvent(task: HubTask, kind: String, detail: String, attemptID: String?,
                             eventID: String = UUID().uuidString, providerEventType: String? = nil) throws {
        let attempt = task.attempts.first { $0.id == attemptID }
        let safeKind = boundedRedacted(kind, bytes: 128)
        let capped = boundedRedacted(detail, bytes: 8192)
        let rawType = providerEventType.map { boundedRedacted($0, bytes: 128) }
        try write("""
            INSERT INTO events(id,task_id,attempt_id,requirement,plan,generation,time,kind,detail,provider_type)
            VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING
            """, [.text(eventID), .text(task.id), attemptID.map(Value.text) ?? .null,
                  .integer(Int64(attempt?.requirementRevision ?? task.requirementRevision)),
                  .integer(Int64(attempt?.planRevision ?? task.planRevision)),
                  .integer(Int64(attempt?.generation ?? task.generation)),
                  .real(Date().timeIntervalSince1970), .text(safeKind), .text(capped), rawType.map(Value.text) ?? .null])
        // Periodic pruning keeps the per-task feed bounded without recounting it on every append.
        guard sqlite3_changes(db) > 0 else { return }
        let count = try query("""
            INSERT INTO event_counters(task_id,seen) VALUES(?,1)
            ON CONFLICT(task_id) DO UPDATE SET seen=seen+1 RETURNING seen
            """, [.text(task.id)]) { sqlite3_column_int64($0, 0) }.first ?? 0
        guard count >= 4096 && count % 128 == 0 else { return }
        try write("""
            DELETE FROM events WHERE task_id=? AND seq<=(
                SELECT seq FROM events WHERE task_id=? ORDER BY seq DESC LIMIT 1 OFFSET 4096
            )
            """, [.text(task.id), .text(task.id)])
    }

    private func boundedRedacted(_ source: String, bytes limit: Int) -> String {
        let safe = HubRedaction.text(source)
        guard safe.utf8.count > limit else { return safe }
        var bytes = safe.utf8.prefix(limit)
        while let last = bytes.last, (0x80...0xBF).contains(last) || last >= 0xC0 {
            if let valid = String(bytes: bytes, encoding: .utf8) { return valid }
            bytes = bytes.dropLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func pageLimit(_ limit: Int) -> Value { .integer(Int64(min(max(1, limit), 500))) }

    private func readEvent(_ statement: OpaquePointer) -> HubEvent {
        HubEvent(id: string(statement, 1), sequence: sqlite3_column_int64(statement, 0),
                 taskID: string(statement, 2), attemptID: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : string(statement, 3),
                 requirementRevision: Int(sqlite3_column_int64(statement, 4)), planRevision: Int(sqlite3_column_int64(statement, 5)),
                 generation: Int(sqlite3_column_int64(statement, 6)), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                 kind: string(statement, 8), detail: string(statement, 9),
                 providerEventType: sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : string(statement, 10))
    }

    private var eventColumns: String { "SELECT seq,id,task_id,attempt_id,requirement,plan,generation,time,kind,detail,provider_type FROM events" }

    public func events(taskID: String, after: Int64 = 0, limit: Int = 200) throws -> [HubEvent] {
        try synchronized {
            try query(eventColumns + " WHERE task_id=? AND seq>? ORDER BY seq LIMIT ?",
                      [.text(taskID), .integer(after), pageLimit(limit)], row: readEvent)
        }
    }

    /// Recent reads return a chronological page. Pass its first sequence as 'before' to page backward.
    public func recentEvents(taskID: String, attemptID: String? = nil, before: Int64? = nil, limit: Int = 200) throws -> [HubEvent] {
        try synchronized {
            var sql = eventColumns + " WHERE task_id=?"
            var args: [Value] = [.text(taskID)]
            if let attemptID { sql += " AND attempt_id=?"; args.append(.text(attemptID)) }
            if let before { sql += " AND seq<?"; args.append(.integer(before)) }
            return try query(sql + " ORDER BY seq DESC LIMIT ?", args + [pageLimit(limit)], row: readEvent).reversed()
        }
    }

    public func recentRoleEvents(taskID: String, attemptIDs: [String], includeTaskEvents: Bool,
                                 before: Int64? = nil, limit: Int = 200) throws -> [HubEvent] {
        try synchronized {
            guard includeTaskEvents || !attemptIDs.isEmpty else { return [] }
            let identifiers = String(decoding: try JSONEncoder().encode(attemptIDs), as: UTF8.self)
            let filter = includeTaskEvents ? "(attempt_id IN (SELECT value FROM json_each(?)) OR attempt_id IS NULL)"
                                          : "attempt_id IN (SELECT value FROM json_each(?))"
            // Select the final visible snapshot for each text stream across its entire history before
            // applying the page cursor. Otherwise a second page could redisplay the same utterance.
            var sql = """
                WITH grouped AS (
                    SELECT MAX(seq) AS seq,task_id,attempt_id,kind,
                           CASE WHEN kind='provider.text' AND id LIKE 'text/%' AND substr(id,-37,1)='/'
                                THEN substr(id,1,length(id)-37) ELSE id END AS stream_id
                    FROM events WHERE task_id=? AND
                """ + " " + filter + """
                 AND kind NOT IN ('message.queued','message.delivered','message.processed')
                 GROUP BY task_id,attempt_id,kind,stream_id
                )
                """ + " " + eventColumns + """
                 WHERE seq IN (
                    SELECT seq FROM grouped WHERE kind!='provider.text' OR NOT EXISTS (
                        SELECT 1 FROM final_streams AS f WHERE f.task_id=grouped.task_id
                        AND f.attempt_id=grouped.attempt_id AND f.stream_id=grouped.stream_id
                    )
                )
                """
            var args: [Value] = [.text(taskID), .text(identifiers)]
            if let before { sql += " AND seq<?"; args.append(.integer(before)) }
            return try query(sql + " ORDER BY seq DESC LIMIT ?", args + [pageLimit(limit)], row: readEvent).reversed()
        }
    }

    public func saveDraft(taskID: String, recipient: String, text: String) throws {
        try transaction {
            if text.isEmpty {
                try write("DELETE FROM drafts WHERE task_id=? AND recipient=?", [.text(taskID), .text(recipient)])
            } else {
                try write("""
                    INSERT INTO drafts(task_id,recipient,text) VALUES(?,?,?)
                    ON CONFLICT(task_id,recipient) DO UPDATE SET text=excluded.text
                    """, [.text(taskID), .text(recipient), .text(HubRedaction.text(text))])
            }
        }
    }

    public func draft(taskID: String, recipient: String) throws -> String {
        try synchronized {
            try query("SELECT text FROM drafts WHERE task_id=? AND recipient=?", [.text(taskID), .text(recipient)]) { string($0, 0) }.first ?? ""
        }
    }

    /// Insertion and clearing the matching submitted draft are one action. Replay preserves a newer draft.
    public func saveMessage(_ message: HubMessage, clearDraft: Bool = false) throws {
        try transaction {
            let task = try task(message.taskID)
            if let existing = try query("SELECT task_id,sender,recipient FROM messages WHERE id=?", [.text(message.id)],
                                        row: { (string($0, 0), string($0, 1), string($0, 2)) }).first {
                guard existing == (message.taskID, message.sender, message.recipient)
                else { throw HubStoreError.invalid("消息编号已用于其他接收对象。") }
                return
            }
            if message.sender == "user" {
                guard task.state != .completed else { throw HubStoreError.invalid("任务已完成。请修改需求或创建后续任务。") }
                guard task.state != .cancelled else { throw HubStoreError.invalid("任务已取消。请创建后续任务。") }
                guard task.requirementRevision == message.requirementRevision else {
                    throw HubStoreError.invalid("任务需求已更新。请检查草稿后重新发送。")
                }
            }
            guard !message.recipient.isEmpty, !message.sender.isEmpty, !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw HubStoreError.invalid("消息需要发送者、接收对象和内容。") }
            try write("""
                INSERT INTO messages(id,task_id,sender,recipient,payload) VALUES(?,?,?,?,?) ON CONFLICT(id) DO NOTHING
                """, [.text(message.id), .text(task.id), .text(message.sender), .text(message.recipient), try encoded(message)])
            guard sqlite3_changes(db) > 0 else { return }
            try indexFinalStream(for: message, task: task)
            if clearDraft {
                try write("DELETE FROM drafts WHERE task_id=? AND recipient=? AND text=?",
                          [.text(task.id), .text(message.recipient), .text(HubRedaction.text(message.text))])
            }
            try insertEvent(task: task, kind: "message." + message.delivery.rawValue, detail: message.recipient, attemptID: nil)
        }
    }

    /// A reply replaces only the stream that produced it. Raw event history is never removed here.
    private func indexFinalStream(for message: HubMessage, task: HubTask) throws {
        guard message.sender != "user", message.recipient == "user", message.delivery == .processed else { return }
        let attemptID: String
        let group: String
        if let explicitID = message.attemptID {
            guard let explicitGroup = message.finalStreamGroup,
                  explicitGroup.hasPrefix("text/" + explicitID + "/"),
                  task.attempts.contains(where: { $0.id == explicitID && $0.role == message.sender && $0.requirementRevision == message.requirementRevision })
            else { return }
            attemptID = explicitID
            group = explicitGroup
        } else {
            // Older records lack a direct link. Only a unique matching completed round and its very
            // last text event can be replaced. Keep ambiguous evidence visible.
            guard let item = message.itemID else { return }
            let eligible = task.attempts.filter { $0.itemID == item && $0.role == message.sender && $0.requirementRevision == message.requirementRevision }
            let candidates = eligible.filter { attempt in
                guard let end = attempt.endedAt, let summary = attempt.summary, summary == message.text,
                      message.sessionID == nil || attempt.providerSessionID == message.sessionID else { return false }
                let delta = message.createdAt.timeIntervalSince(end)
                return (0...120).contains(delta) && !eligible.contains(where: {
                    $0.id != attempt.id && $0.startedAt > attempt.startedAt && $0.startedAt <= message.createdAt
                })
            }
            guard candidates.count == 1, let attempt = candidates.first,
                  let last = try query("""
                     SELECT id,detail FROM events WHERE task_id=? AND attempt_id=? AND kind='provider.text'
                     ORDER BY seq DESC LIMIT 1
                     """, [.text(task.id), .text(attempt.id)], row: { (string($0, 0), string($0, 1)) }).first,
                  !last.1.isEmpty, message.text.hasPrefix(last.1) || message.text.hasSuffix(last.1) else { return }
            attemptID = attempt.id
            if last.0.hasPrefix("text/" + attempt.id + "/"), let slash = last.0.lastIndex(of: "/"),
               UUID(uuidString: String(last.0[last.0.index(after: slash)...])) != nil {
                group = String(last.0[..<slash])
            } else {
                group = last.0
            }
        }
        try write("""
            INSERT INTO final_streams(task_id,attempt_id,stream_id,message_id) VALUES(?,?,?,?)
            ON CONFLICT(task_id,attempt_id,stream_id) DO NOTHING
            """, [.text(task.id), .text(attemptID), .text(group), .text(message.id)])
    }

    private func backfillFinalStreams() throws {
        var cursor: Int64 = 0
        var cachedTask: HubTask?
        while true {
            let page = try query("""
                SELECT seq,payload FROM messages WHERE sender!='user' AND recipient='user' AND seq>?
                ORDER BY seq LIMIT 100
                """, [.integer(cursor)], row: readMessage)
            guard let last = page.last else { return }
            for message in page {
                if cachedTask?.id != message.taskID { cachedTask = try task(message.taskID) }
                if let cachedTask { try indexFinalStream(for: message, task: cachedTask) }
            }
            cursor = last.sequence
        }
    }

    public func setDelivery(messageID: String, to state: MessageDelivery) throws {
        try transaction {
            guard var message = try query("SELECT seq,payload FROM messages WHERE id=?", [.text(messageID)], row: readMessage).first
            else { throw HubStoreError.missing("消息") }
            let order: [MessageDelivery] = [.queued, .delivered, .processed]
            guard order.firstIndex(of: state)! > order.firstIndex(of: message.delivery)! else { return }
            message.delivery = state
            try write("UPDATE messages SET payload=? WHERE id=?", [try encoded(message), .text(messageID)])
            try insertEvent(task: task(message.taskID), kind: "message." + state.rawValue, detail: message.recipient, attemptID: nil)
        }
    }

    private func readMessage(_ statement: OpaquePointer) throws -> HubMessage {
        var result = try decoded(HubMessage.self, statement, 1)
        result.sequence = sqlite3_column_int64(statement, 0)
        return result
    }

    public func messages(taskID: String, recipient: String? = nil, after: Int64 = 0, limit: Int = 200) throws -> [HubMessage] {
        try synchronized {
            var sql = "SELECT seq,payload FROM messages WHERE task_id=? AND seq>?"
            var args: [Value] = [.text(taskID), .integer(after)]
            if let recipient { sql += " AND recipient=?"; args.append(.text(recipient)) }
            return try query(sql + " ORDER BY seq LIMIT ?", args + [pageLimit(limit)], row: readMessage)
        }
    }

    public func pendingUserMessages(taskID: String, requirementRevision: Int, limit: Int = 200) throws -> [HubMessage] {
        try synchronized {
            try query("""
                SELECT seq,payload FROM messages WHERE task_id=? AND sender='user'
                AND json_extract(CAST(payload AS TEXT),'$.requirementRevision')=?
                AND json_extract(CAST(payload AS TEXT),'$.delivery') IN ('queued','delivered')
                ORDER BY seq LIMIT ?
                """, [.text(taskID), .integer(Int64(requirementRevision)), pageLimit(limit)], row: readMessage)
        }
    }

    public func recentMessages(taskID: String, recipient: String? = nil, before: Int64? = nil, limit: Int = 200) throws -> [HubMessage] {
        try recentMessagePage(taskID: taskID, recipient: recipient, conversation: nil, before: before, limit: limit)
    }

    public func recentConversation(taskID: String, role: String, before: Int64? = nil, limit: Int = 200) throws -> [HubMessage] {
        try recentMessagePage(taskID: taskID, recipient: nil, conversation: role, before: before, limit: limit)
    }

    private func recentMessagePage(taskID: String, recipient: String?, conversation: String?, before: Int64?, limit: Int) throws -> [HubMessage] {
        try synchronized {
            var sql = "SELECT seq,payload FROM messages WHERE task_id=?"
            var args: [Value] = [.text(taskID)]
            if let before { sql += " AND seq<?"; args.append(.integer(before)) }
            if let recipient { sql += " AND recipient=?"; args.append(.text(recipient)) }
            if let role = conversation {
                sql += role == "lead" ? " AND (recipient IN (?, 'task') OR sender IN (?, 'task'))" : " AND (recipient=? OR sender=?)"
                args += [.text(role), .text(role)]
            }
            return try query(sql + " ORDER BY seq DESC LIMIT ?", args + [pageLimit(limit)], row: readMessage).reversed()
        }
    }

    /// Invoke after the supervisor has reconciled any reliably identifiable process trees.
    /// No PID-only process termination or silent replay occurs on database open.
    @discardableResult
    public func recoverInterrupted() throws -> [String] {
        var recovered: [String] = []
        for candidate in try tasks() where candidate.state == .running || candidate.state == .pausing || candidate.attempts.contains(where: { $0.state.isActive }) {
            let result = try updateTask(candidate.id, kind: "recovery.interrupted", detail: "已保留工作区。请确认后从检查点继续。") { current in
                guard current.state == .running || current.state == .pausing || current.attempts.contains(where: { $0.state.isActive }) else { return }
                for index in current.attempts.indices where current.attempts[index].state.isActive {
                    current.attempts[index].state = .interrupted
                    current.attempts[index].endedAt = Date()
                    current.attempts[index].failureKind = "resume_required"
                    current.attempts[index].failure = "应用重启后，原执行无法重新连接。"
                }
                if var plan = current.plan {
                    for index in plan.items.indices where plan.items[index].state == .running {
                        plan.items[index].state = .pending
                    }
                    current.plan = plan
                }
                current.generation += 1
                if current.state != .cancelled && current.state != .completed {
                    current.state = .needsUser
                    current.attentionReason = "resume_required"
                }
            }
            recovered.append(result.id)
        }
        return recovered
    }
}
