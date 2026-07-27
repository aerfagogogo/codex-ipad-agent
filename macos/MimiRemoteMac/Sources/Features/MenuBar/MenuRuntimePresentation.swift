enum MenuRuntimePresentation {
    static func detailText(
        for runtime: AgentRuntimeStatus?,
        missingDetail: String
    ) -> String {
        guard let runtime else {
            return missingDetail
        }
        if runtime.reason == "refresh_in_progress" {
            return "正在后台获取连接与额度状态…"
        }
        // 认证类型与状态必须同时匹配，避免把其他已连接账户误显示成 API Key。
        let isConfiguredAPIKey = runtime.authMode == "api_key"
            && (runtime.state == .available || runtime.state == .connected)
        if isConfiguredAPIKey {
            return "API Key 已配置（按量计费），将在首次请求时验证有效性。"
        }
        if runtime.reason == "bedrock_credentials_configured_unverified" {
            return "Bedrock 凭据来源已配置，将在首次请求时验证有效性。"
        }
        if runtime.reason == "account_configured_unverified" {
            return "账户已配置，但尚未验证凭据是否有效。"
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
}
