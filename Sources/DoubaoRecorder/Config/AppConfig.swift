import Foundation

/// 集中读取环境变量与 .env 配置。密钥绝不硬编码，适合开源。
///
/// 查找顺序：进程环境变量优先，缺失时回落到 .env 文件（CWD 或可执行文件向上查找）。
struct AppConfig {
    // MARK: ASR 鉴权（新版 / 旧版二选一）
    /// 新版控制台 X-Api-Key
    let doubaoApiKey: String?
    /// 旧版控制台 X-Api-App-Key（APP ID）
    let doubaoAppId: String?
    /// 旧版控制台 X-Api-Access-Key（Access Token）
    let doubaoAccessToken: String?

    // MARK: TOS 对象存储
    let tosAccessKey: String
    let tosSecretKey: String
    let tosBucket: String
    let tosRegion: String
    let tosEndpoint: String

    // MARK: 其他
    /// 提交 ASR 时的 user.uid
    let uid: String

    /// 是否用新版鉴权
    var useNewAuth: Bool { doubaoApiKey != nil }

    static func load() throws -> AppConfig {
        // 优先 config.json（GUI 写），回落 .env（CLI 兼容），最后环境变量
        var env = ConfigStore.load()
        for (k, v) in mergedEnvironment() where env[k] == nil { env[k] = v }
        for (k, v) in ProcessInfo.processInfo.environment where env[k] == nil { env[k] = v }

        let apiKey = env["DOUBAO_API_KEY"]?.nonEmpty
        let appId = env["DOUBAO_APP_ID"]?.nonEmpty
        let accessToken = env["DOUBAO_ACCESS_TOKEN"]?.nonEmpty

        // ASR 鉴权：新版或旧版至少一组
        if apiKey == nil && (appId == nil || accessToken == nil) {
            throw ConfigError.missingAsrAuth
        }

        guard let tosAk = env["TOS_AK"]?.nonEmpty,
              let tosSk = env["TOS_SK"]?.nonEmpty,
              let tosBucket = env["TOS_BUCKET"]?.nonEmpty,
              let tosRegion = env["TOS_REGION"]?.nonEmpty,
              let tosEndpoint = env["TOS_ENDPOINT"]?.nonEmpty else {
            throw ConfigError.missingTos
        }

        let uid = env["DOUBAO_UID"]?.nonEmpty ?? "doubao-recorder"

        return AppConfig(
            doubaoApiKey: apiKey,
            doubaoAppId: appId,
            doubaoAccessToken: accessToken,
            tosAccessKey: tosAk,
            tosSecretKey: tosSk,
            tosBucket: tosBucket,
            tosRegion: tosRegion,
            tosEndpoint: tosEndpoint,
            uid: uid
        )
    }

    // MARK: - .env 解析

    /// 合并进程环境变量与 .env 文件（环境变量优先）。
    private static func mergedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        guard let envURL = findEnvFile(),
              let content = try? String(contentsOf: envURL, encoding: .utf8) else {
            return env
        }
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2)
                || (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
            }
            if env[key] == nil { env[key] = value }
        }
        return env
    }

    /// 查找 .env：CWD 优先，再从可执行文件目录向上找最多 5 级。
    private static func findEnvFile() -> URL? {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".env")
        if fm.fileExists(atPath: cwd.path) { return cwd }

        let exe = CommandLine.arguments.first ?? fm.currentDirectoryPath
        var dir = URL(fileURLWithPath: exe).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent(".env")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

enum ConfigError: LocalizedError {
    case missingAsrAuth
    case missingTos

    var errorDescription: String? {
        switch self {
        case .missingAsrAuth:
            return "缺少 ASR 鉴权配置：请在 .env 设置 DOUBAO_API_KEY（新版）或 DOUBAO_APP_ID+DOUBAO_ACCESS_TOKEN（旧版）。"
        case .missingTos:
            return "缺少 TOS 配置：请在 .env 设置 TOS_AK / TOS_SK / TOS_BUCKET / TOS_REGION / TOS_ENDPOINT。"
        }
    }
}

private extension String {
    /// 去掉首尾空白后若为空则返回 nil。
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
