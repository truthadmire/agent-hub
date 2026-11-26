import Foundation

public struct GitChange: Codable, Equatable, Sendable {
    /// Two-column Git porcelain code, including the index and worktree columns.
    public let code: String
    public let path: String
    public let originalPath: String?
}

public struct GitProject: Codable, Equatable, Sendable {
    public let id: String
    public let path: URL
    public let branch: String?
    public let head: String
    public let changes: [GitChange]
    public let technologies: [String]
}

public enum GitWorkspaceKind: String, Codable, Sendable { case task, attempt }

public struct GitWorkspace: Codable, Equatable, Sendable {
    public let id: UUID
    public let project: GitProject
    public let path: URL
    public let branch: String
    public let baseline: String
    public let taskID: UUID
    public let kind: GitWorkspaceKind
}

public enum GitIntegration: Equatable, Sendable {
    case integrated(String)
    case conflict([String])
}

public struct GitSnapshotPreview: Sendable {
    public let tree: String
    public let patch: Data
    public let excludedPaths: [String]
}

public enum GitWorkspaceError: LocalizedError, Equatable {
    case operation(String)
    public var errorDescription: String? {
        switch self { case let .operation(message): return message }
    }
}
