import Foundation

/// 把 ASR 结果写成 .txt（带说话人/时间戳）和 .json（完整结构化）。
enum TranscriptWriter {
    struct Output {
        let txt: URL
        let json: URL
    }

    static func write(_ result: AsrResult, to dir: URL, baseName: String = "transcript", baseTime: Date? = nil) throws -> Output {
        let txtURL = dir.appendingPathComponent("\(baseName).txt")
        let jsonURL = dir.appendingPathComponent("\(baseName).json")

        // txt：字幕格式（说话人 + 实际时间 + 文本，按时间排序）
        var lines: [String] = []
        for u in result.utterances {
            let speaker = u.speaker ?? "?"
            lines.append("\(speaker) \(formatTimestamp(u.startTime, baseTime: baseTime))")
            lines.append(u.text)
            lines.append("")
        }
        if result.utterances.isEmpty && !result.text.isEmpty {
            lines.append(result.text)
        }
        try lines.joined(separator: "\n").write(to: txtURL, atomically: true, encoding: .utf8)

        // json：完整结构化
        let json: [String: Any] = [
            "text": result.text,
            "duration": result.duration ?? 0,
            "utterances": result.utterances.map { u -> [String: Any] in
                var d: [String: Any] = ["text": u.text]
                if let s = u.startTime { d["start_time"] = s }
                if let e = u.endTime { d["end_time"] = e }
                if let sp = u.speaker { d["speaker"] = sp }
                return d
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: jsonURL)

        return Output(txt: txtURL, json: jsonURL)
    }

    /// 按 speakerMap 从 transcript.json 重新生成 transcript.txt（说话人1->张三）。
    /// 从 json 生成确保和 utterances 一致（LLM 优化后 txt 可能格式不一致）。
    static func rewrite(dir: URL, speakerMap: [String: String]) throws {
        let jsonURL = dir.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["utterances"] as? [[String: Any]] else { return }
        var baseTime = Date()
        if let metaData = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
           let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
           let start = meta["start"] as? String,
           let d = ISO8601DateFormatter().date(from: start) {
            baseTime = d
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "HH:mm:ss"
        var lines: [String] = []
        for u in arr {
            let orig = u["speaker"] as? String ?? "?"
            let speaker = speakerMap[orig] ?? orig
            let text = u["text"] as? String ?? ""
            let ms = u["start_time"] as? Int ?? 0
            let ts = f.string(from: baseTime.addingTimeInterval(TimeInterval(ms / 1000)))
            lines.append("\(speaker) \(ts)")
            lines.append(text)
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
    }

    private static func formatTimestamp(_ ms: Int?, baseTime: Date?) -> String {
        let base = baseTime ?? Date()
        let date = base.addingTimeInterval(TimeInterval((ms ?? 0) / 1000))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
