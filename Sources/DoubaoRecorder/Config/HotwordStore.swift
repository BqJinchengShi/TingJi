import Foundation

/// 热词列表持久化（~/Library/Application Support/DoubaoRecorder/hotwords.json）。
/// 转写时传给豆包 ASR 的 context 字段，提升专业术语/人名识别准确率。
enum HotwordStore {
    static var url: URL { ConfigStore.appSupportDir.appendingPathComponent("hotwords.json") }

    static func load() -> [String] {
        guard let data = try? Data(contentsOf: url),
              let words = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return words
    }

    static func save(_ words: [String]) throws {
        ConfigStore.ensureDir()
        let data = try JSONEncoder().encode(words)
        try data.write(to: url, options: .atomic)
    }

    /// 拼成豆包 ASR context 字段（JSON 字符串）：{"hotwords":[{"word":"..."}]}
    static func contextJSON() -> String? {
        let words = load()
        guard !words.isEmpty else { return nil }
        let json: [String: Any] = ["hotwords": words.map { ["word": $0] }]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}
