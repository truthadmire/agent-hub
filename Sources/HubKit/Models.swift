import Foundation
import HubProviders

public enum TaskState: String, Codable, CaseIterable, Sendable {
    case queued, running, pausing, paused, needsUser = "needs_user", completed, cancelled
}

public enum TaskPhase: String, Codable, CaseIterable, Sendable {
    case planning, implementing, integrating, verifying, repairing
}

public enum AttemptState: String, Codable, CaseIterable, Sendable {
    case queued, starting, running, succeeded, failed, cancelled, interrupted
    public var isActive: Bool { self == .queued || self == .starting || self == .running }
}

public enum WorkItemState: String, Codable, Sendable {
    case pending, running, delivered, integrated
}

public enum VerificationState: String, Codable, Sendable {
    case passed, failed, notRun = "not_run", blocked, notApplicable = "not_applicable", waived
}

public enum MessageDelivery: String, Codable, Sendable { case queued, delivered, processed }

/// Nil values inherit the next broader scope. Each role override inherits independently.
public struct HubConfiguration: Codable, Equatable, Sendable {
    public var roles: [String: ProviderID] = [:]
    public var models: [String: String] = [:]
    public var executableOverrides: [String: String] = [:]
    public var disabledProviders: [ProviderID]?
    public var enabledRoles: [String]?
    public var maxCostUSD: Double?
    public var reservedCostUSD: Double?
    public var maxAttempts: Int?
    public var maxConcurrent: Int?
    public var providerConcurrency: [String: Int] = [:]
    public var maxRetries: Int?
    public var maxRepairs: Int?
    public var maxSeconds: Int?
    public var commandWorkingDirectory: String?
    public var commandEnvironment: [String: String]?
    public var installCommand: [String]?
    public var verificationCommands: [[String]]?
    public var previewCommand: [String]?
    public var paidProviders: [ProviderID]?
    public var allowedFallbacks: [ProviderID]?
    public init() {}

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case roles, models, executableOverrides, disabledProviders, enabledRoles, maxCostUSD, reservedCostUSD
        case maxAttempts, maxConcurrent, providerConcurrency, maxRetries, maxRepairs, maxSeconds
        case commandWorkingDirectory, commandEnvironment, installCommand, verificationCommands, previewCommand
        case paidProviders, allowedFallbacks
    }

    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: Field.self)
        let supported = Set(CodingKeys.allCases.map(\.rawValue))
        let unknown = raw.allKeys.map(\.stringValue).filter { !supported.contains($0) }
        guard unknown.isEmpty else {
            throw HubStoreError.invalid("配置包含此版本无法识别的字段（" + unknown.sorted().joined(separator: "、") + "）。请使用兼容版本读取。")
        }
        let box = try decoder.container(keyedBy: CodingKeys.self)
        roles = try box.decodeIfPresent([String: ProviderID].self, forKey: .roles) ?? [:]
        models = try box.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
        executableOverrides = try box.decodeIfPresent([String: String].self, forKey: .executableOverrides) ?? [:]
        disabledProviders = try box.decodeIfPresent([ProviderID].self, forKey: .disabledProviders)
        enabledRoles = try box.decodeIfPresent([String].self, forKey: .enabledRoles)
        maxCostUSD = try box.decodeIfPresent(Double.self, forKey: .maxCostUSD)
        reservedCostUSD = try box.decodeIfPresent(Double.self, forKey: .reservedCostUSD)
        maxAttempts = try box.decodeIfPresent(Int.self, forKey: .maxAttempts)
        maxConcurrent = try box.decodeIfPresent(Int.self, forKey: .maxConcurrent)
        providerConcurrency = try box.decodeIfPresent([String: Int].self, forKey: .providerConcurrency) ?? [:]
        maxRetries = try box.decodeIfPresent(Int.self, forKey: .maxRetries)
        maxRepairs = try box.decodeIfPresent(Int.self, forKey: .maxRepairs)
        maxSeconds = try box.decodeIfPresent(Int.self, forKey: .maxSeconds)
        commandWorkingDirectory = try box.decodeIfPresent(String.self, forKey: .commandWorkingDirectory)
        commandEnvironment = try box.decodeIfPresent([String: String].self, forKey: .commandEnvironment)
        installCommand = try box.decodeIfPresent([String].self, forKey: .installCommand)
        verificationCommands = try box.decodeIfPresent([[String]].self, forKey: .verificationCommands)
        previewCommand = try box.decodeIfPresent([String].self, forKey: .previewCommand)
        paidProviders = try box.decodeIfPresent([ProviderID].self, forKey: .paidProviders)
        allowedFallbacks = try box.decodeIfPresent([ProviderID].self, forKey: .allowedFallbacks)
    }

    public static var balanced: Self {
        var value = Self()
        value.roles = ["lead": .codex, "frontend": .antigravity, "backend": .codex,
                       "test": .dsh, "review": .codex]
        value.disabledProviders = []
        value.enabledRoles = ["lead", "frontend", "backend", "test", "review"]
        value.maxAttempts = 12
        value.maxConcurrent = 2
        value.maxRetries = 2
        value.maxRepairs = 2
        value.maxSeconds = 3600
        value.verificationCommands = []
        value.paidProviders = []
        value.allowedFallbacks = []
        return value
    }

    public func overriding(with other: Self) -> Self {
        var value = self
        for (role, provider) in other.roles where value.roles[role] != provider {
            value.models.removeValue(forKey: role)
        }
        value.roles.merge(other.roles) { _, new in new }
        value.models.merge(other.models) { _, new in new }
        value.providerConcurrency.merge(other.providerConcurrency) { _, new in new }
        value.executableOverrides.merge(other.executableOverrides) { _, new in new }
        value.disabledProviders = other.disabledProviders ?? disabledProviders
        value.enabledRoles = other.enabledRoles ?? enabledRoles
        value.maxCostUSD = other.maxCostUSD ?? maxCostUSD
        value.reservedCostUSD = other.reservedCostUSD ?? reservedCostUSD
        value.maxAttempts = other.maxAttempts ?? maxAttempts
        value.maxConcurrent = other.maxConcurrent ?? maxConcurrent
        value.maxRetries = other.maxRetries ?? maxRetries
        value.maxRepairs = other.maxRepairs ?? maxRepairs
        value.maxSeconds = other.maxSeconds ?? maxSeconds
        value.commandWorkingDirectory = other.commandWorkingDirectory ?? commandWorkingDirectory
        value.commandEnvironment = other.commandEnvironment ?? commandEnvironment
        value.installCommand = other.installCommand ?? installCommand
        value.verificationCommands = other.verificationCommands ?? verificationCommands
        value.previewCommand = other.previewCommand ?? previewCommand
        value.paidProviders = other.paidProviders ?? paidProviders
        value.allowedFallbacks = other.allowedFallbacks ?? allowedFallbacks
        return value
    }
}

