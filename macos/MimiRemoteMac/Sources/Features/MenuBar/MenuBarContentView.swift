import AppKit
import SwiftUI

struct MenuBarContentView: View {
    let store: HostStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var confirmsQuit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuStatusHeader(
                lifecycle: store.lifecycle,
                isRefreshing: store.isRefreshingStatus || store.isBusy,
                refresh: refreshStatus
            )

            if let status = store.status {
                Divider()
                    .opacity(0.45)
                    .padding(.top, 11)

                MenuConnectionSummary(status: status, owner: store.owner)
                    .padding(.vertical, 9)

                Divider()
                    .opacity(0.45)

                MenuRuntimeSummary(
                    snapshot: status.runtimeStatus,
                    serviceAvailable: status.serviceOK,
                    owner: store.owner,
                    lifecycle: store.lifecycle
                )
                .padding(.vertical, 9)

                Divider()
                    .opacity(0.45)
            }

            if let lastError = store.lastError {
                MenuStatusMessage(message: lastError)
                    .padding(.top, 8)
            }

            if needsPrimaryAction {
                Button {
                    presentWindow(.dashboard)
                } label: {
                    Label(primaryActionTitle, systemImage: primaryActionSymbol)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 10)
            }

            VStack(spacing: 0) {
                MenuActionRow(
                    title: "配对设备…",
                    systemImage: "qrcode",
                    isEnabled: store.status != nil
                ) {
                    presentWindow(.pairing)
                    Task { await store.refreshPairing() }
                }

                Divider()
                    .opacity(0.4)
                    .padding(.leading, 34)

                MenuActionRow(
                    title: "运行诊断…",
                    systemImage: "stethoscope"
                ) {
                    presentWindow(.diagnostics)
                }

                Divider()
                    .opacity(0.4)
                    .padding(.leading, 34)

                MenuActionRow(
                    title: "设置",
                    systemImage: "gearshape"
                ) {
                    openSettings()
                    activateApplication()
                }

                if store.owner == .macApp {
                    Divider()
                        .opacity(0.4)
                        .padding(.leading, 34)

                    MenuActionRow(
                        title: "重新启动服务",
                        systemImage: "arrow.clockwise",
                        isEnabled: !store.isBusy,
                        showsDisclosure: false,
                        isWorking: store.isBusy
                    ) {
                        Task { await store.restartService() }
                    }
                }

                Divider()
                    .opacity(0.4)
                    .padding(.leading, 34)

                MenuActionRow(
                    title: "退出并停止服务…",
                    systemImage: "power",
                    isEnabled: !store.isBusy,
                    role: .destructive,
                    showsDisclosure: false
                ) {
                    confirmsQuit = true
                }
            }
            .padding(.top, 6)
        }
        .padding(12)
        .frame(width: 340)
        .background(MenuBarWindowPositionGuard())
        .animation(
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 1),
            value: store.lifecycle
        )
        .task {
            await store.refresh()
        }
        .alert("退出并停止 Mimi Remote Mac？", isPresented: $confirmsQuit) {
            Button("取消", role: .cancel) {}
            Button("退出并停止", role: .destructive) {
                Task { await store.stopServiceAndQuit() }
            }
        } message: {
            Text("这会立即中断 iPhone 和 iPad 的连接。下次打开 App 或重新登录 Mac 时会重新启动服务。")
        }
    }

    private func refreshStatus() {
        Task { await store.refresh() }
    }

    private func presentWindow(_ window: AppWindow) {
        openWindow(id: window.rawValue)
        activateApplication()
    }

    private func activateApplication() {
        // 菜单栏 App 是 LSUIElement，SwiftUI 只创建窗口时不会自动把进程切到前台。
        // 等本轮菜单跟踪结束后再激活，避免系统仍把焦点留在刚关闭的 MenuBarExtra 上。
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private var needsPrimaryAction: Bool {
        store.lifecycle == .notConfigured || store.lifecycle == .migrationRequired
    }

    private var primaryActionTitle: String {
        store.lifecycle == .notConfigured ? "完成首次设置…" : "迁移到 Mimi Remote Mac…"
    }

    private var primaryActionSymbol: String {
        store.lifecycle == .notConfigured ? "slider.horizontal.3" : "arrow.triangle.2.circlepath"
    }
}

