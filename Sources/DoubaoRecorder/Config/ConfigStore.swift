import Foundation

/// 管理 ~/Library/Application Support/DoubaoRecorder/config.json
///
/// GUI 配置页写入；AppConfig.load 优先读取。明文本地存储。
enum ConfigStore {
    static let appSupportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("DoubaoRecorder", isDirectory: true)

    static var configURL: URL { appSupportDir.appendingPathComponent("config.json") }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }

    /// 读 config.json 为键值字典；不存在或解析失败返回空。
    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }

    /// 写 config.json（原子写）。
    static func save(_ config: [String: String]) throws {
        ensureDir()
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
    }
}