public struct HubProject: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var stack: [String] = []
    public var branch: String?
    public var baseCommit: String?
    public var changedPaths: [String] = []
    public var isDirty = false
    public var instructions: [String] = []
    public var configuration = HubConfiguration()
    public var createdAt = Date()
    public init(id: String = UUID().uuidString, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

public struct WorkspaceReference: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var branch: String
    public var baseCommit: String
    public var snapshot: String?
    public init(id: String = UUID().uuidString, path: String, branch: String, baseCommit: String) {
        self.id = id
        self.path = path
        self.branch = branch
        self.baseCommit = baseCommit
    }
}

public struct WorkItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var role: String
    public var provider: ProviderID
    public var dependencies: [String] = []
    public var inputs: [String] = []
    public var deliverables: [String] = []
    public var readScope: [String] = []
    public var writeScope: [String] = []
    public var state: WorkItemState = .pending
    public var workspace: WorkspaceReference?
    public init(id: String = UUID().uuidString, title: String, role: String, provider: ProviderID) {
        self.id = id
        self.title = title
        self.role = role
        self.provider = provider
    }
}

public struct PlanRevision: Codable, Equatable, Sendable {
    public var revision: Int
    public var requirementRevision: Int
    public var goal: String
    public var items: [WorkItem]
    public var acceptance: [String] = []
    public var interfaces: [String] = []
    public var checks: [String] = []
    public var questions: [String] = []
    public init(revision: Int, requirementRevision: Int, goal: String, items: [WorkItem]) {
        self.revision = revision
        self.requirementRevision = requirementRevision
        self.goal = goal
        self.items = items
    }
}

public struct HubAttempt: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var itemID: String
    public var provider: ProviderID
    public var role: String
    public var model: String?
    public var requirementRevision: Int
    public var planRevision: Int
    public var generation: Int
    public var revalidatedGeneration: Int?
    public var state: AttemptState = .starting
    public var previousID: String?
    public var providerSessionID: String?
    public var workspace: WorkspaceReference?
    public var configuration: HubConfiguration?
    public var startedAt = Date()
    public var endedAt: Date?
    public var retryAfter: Date?
    public var failureKind: String?
    public var billingUSD: Double?
    public var usageSource: String?
    public var usageObservedAt: Date?
    public var integratedCommit: String?
    public var changedPaths: [String] = []
    public var failure: String?
    public var summary: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var modelRequestCount: Int?
    public var processIdentity: Data?
    public var pid: Int32?
    public var processGroup: Int32?
    public var executable: String?
    public var processStartedAt: Date?
    public init(id: String = UUID().uuidString, itemID: String, provider: ProviderID, role: String,
                requirementRevision: Int, planRevision: Int, generation: Int) {
        self.id = id
        self.itemID = itemID
        self.provider = provider
        self.role = role
        self.requirementRevision = requirementRevision
        self.planRevision = planRevision
        self.generation = generation
    }
}

/// Stable projection of CLI sessions from durable, append-only attempt identities.
public struct HubProviderSession: Identifiable, Equatable, Sendable {
    /// The UUID of the first attempt observing this session is stable across reloads.
    public let id: String
    public let taskID: String
    public let provider: ProviderID
    public let externalID: String
    public let attemptIDs: [String]
    public let workspaceID: String?
    public let createdAt: Date
    public let lastObservedAt: Date
}