private struct MenuStatusHeader: View {
    let lifecycle: HostLifecycleState
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))

                if lifecycle == .loading || lifecycle == .starting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(statusColor)
                } else {
                    Image(systemName: lifecycle.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button(action: refresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
            }
            .buttonStyle(MenuIconButtonStyle())
            .disabled(isRefreshing)
            .help("刷新服务状态")
            .accessibilityLabel("刷新服务状态")
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch lifecycle {
        case .loading: "正在检查 Mac 服务"
        case .notConfigured: "完成 Mac 端设置"
        case .migrationRequired: "Homebrew 服务正在运行"
        case .starting: "正在启动 Mimi Remote"
        case .ready: "Mimi Remote 已连接"
        case .degraded: "服务需要处理"
        case .stopped: "服务已停止"
        case .failed: "服务启动失败"
        }
    }

    private var subtitle: String {
        switch lifecycle {
        case .loading: "正在读取服务和连接状态。"
        case .notConfigured: "选择代码目录后即可配对移动设备。"
        case .migrationRequired: "可安全迁移，现有配置和配对都会保留。"
        case .starting: "移动设备连接会在服务就绪后自动恢复。"
        case .ready: "Mac 端服务运行正常。"
        case .degraded(let message), .failed(let message): message
        case .stopped: "打开 App 或重新登录后可以再次启动。"
        }
    }

    private var statusColor: Color {
        switch lifecycle {
        case .ready: .mimiPrimary
        case .loading, .starting: .blue
        case .notConfigured, .migrationRequired, .degraded: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

private struct MenuConnectionSummary: View {
    let status: AgentStatus
    let owner: ServiceOwner

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MenuMetadataRow(systemImage: "network") {
                Text(status.endpoint)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            MenuMetadataRow(systemImage: "shippingbox") {
                Text("agentd \(status.version) · \(status.projects) 个项目")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            MenuMetadataRow(systemImage: ownerSymbol) {
                Text(ownerTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ownerColor)
            }
        }
        .padding(.horizontal, 3)
        .accessibilityElement(children: .contain)
    }

    private var ownerTitle: String {
        switch owner {
        case .none: "未托管"
        case .macApp: "App 托管"
        case .homebrew: "Homebrew"
        }
    }

    private var ownerColor: Color {
        switch owner {
        case .none: .secondary
        case .macApp: .mimiPrimary
        case .homebrew: .orange
        }
    }

    private var ownerSymbol: String {
        switch owner {
        case .none: "questionmark.circle"
        case .macApp: "app.fill"
        case .homebrew: "shippingbox.fill"
        }
    }
}

private struct MenuMetadataRow<Content: View>: View {
    let systemImage: String
    @ViewBuilder let content: Content

    init(systemImage: String, @ViewBuilder content: () -> Content) {
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            content
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MenuRuntimeSummary: View {
    let snapshot: AgentRuntimeStatusSnapshot?
    let serviceAvailable: Bool
    let owner: ServiceOwner
    let lifecycle: HostLifecycleState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Text("AI 运行时")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)

                Spacer(minLength: 4)

                if snapshot?.refreshing == true {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("正在刷新运行时状态")
                }

                if let snapshotStatusText {
                    Text(snapshotStatusText)
                        .font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 3)

            MenuRuntimeRow(
                runtime: runtime(id: "codex"),
                fallbackTitle: "Codex",
                systemImage: "chevron.left.forwardslash.chevron.right",
                serviceAvailable: serviceAvailable,
                isRefreshing: snapshot?.refreshing == true,
                isStale: isStale,
                missingDetail: missingDetail
            )

            MenuRuntimeRow(
                runtime: runtime(id: "claude"),
                fallbackTitle: "Claude",
                systemImage: "sparkles",
                serviceAvailable: serviceAvailable,
                isRefreshing: snapshot?.refreshing == true,
                isStale: isStale,
                missingDetail: missingDetail
            )
        }
    }

    private func runtime(id: String) -> AgentRuntimeStatus? {
        snapshot?.runtimes.first { $0.id == id }
    }

    private var isStale: Bool {
        guard serviceAvailable, lifecycleAllowsFreshStatus else { return true }
        return snapshot?.isExpired() == true
    }

    private var lifecycleAllowsFreshStatus: Bool {
        switch lifecycle {
        case .ready, .migrationRequired:
            return true
        default:
            return false
        }
    }

    private var missingDetail: String {
        if owner == .homebrew {
            return "升级或迁移到新版 Mac App 后可显示运行时状态。"
        }
        if !serviceAvailable {
            return "Mac 服务不可用。"
        }
        return "运行时状态暂不可获取，请刷新或运行诊断。"
    }

    private var snapshotStatusText: String? {
        if snapshot?.refreshing == true {
            return snapshot?.checkedDate == nil ? "正在首次获取" : "后台刷新"
        }
        if isStale, snapshot != nil {
            return "状态可能已过期"
        }
        if let checkedDate = snapshot?.checkedDate {
            return "更新于 \(checkedDate.formatted(date: .omitted, time: .shortened))"
        }
        if owner == .homebrew {
            return "需要升级"
        }
        return nil
    }
}

private struct MenuRuntimeRow: View {
    let runtime: AgentRuntimeStatus?
    let fallbackTitle: String
    let systemImage: String
    let serviceAvailable: Bool
    let isRefreshing: Bool
    let isStale: Bool
    let missingDetail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(stateColor)
                .frame(width: 16, height: 19)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(runtime?.title ?? fallbackTitle)
                        .font(.callout.weight(.semibold))

                    Spacer(minLength: 4)

                    Circle()
                        .fill(stateColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)

                    Text(stateTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(stateColor)

                    if let accountLabel {
                        Text("· \(accountLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !usageWindows.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(usageWindows) { item in
                            MenuRuntimeQuotaWindow(item: item)
                        }
                    }
                }

                if let quotaNoticeText {
                    Text(quotaNoticeText)
                        .font(.caption2.weight(quotaIsExhausted ? .semibold : .regular))
                        .foregroundStyle(quotaIsExhausted ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let creditSummary {
                    Text(creditSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if usageWindows.isEmpty, quotaNoticeText == nil, creditSummary == nil {
                    Text(detailText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 3)
        .accessibilityElement(children: .contain)
    }

    private var usageWindows: [MenuRuntimeQuotaWindowItem] {
        guard let limits = runtime?.rateLimits else { return [] }
        let reached = limits.reachedType?.lowercased() ?? ""
        var result: [MenuRuntimeQuotaWindowItem] = []
        if let primary = limits.primary,
           primary.usedPercent != nil || primary.resetsAt != nil || primary.windowDurationMins != nil
        {
            result.append(MenuRuntimeQuotaWindowItem(
                id: "primary",
                window: primary,
                isExhausted: primary.isExhausted || reached.contains("primary")
            ))
        }
        if let secondary = limits.secondary,
           secondary.usedPercent != nil || secondary.resetsAt != nil || secondary.windowDurationMins != nil
        {
            result.append(MenuRuntimeQuotaWindowItem(
                id: "secondary",
                window: secondary,
                isExhausted: secondary.isExhausted || reached.contains("secondary")
            ))
        }
        return result
    }

    private var stateTitle: String {
        if runtime?.state == .disabled { return "未启用" }
        if isStale { return "状态已过期" }
        if isRefreshing, runtime?.reason == "refresh_in_progress" {
            return "正在刷新"
        }
        guard let runtime else {
            return serviceAvailable ? "状态未知" : "不可用"
        }
        switch runtime.state {
        case .connected: return "已连接"
        case .available: return "运行时可用"
        case .signedOut: return "未登录"
        case .disabled: return "未启用"
        case .unavailable: return "不可用"
        }
    }

    private var accountLabel: String? {
        if runtime?.authMode == "api_key" {
            return "API Key"
        }
        if let plan = runtime?.effectivePlanType {
            return formattedAccountValue(plan)
        }
        guard let authMode = runtime?.authMode else { return nil }
        switch authMode {
        case "api_key": return "API Key"
        case "chatgpt": return "ChatGPT"
        case "oauth": return "OAuth"
        case "bedrock": return "Bedrock"
        default: return formattedAccountValue(authMode)
        }
    }

    private var detailText: String {
        guard let runtime else {
            return missingDetail
        }
        if runtime.reason == "refresh_in_progress" {
            return "正在后台获取连接与额度状态…"
        }
        if runtime.authMode == "api_key",
           runtime.state == .available || runtime.state == .connected
        {
            return "API Key 已配置（按量计费），将在首次请求时验证有效性。"
        }
        switch runtime.state {
        case .disabled:
            return "可在设置中启用 Claude 实验通道。"
        case .signedOut:
            return "请在这台 Mac 上完成登录。"
        case .unavailable:
            return "运行时暂不可用，请刷新或运行诊断。"
        case .connected, .available:
            return "尚未获取到额度数据。"
        }
    }

    private var stateColor: Color {
        if runtime?.state == .disabled { return .secondary }
        if isStale { return .orange }
        if isRefreshing, runtime?.reason == "refresh_in_progress" {
            return .secondary
        }
        guard let runtime else {
            return serviceAvailable ? .secondary : .red
        }
        switch runtime.state {
        case .connected: return Color.mimiPrimary
        case .available: return Color.blue
        case .signedOut: return Color.orange
        case .disabled: return Color.secondary
        case .unavailable: return Color.red
        }
    }

    private var quotaIsExhausted: Bool {
        runtime?.rateLimits?.isExhausted == true
    }

    private var quotaNoticeText: String? {
        guard let limits = runtime?.rateLimits else { return nil }
        if limits.isExhausted {
            return "额度已耗尽，等待窗口重置。"
        }
        switch limits.availability?.lowercased() {
        case "partial":
            return "仅显示已观测到的额度窗口。"
        case "unavailable":
            return "额度暂不可获取。"
        default:
            return nil
        }
    }

    private var creditSummary: String? {
        guard runtime?.authMode != "api_key", let limits = runtime?.rateLimits else {
            return nil
        }
        if limits.creditsUnlimited == true {
            return "Credits 无限"
        }
        if let balance = limits.creditBalance?.trimmingCharacters(in: .whitespacesAndNewlines),
           !balance.isEmpty
        {
            return "Credits 余额 \(balance)"
        }
        if limits.hasCredits == false {
            return "Credits 未启用"
        }
        if limits.hasCredits == true {
            return "Credits 可用"
        }
        return nil
    }

    private func formattedAccountValue(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return raw }
        switch value.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        default: return value
        }
    }
}

private struct MenuRuntimeQuotaWindowItem: Identifiable {
    let id: String
    let window: AgentRuntimeRateLimitWindow
    let isExhausted: Bool
}

private struct MenuRuntimeQuotaWindow: View {
    let item: MenuRuntimeQuotaWindowItem

    private var window: AgentRuntimeRateLimitWindow {
        item.window
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.durationLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(valueText)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(item.isExhausted ? Color.red : Color.primary)
            }

            if item.isExhausted || window.remainingFraction != nil {
                let progress = item.isExhausted ? 0 : (window.remainingFraction ?? 0)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(item.isExhausted ? Color.red : progressColor(progress))
                    .accessibilityLabel("\(window.durationLabel)额度")
                    .accessibilityValue(valueText)
            }

            if let resetDate = window.resetDate {
                Text("\(resetText(resetDate)) 重置")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            item.isExhausted ? Color.red.opacity(0.07) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    private var valueText: String {
        if item.isExhausted { return "已耗尽" }
        return window.remainingPercentText.map { "剩余 \($0)" } ?? "等待刷新"
    }

    private func progressColor(_ remaining: Double) -> Color {
        if remaining <= 0.05 { return .red }
        if remaining <= 0.2 { return .orange }
        return .mimiPrimary
    }

    private func resetText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct MenuStatusMessage: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityLabel("注意：\(message)")
    }
}

private struct MenuActionRow: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    var role: ButtonRole?
    var showsDisclosure = true
    var isWorking = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(role == .destructive ? Color.mimiMutedDestructive : Color.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(role == .destructive ? Color.mimiMutedDestructive : Color.primary)
                Spacer(minLength: 0)
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 35, alignment: .leading)
            .background(
                Color.primary.opacity(isHovered ? 0.075 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct MenuPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 1),
                value: configuration.isPressed
            )
    }
}

private struct MenuIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(7)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.055), in: Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 1),
                value: configuration.isPressed
            )
    }
}

