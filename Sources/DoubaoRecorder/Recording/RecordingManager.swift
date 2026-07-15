import Foundation

/// 录音 + 转写编排（GUI 用）。@Observable 供 SwiftUI 绑定。
/// 录音状态用 state/statusText；上传转写状态写进对应 RecordingItem.status，两者互不干扰。
@Observable
final class RecordingManager {
    static let shared = RecordingManager()
    enum State { case idle, recording, transcribing, done }
    var state: State = .idle
    var statusText: String = ""
    var recordings: [RecordingItem] = []
    var elapsed: Int = 0  // 录音已录秒数（实时）

    private var engine: RecorderEngine?
    private var currentDir: URL?
    private var currentId: UUID?
    private var startTime: Date?
    private var timer: Task<Void, Never>?

    init() { reload() }

    func reload() { recordings = RecordingStore.list() }

    func startRecording() async {
        guard state == .idle || state == .done else { return }
        let id = UUID()
        let dir = RecordingStore.dir(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        currentId = id
        currentDir = dir
        startTime = Date()
        elapsed = 0

        let meta = ["start": ISO8601DateFormatter().string(from: startTime!)]
        if let data = try? JSONSerialization.data(withJSONObject: meta) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
        var item = RecordingItem(id: id, startTime: startTime!, duration: nil, summary: "", title: nil, status: .recording)
        try? RecordingStore.saveMeta(item)
        reload()

        let engine = RecorderEngine()
        self.engine = engine
        state = .recording
        statusText = "录音中"
        let start = startTime!
        timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.elapsed = Int(Date().timeIntervalSince(start))
            }
        }
        do {
            _ = try await engine.start(outputDir: dir)
        } catch {
            timer?.cancel(); timer = nil
            statusText = "录音失败: \(error.localizedDescription)"
            state = .idle
            self.engine = nil
            item.status = .failed
            try? RecordingStore.saveMeta(item)
            reload()
        }
    }

    func stopRecording() async {
        guard state == .recording, let engine, let dir = currentDir, let start = startTime, let id = currentId else { return }
        timer?.cancel(); timer = nil
        await engine.stop()
        self.engine = nil
        let duration = elapsed

        try? AudioMixer.mix(system: dir.appendingPathComponent("system.wav"),
                            mic: dir.appendingPathComponent("mic.wav"),
                            output: dir.appendingPathComponent("mixed.wav"))

        state = .transcribing
        statusText = "转写中..."
        var item = RecordingItem(id: id, startTime: start, duration: duration, summary: "", title: nil, status: .transcribing)
        try? RecordingStore.saveMeta(item)
        reload()

        do {
            _ = try await TranscriptionService.transcribe(dir: dir, baseTime: start) { step in
                self.statusText = step
            }
            let transcriptURL = dir.appendingPathComponent("transcript.txt")
            let text = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
            item.summary = String(text.prefix(100))
            item.status = .done
            try? RecordingStore.saveMeta(item)
            saveToCustomPathIfNeeded(title: displayTitle(item), transcriptURL: transcriptURL)
            statusText = "转写完成"
        } catch {
            item.status = .failed
            try? RecordingStore.saveMeta(item)
            statusText = "转写失败: \(error.localizedDescription)"
        }
        state = .done
        reload()
    }

    /// 上传本地音频转写（异步，不耽误录音）。状态写进 item.status，列表实时显示。
    func uploadAndTranscribe(url: URL) async {
        let id = UUID()
        let dir = RecordingStore.dir(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let start = Date()

        // 复制原文件到 dir/mixed.<ext> 供播放/下载
        let ext = url.pathExtension.lowercased()
        let mixed = dir.appendingPathComponent("mixed.\(ext.isEmpty ? "wav" : ext)")
        try? FileManager.default.copyItem(at: url, to: mixed)

        var item = RecordingItem(id: id, startTime: start, duration: nil, summary: "",
                                  title: url.deletingPathExtension().lastPathComponent, status: .uploading)
        try? RecordingStore.saveMeta(item)
        reload()

        do {
            let config = try AppConfig.load()
            let uploader = TosUploader(config: config)
            let (audioURL, tosKey) = try await uploader.upload(mixed)
            item.tosKey = tosKey
            item.status = .transcribing
            try? RecordingStore.saveMeta(item)
            reload()

            let format = ext.isEmpty ? "wav" : ext
            _ = try await TranscriptionService.transcribeSingle(audioURL: audioURL, format: format, rate: 16000,
                                                                dir: dir, baseTime: start) { _ in }
            let transcriptURL = dir.appendingPathComponent("transcript.txt")
            let text = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
            item.summary = String(text.prefix(100))
            item.duration = nil
            item.status = .done
            try? RecordingStore.saveMeta(item)
            saveToCustomPathIfNeeded(title: displayTitle(item), transcriptURL: transcriptURL)
        } catch {
            item.status = .failed
            try? RecordingStore.saveMeta(item)
        }
        reload()
    }

    func rename(_ item: RecordingItem, to title: String) {
        let oldTitle = displayTitle(item)
        var item = item
        item.title = title.isEmpty ? nil : title
        let newTitle = displayTitle(item)
        try? RecordingStore.saveMeta(item)

        // 同步自定义路径 txt（删旧建新）
        let path = ConfigStore.load()["TRANSCRIPT_SAVE_PATH"] ?? ""
        if !path.isEmpty {
            let dir = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sanitize(oldTitle)).txt"))
            let transcriptURL = RecordingStore.dir(for: item.id).appendingPathComponent("transcript.txt")
            saveToCustomPathIfNeeded(title: newTitle, transcriptURL: transcriptURL)
        }

        // 同步 TOS 桶文件名（copy 到新 key + delete 旧 key）
        if let tosKey = item.tosKey {
            let ext = (tosKey as NSString).pathExtension
            let newKey = "doubao-recorder/\(sanitize(newTitle)).\(ext)"
            Task {
                if let config = try? AppConfig.load() {
                    let uploader = TosUploader(config: config)
                    try? await uploader.copyObject(srcKey: tosKey, destKey: newKey)
                    try? await uploader.deleteObject(key: tosKey)
                }
                var updated = item
                updated.tosKey = newKey
                try? RecordingStore.saveMeta(updated)
                await MainActor.run { self.reload() }
            }
        }
        reload()
    }

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    func delete(_ item: RecordingItem) {
        let dir = RecordingStore.dir(for: item.id)
        // 同步删除云端 TOS 文件，避免占用空间
        if let tosKey = item.tosKey {
            Task {
                if let config = try? AppConfig.load() {
                    let uploader = TosUploader(config: config)
                    try? await uploader.deleteObject(key: tosKey)
                }
            }
        }
        try? FileManager.default.removeItem(at: dir)
        reload()
    }

    private func displayTitle(_ item: RecordingItem) -> String {
        item.title ?? item.startTime.formatted(date: .abbreviated, time: .shortened)
    }

    /// 若配置了 TRANSCRIPT_SAVE_PATH，把 transcript.txt 复制到该目录（按标题命名）。
    private func saveToCustomPathIfNeeded(title: String, transcriptURL: URL) {
        let path = ConfigStore.load()["TRANSCRIPT_SAVE_PATH"] ?? ""
        guard !path.isEmpty else { return }
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = title.replacingOccurrences(of: "/", with: "-")
        let dest = dir.appendingPathComponent("\(safe).txt")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: transcriptURL, to: dest)
    }
}