public struct HubVerification: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var required: Bool
    public var state: VerificationState
    public var requirementRevision: Int
    public var snapshot: String
    public var snapshotAfter: String?
    public var command: [String] = []
    public var directory: String?
    public var environment: String?
    public var startedAt = Date()
    public var endedAt: Date?
    public var exitCode: Int32?
    public var evidence: String?
    public var reason: String?
    public var actor: String?
    public init(id: String = UUID().uuidString, name: String, required: Bool = true,
                state: VerificationState, requirementRevision: Int, snapshot: String) {
        self.id = id
        self.name = name
        self.required = required
        self.state = state
        self.requirementRevision = requirementRevision
        self.snapshot = snapshot
    }
}

public struct HubHandoff: Identifiable, Codable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var createdAt = Date()
    public var fromAttemptID: String?
    public var requirementRevision: Int
    public var planRevision: Int
    public var goal: String
    public var workspace: WorkspaceReference?
    public var completed: [String] = []
    public var remaining: [String] = []
    public var decisions: [String] = []
    public var interfaces: [String] = []
    public var verificationIDs: [String] = []
    public var artifactIDs: [String] = []
    public var issues: [String] = []
    public var lastFailure: String?
    public var nextAction: String
    public init(goal: String, requirementRevision: Int, planRevision: Int, nextAction: String) {
        self.goal = goal
        self.requirementRevision = requirementRevision
        self.planRevision = planRevision
        self.nextAction = nextAction
    }
}

public struct HubArtifact: Identifiable, Codable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var kind: String
    public var title: String
    public var path: String
    public var snapshot: String?
    public var createdAt = Date()
    public init(kind: String, title: String, path: String) {
        self.kind = kind
        self.title = title
        self.path = path
    }
}

public struct HubTask: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var projectID: String
    public var title: String
    public var selectedBaseCommit: String?
    public var expectedSnapshotID: String?
    public var includeUncommitted = false
    public var originalGoal: String
    public var goal: String
    public var acceptance: [String]
    public var priority: Int
    public var overrides: HubConfiguration
    public var runtimeConfig: HubConfiguration?
    public var state: TaskState = .queued
    public var phase: TaskPhase = .planning
    public var attentionReason: String?
    public var summary = ""
    public var requirementRevision = 1
    public var planRevision = 0
    public var generation = 0
    public var plan: PlanRevision?
    public var attempts: [HubAttempt] = []
    public var verifications: [HubVerification] = []
    public var handoffs: [HubHandoff] = []
    public var artifacts: [HubArtifact] = []
    public var decisions: [String] = []
    public var workspace: WorkspaceReference?
    public var retryCount = 0
    public var repairCount = 0
    public var switchCount = 0
    public var elapsedSeconds: Double = 0
    public var runningSince: Date?
    public var isArchived = false
    public var createdAt = Date()
    public var updatedAt = Date()
    public init(id: String = UUID().uuidString, projectID: String, title: String, goal: String,
                acceptance: [String] = [], priority: Int = 0, overrides: HubConfiguration = .init()) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.originalGoal = goal
        self.goal = goal
        self.acceptance = acceptance
        self.priority = priority
        self.overrides = overrides
    }
}

extension HubTask {
    /// A CLI's session identifier is scoped to its provider. Several sequential rounds may share it.
    public var providerSessions: [HubProviderSession] {
        var providers: [ProviderID: [String: [HubAttempt]]] = [:]
        for attempt in attempts {
            guard let external = attempt.providerSessionID, !external.isEmpty else { continue }
            providers[attempt.provider, default: [:]][external, default: []].append(attempt)
        }
        var sessions: [HubProviderSession] = []
        for (provider, identifiers) in providers {
            for (externalID, rounds) in identifiers {
                guard let first = rounds.first, let last = rounds.last else { continue }
                sessions.append(HubProviderSession(id: first.id, taskID: id, provider: provider, externalID: externalID,
                                                   attemptIDs: rounds.map(\.id), workspaceID: first.workspace?.id,
                                                   createdAt: first.startedAt, lastObservedAt: last.endedAt ?? last.startedAt))
            }
        }
        return sessions.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
}

public struct HubEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var sequence: Int64
    public var taskID: String
    public var attemptID: String?
    public var requirementRevision: Int
    public var planRevision: Int
    public var generation: Int
    public var createdAt: Date
    public var kind: String
    public var detail: String
}

public struct HubMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var sequence: Int64 = 0
    public var taskID: String
    public var sender: String
    public var recipient: String
    public var itemID: String?
    public var sessionID: String?
    public var text: String
    public var delivery: MessageDelivery = .queued
    public var requirementRevision: Int
    public var createdAt = Date()
    public init(id: String = UUID().uuidString, taskID: String, sender: String, recipient: String,
                text: String, requirementRevision: Int) {
        self.id = id
        self.taskID = taskID
        self.sender = sender
        self.recipient = recipient
        self.text = text
        self.requirementRevision = requirementRevision
    }
}
