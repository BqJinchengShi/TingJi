import Foundation

/// 一条历史录音的元数据（持久化在 recordings/<uuid>/meta.json）。
enum RecordingStatus: String, Codable { case recording, uploading, transcribing, done, failed }

struct RecordingItem: Identifiable, Codable {
    let id: UUID
    let startTime: Date
    var duration: Int?      // 秒
    var summary: String     // 转写摘要（前 100 字）
    var title: String?      // 用户自定义标题；nil 时显示开始时间
    var status: RecordingStatus?  // nil 视为 done（旧记录兼容）
    var tosKey: String?     // TOS 桶音频文件 key（rename 同步用）
    var speakerMap: [String: String]?  // 说话人1->张三（试听时批量替换）
}

/// 扫描/管理 ~/Library/Application Support/DoubaoRecorder/recordings/
enum RecordingStore {
    static var recordingsDir: URL {
        ConfigStore.appSupportDir.appendingPathComponent("recordings", isDirectory: true)
    }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
    }

    static func dir(for id: UUID) -> URL {
        recordingsDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// 列出所有历史录音，按开始时间倒序。
    static func list() -> [RecordingItem] {
        ensureDir()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: recordingsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var items: [RecordingItem] = []
        for d in entries where (try? d.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let metaURL = d.appendingPathComponent("meta.json")
            if let data = try? Data(contentsOf: metaURL),
               let item = try? JSONDecoder().decode(RecordingItem.self, from: data) {
                items.append(item)
            }
        }
        return items.sorted { $0.startTime > $1.startTime }
    }

    static func saveMeta(_ item: RecordingItem) throws {
        let dir = dir(for: item.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(item)
        try data.write(to: dir.appendingPathComponent("meta.json"))
    }
}
