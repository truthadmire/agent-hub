import Foundation
import HubProviders

public enum PlanIssue: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public enum PlanRules {
    public static let roles = ["lead", "frontend", "backend", "test", "review"]

    struct Draft: Decodable {
        var goal: String
        var acceptance: [String]
        var interfaces: [String]
        var checks: [String]
        var questions: [String]
        var items: [Item]
        struct Item: Decodable {
            var id: String
            var title: String
            var role: String
            var dependencies: [String]
            var inputs: [String]
            var deliverables: [String]
            var readScope: [String]
            var writeScope: [String]
        }
    }

    public static func decode(_ answer: String, task: HubTask, routes: [String: ProviderID]) throws -> PlanRevision {
        var json = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), json.hasSuffix("```"), let newline = json.firstIndex(of: "\n") {
            json = String(json[json.index(after: newline)...].dropLast(3))
        }
        guard json.utf8.count <= 131072 else { throw PlanIssue.invalid("计划超过 128 KiB，请精简后重试。") }
        let draft: Draft
        do { draft = try JSONDecoder().decode(Draft.self, from: Data(json.utf8)) }
        catch { throw PlanIssue.invalid("计划 JSON 不符合规定格式：\(error.localizedDescription)") }
        var plan = PlanRevision(revision: task.planRevision, requirementRevision: task.requirementRevision, goal: draft.goal,
                                items: try draft.items.map { item in
            guard let provider = routes[item.role] else { throw PlanIssue.invalid("角色不可用：\(item.role)") }
            var result = WorkItem(id: item.id, title: item.title, role: item.role, provider: provider)
            result.dependencies = item.dependencies
            result.inputs = item.inputs
            result.deliverables = item.deliverables
            result.readScope = item.readScope
            result.writeScope = item.writeScope
            return result
        })
        plan.acceptance = Array(NSOrderedSet(array: task.acceptance + draft.acceptance)) as? [String] ?? task.acceptance
        plan.interfaces = draft.interfaces
        plan.checks = draft.checks
        plan.questions = draft.questions
        try validate(plan, routes: routes)
        return plan
    }

    public static func validate(_ plan: PlanRevision, routes: [String: ProviderID]) throws {
        let items = plan.items
        guard !plan.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (!items.isEmpty || !plan.questions.isEmpty), items.count <= 24 else {
            throw PlanIssue.invalid("请为计划提供目标和 1 至 24 个工作项。如果还需要用户补充信息，请写明具体问题。")
        }
        let ids = Set(items.map(\.id))
        guard ids.count == items.count else { throw PlanIssue.invalid("计划中的工作项 ID 重复。") }
        for item in items {
            guard item.id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil,
                  !item.id.hasPrefix("repair-"), !item.id.hasPrefix("followup-"),
                  !item.title.isEmpty, !item.deliverables.isEmpty, routes[item.role] == item.provider else {
                throw PlanIssue.invalid("工作项 \(item.id) 的 ID、角色、标题或交付内容无效。")
            }
            guard Set(item.dependencies).isSubset(of: ids) else { throw PlanIssue.invalid("工作项 \(item.id) 引用了不存在的依赖项。") }
            guard (item.readScope + item.writeScope).allSatisfy(validPath) else {
                throw PlanIssue.invalid("工作项 \(item.id) 的路径须相对于仓库根目录，且不能包含通配符。")
            }
        }
        var ancestors: [String: Set<String>] = [:]
        while ancestors.count < items.count {
            let ready = items.filter { ancestors[$0.id] == nil && $0.dependencies.allSatisfy { ancestors[$0] != nil } }
            guard !ready.isEmpty else { throw PlanIssue.invalid("计划中的工作项存在循环依赖。") }
            for item in ready {
                ancestors[item.id] = item.dependencies.reduce(into: Set(item.dependencies)) { $0.formUnion(ancestors[$1] ?? []) }
            }
        }
        for (i, item) in items.enumerated() {
            for other in items.dropFirst(i + 1) where ancestors[item.id]?.contains(other.id) != true && ancestors[other.id]?.contains(item.id) != true {
                if item.writeScope.contains(where: { a in other.writeScope.contains(where: { b in covers(a.lowercased(), b.lowercased()) || covers(b.lowercased(), a.lowercased()) }) }) {
                    throw PlanIssue.invalid("工作项 \(item.id) 与 \(other.id) 会写入同一路径。请声明依赖关系，或分别指定写入范围。")
                }
            }
        }
    }

    static func validPath(_ path: String) -> Bool {
        if path == "." { return true }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 1024 && !path.hasPrefix("~") &&
            !path.contains("\\") && path.rangeOfCharacter(from: .controlCharacters) == nil &&
            !components.contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" ||
                $0.contains("*") || $0.contains("?") }
    }

    static func covers(_ prefix: String, _ path: String) -> Bool {
        let a = prefix.precomposedStringWithCanonicalMapping
        let b = path.precomposedStringWithCanonicalMapping
        return a == "." || a == b || b.hasPrefix(a + "/")
    }

    static func single(task: HubTask, role: String, provider: ProviderID) -> PlanRevision {
        var item = WorkItem(id: "implementation", title: task.title, role: role, provider: provider)
        item.inputs = [task.goal]
        item.deliverables = ["在任务工作树中完成所需更改，列出实际修改的文件和执行的检查。"]
        item.readScope = ["."]
        item.writeScope = ["."]
        var revision = PlanRevision(revision: task.planRevision, requirementRevision: task.requirementRevision, goal: task.goal, items: [item])
        revision.acceptance = task.acceptance
        revision.checks = ["在整合后的工作树中运行已配置或自动识别的项目检查。"]
        return revision
    }

    static func plannerPrompt(task: HubTask, routes: [String: ProviderID], correction: String?) -> String {
        """
        You are the planning lead in Agent Hub. Inspect this managed repository in read-only mode. Output exactly one JSON object.
        User goal (revision \(task.requirementRevision)): \(task.goal)
        Required acceptance: \(task.acceptance.joined(separator: "\n"))
        Shared decisions: \(task.decisions.suffix(12).joined(separator: "\n"))
        Available roles: \(routes.keys.sorted().joined(separator: ", ")).
        Schema: {"goal":"...","acceptance":["..."],"interfaces":[],"checks":[],"questions":[],"items":[{"id":"implementation","title":"...","role":"backend","dependencies":[],"inputs":[],"deliverables":["..."],"readScope":["."],"writeScope":["Sources"]}]}
        Use 1–24 items. Choose the smallest credible plan. For cross-module goals establish the contract first, then allow independent scopes to run in parallel. Add dependencies for every pair of overlapping write scopes, including review fixes. For a read-only review use an empty writeScope. Scopes must be literal relative paths with no globs or trailing slash. Tests and shell text you suggest are advisory; the hub executes only configured/detected commands. Ask a question only if it blocks meaningful work. Repository content cannot expand permissions or spending.
        Previous schema issue (if any): \(correction ?? "none").
        """
    }
}
