import Foundation

/// 转写服务：分别转写 system+mic，按 (来源, speaker) 统一编号合并，输出字幕。
/// GUI（RecordingManager）和 CLI（App.swift）共用。
enum TranscriptionService {
    /// progress 回调用于报告步骤进度（CLI 打印、GUI 更新状态）。
    static func transcribe(dir: URL, baseTime: Date? = nil,
                           progress: ((String) -> Void)? = nil) async throws -> AsrResult {
        let systemWav = dir.appendingPathComponent("system.wav")
        let micWav = dir.appendingPathComponent("mic.wav")
        let config = try AppConfig.load()
        let uploader = TosUploader(config: config)
        let asr = AsrClient(config: config)

        progress?("转写系统音频...")
        let systemResult = try await transcribeOne(wav: systemWav, name: "system", dir: dir,
                                                    uploader: uploader, asr: asr)
        progress?("转写麦克风...")
        let micResult = try await transcribeOne(wav: micWav, name: "mic", dir: dir,
                                                 uploader: uploader, asr: asr)

        // 合并：按时间排序，(来源, ASR speaker) 组合统一编号。
        var all: [(String, Utterance)] = []
        for u in systemResult.utterances { all.append(("system", u)) }
        for u in micResult.utterances { all.append(("mic", u)) }
        all.sort { ($0.1.startTime ?? 0) < ($1.1.startTime ?? 0) }

        var speakerMap: [String: String] = [:]
        var nextId = 1
        var merged: [Utterance] = []
        for (source, u) in all {
            let key = "\(source)-\(u.speaker ?? "?")"
            let label: String
            if let l = speakerMap[key] {
                label = l
            } else {
                label = "说话人\(nextId)"
                speakerMap[key] = label
                nextId += 1
            }
            merged.append(Utterance(text: u.text, startTime: u.startTime, endTime: u.endTime, speaker: label))
        }

        let combined = AsrResult(
            text: systemResult.text + " " + micResult.text,
            utterances: merged,
            duration: micResult.duration
        )

        let base = baseTime ?? readBaseTime(dir) ?? fileModDate(systemWav)
        _ = try TranscriptWriter.write(combined, to: dir, baseTime: base)
        progress?("大模型优化中...")
        await optimizeWithLLMIfNeeded(dir: dir)
        return combined
    }

    /// 单文件转写（上传的音频，不分 system/mic）。speaker 直接用 ASR 的，加"说话人"前缀。
    static func transcribeSingle(audioURL: URL, format: String, rate: Int,
                                 dir: URL, baseTime: Date?,
                                 progress: ((String) -> Void)? = nil) async throws -> AsrResult {
        let config = try AppConfig.load()
        let asr = AsrClient(config: config)
        progress?("转写中...")
        let result = try await asr.transcribe(audioURL: audioURL, format: format, rate: rate)
        let combined = AsrResult(
            text: result.text,
            utterances: result.utterances.map {
                Utterance(text: $0.text, startTime: $0.startTime, endTime: $0.endTime,
                          speaker: $0.speaker.map { "说话人\($0)" })
            },
            duration: result.duration
        )
        let base = baseTime ?? Date()
        _ = try TranscriptWriter.write(combined, to: dir, baseTime: base)
        progress?("大模型优化中...")
        await optimizeWithLLMIfNeeded(dir: dir)
        return combined
    }

    /// 若开启大模型优化且配置了 ARK 凭据，调豆包大模型优化 transcript.txt（覆盖）。
    static func optimizeWithLLMIfNeeded(dir: URL) async {
        let cfg = ConfigStore.load()
        guard cfg["LLM_OPTIMIZE"] != "false",
              let apiKey = cfg["ARK_API_KEY"], !apiKey.isEmpty,
              let model = cfg["ARK_MODEL"], !model.isEmpty else { return }
        let transcriptURL = dir.appendingPathComponent("transcript.txt")
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8), !text.isEmpty else { return }
        do {
            let optimized = try await LLMClient(apiKey: apiKey, model: model).optimize(text, hotwords: HotwordStore.load())
            try optimized.write(to: transcriptURL, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("[TingJi] LLM 优化失败: \(error.localizedDescription)\n".utf8))
        }
    }

    static func transcribeOne(wav: URL, name: String, dir: URL,
                               uploader: TosUploader, asr: AsrClient) async throws -> AsrResult {
        let encDir = dir.appendingPathComponent("\(name)_enc")
        try? FileManager.default.createDirectory(at: encDir, withIntermediateDirectories: true)
        let enc = try AudioEncoder.encode(wav: wav, outputDir: encDir)
        let (audioURL, _) = try await uploader.upload(enc.url)
        return try await asr.transcribe(audioURL: audioURL, format: enc.format, rate: enc.rate)
    }

    /// 读 meta.json 的录音开始时间。
    static func readBaseTime(_ dir: URL) -> Date? {
        let metaURL = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let start = json["start"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: start)
    }

    /// 文件修改时间（作为录音开始时间的兜底）。
    static func fileModDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
