import Foundation

/// 从旧 MimiTag 任务岛保留下来的纯状态精华：跨 Runtime 去重，并把真正需要人处理的会话置顶。
/// 展示层只使用这份排序结果分组，不再叠加第二套仪表盘或重复会话卡。
struct TaskAttentionSnapshot: Equatable {
    enum State: Int, Equatable {
        case approval = 0
        case input = 1
        case failed = 2
        case running = 3
        case completed = 4
        case idle = 5

        var needsAttention: Bool {
            self == .approval || self == .input || self == .failed
        }
    }

    struct Item: Identifiable, Equatable {
        let session: AgentSession
        let state: State

        var id: SessionID { session.id }
    }

    let items: [Item]
    let attentionItems: [Item]
    let runningCount: Int
    let completedCount: Int

    init(sessions: [AgentSession]) {
        var newestByID: [SessionID: AgentSession] = [:]
        for session in sessions {
            guard let existing = newestByID[session.id] else {
                newestByID[session.id] = session
                continue
            }
            if SessionIndexStore.orderingDate(for: session) >= SessionIndexStore.orderingDate(for: existing) {
                newestByID[session.id] = session
            }
        }

        items = newestByID.values
            .map { Item(session: $0, state: Self.state(for: $0)) }
            .sorted(by: Self.precedes)
        attentionItems = items.filter(\.state.needsAttention)
        runningCount = items.filter { $0.state == .running }.count
        completedCount = items.filter { $0.state == .completed }.count
    }

    static func state(for session: AgentSession) -> State {
        if session.pendingApproval != nil || session.status == SessionStatus.waitingForApproval.rawValue {
            return .approval
        }
        if session.pendingUserInput != nil || session.status == SessionStatus.waitingForInput.rawValue {
            return .input
        }
        switch session.status {
        case SessionStatus.failed.rawValue:
            return .failed
        case SessionStatus.running.rawValue:
            return .running
        case SessionStatus.completed.rawValue, SessionStatus.closed.rawValue, SessionStatus.history.rawValue:
            return .completed
        default:
            return session.activeTurnID == nil ? .idle : .running
        }
    }

    private static func precedes(_ lhs: Item, _ rhs: Item) -> Bool {
        if lhs.state.rawValue != rhs.state.rawValue {
            return lhs.state.rawValue < rhs.state.rawValue
        }
        let lhsDate = SessionIndexStore.orderingDate(for: lhs.session)
        let rhsDate = SessionIndexStore.orderingDate(for: rhs.session)
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs.id < rhs.id
    }
}
