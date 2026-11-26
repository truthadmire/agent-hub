import Foundation

public enum HubPresentation {
    public static func roleTitle(_ role: String) -> String {
        switch role {
        case "lead": return "负责人"
        case "frontend": return "前端"
        case "backend": return "后端"
        case "test": return "测试"
        case "review": return "审查"
        case "task": return "任务负责人"
        default: return role
        }
    }

    public static func verificationStateTitle(_ state: VerificationState) -> String {
        switch state {
        case .passed: return "已通过"
        case .failed: return "未通过"
        case .notRun: return "未运行"
        case .blocked: return "受阻"
        case .notApplicable: return "不适用"
        case .waived: return "已豁免"
        }
    }

    public static func attentionTitle(_ code: String) -> String {
        switch code {
        case "connection_required": return "请配置可用连接"
        case "role_unavailable": return "请为角色指定可用连接"
        case "resume_required", "interrupted": return "执行已中断，可从检查点继续"
        case "planning_question": return "请回答计划中的问题"
        case "manual_acceptance": return "请确认人工验收项"
        case "merge_conflict": return "请处理合并冲突"
        case "verification_blocked": return "验证受阻，请查看验证记录"
        case "verification_unstable": return "验证过程中源文件多次发生变化"
        case "time_budget": return "已用完任务时限"
        case "attempt_budget": return "已达到尝试次数上限"
        case "repair_budget": return "已达到修复次数上限"
        case "cost_threshold": return "请核对费用和支出上限"
        case "no_progress": return "多次修复后仍出现同一验证错误"
        case "invalid_plan": return "计划未通过校验"
        case "write_scope": return "有更改超出了分配的写入范围"
        case "checkpoint": return "无法保存工作树检查点"
        case "process_incomplete": return "子进程输出未收齐，请检查本次执行"
        case "authentication": return "连接身份验证失败"
        case "quota": return "服务额度受限"
        case "network": return "网络连接失败"
        case "permission": return "操作权限不足"
        case "protocolError": return "CLI 返回了无法识别的事件"
        case "incompatible": return "CLI 版本不兼容"
        case "waiting": return "CLI 正在等待输入"
        case "cancelled": return "执行已取消"
        case "execution", "execution_error": return "执行失败，请查看本次尝试的记录"
        case "runtime_error": return "任务调度失败，请查看工作区详情"
        default: return code
        }
    }

    /// Check names are durable identifiers. Localize the Hub's labels at display time.
    public static func verificationTitle(_ name: String) -> String {
        let baseline = "Baseline · "
        let manual = "Human · "
        if name.hasPrefix(manual) {
            return "人工验收 · " + name.dropFirst(manual.count)
        }
        let isBaseline = name.hasPrefix(baseline)
        let command = isBaseline ? String(name.dropFirst(baseline.count)) : name
        return (isBaseline ? "基线 · " : "") + commandTitle(command)
    }

    private static func commandTitle(_ name: String) -> String {
        switch name {
        case "Swift build": return "Swift 构建"
        case "Swift tests": return "Swift 测试"
        case "Cargo tests": return "Cargo 测试"
        case "Python unit tests": return "Python 单元测试"
        case "Python syntax": return "Python 语法检查"
        case "HTML entry and local assets": return "HTML 入口与本地资源"
        default:
            if name.hasPrefix("Check ") {
                let suffix = name.dropFirst("Check ".count)
                if let separator = suffix.range(of: " · "),
                   let index = Int(suffix[..<separator.lowerBound]), index > 0 {
                    return "检查 " + suffix
                }
            }
            return name
        }
    }
}