enum MenuBarWindowPlacement {
    static func correctedOriginY(
        windowFrame: CGRect,
        screenFrame: CGRect,
        menuBarHeight: CGFloat
    ) -> CGFloat {
        let highestAllowedOrigin = screenFrame.maxY - max(0, menuBarHeight) - windowFrame.height
        return min(windowFrame.minY, highestAllowedOrigin)
    }
}

private struct MenuBarWindowPositionGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MenuBarWindowProbeView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MenuBarWindowProbeView)?.scheduleAdjustment()
    }
}

private final class MenuBarWindowProbeView: NSView {
    private var adjustmentScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleAdjustment()
    }

    override func layout() {
        super.layout()
        scheduleAdjustment()
    }

    func scheduleAdjustment() {
        guard !adjustmentScheduled else { return }
        adjustmentScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.adjustmentScheduled = false
            self.keepWindowBelowMenuBar()
        }
    }

    private func keepWindowBelowMenuBar() {
        guard let window, let screen = window.screen else { return }

        let currentFrame = window.frame
        let correctedY = MenuBarWindowPlacement.correctedOriginY(
            windowFrame: currentFrame,
            screenFrame: screen.frame,
            menuBarHeight: inferredMenuBarHeight(for: screen)
        )
        guard correctedY < currentFrame.minY - 0.5 else { return }

        // 全屏空间会把隐藏状态栏的锚点放到屏幕顶端；只修正垂直越界，保留系统计算的水平锚点。
        var correctedFrame = currentFrame
        correctedFrame.origin.y = correctedY
        window.setFrame(correctedFrame, display: true, animate: false)
    }

    private func inferredMenuBarHeight(for screen: NSScreen) -> CGFloat {
        let targetInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let visibleMenuBarInset = NSScreen.screens
            .map { max(0, $0.frame.maxY - $0.visibleFrame.maxY) }
            .max() ?? 0

        return max(NSStatusBar.system.thickness, max(targetInset, visibleMenuBarInset))
    }
}

#if DEBUG
    #Preview("菜单栏 · 等待迁移") {
        MenuBarContentView(store: .preview(.migrationRequired))
    }

    #Preview("菜单栏 · 服务可用") {
        MenuBarContentView(store: .preview(.ready))
    }
#endif
