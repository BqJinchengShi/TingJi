import Foundation

/// 豆包录音文件识别（离线 ASR）客户端：提交任务 + 轮询查询。
///
/// 文档：火山引擎「大模型录音文件识别」。流程为异步--提交拿 task_id，轮询 query 直到成功。
final class AsrClient {
    static let submitURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit")!
    static let queryURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query")!
    static let resourceId = "volc.seedasr.auc"

    let config: AppConfig
    let pollInterval: TimeInterval
    let maxPolls: Int

    init(config: AppConfig, pollInterval: TimeInterval = 5, maxPolls: Int = 360) {
        self.config = config
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
    }

    /// 端到端：提交 + 轮询，返回转写结果。
    func transcribe(audioURL: URL, format: String, rate: Int) async throws -> AsrResult {
        let taskID = try await submit(audioURL: audioURL, format: format, rate: rate)
        return try await poll(taskID: taskID)
    }

    // MARK: - 提交任务

    func submit(audioURL: URL, format: String, rate: Int) async throws -> String {
        let taskID = UUID().uuidString
        var request = URLRequest(url: Self.submitURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.setValue(Self.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(taskID, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")

        var requestBody: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "enable_speaker_info": true,
            "show_utterances": true,
            "ssd_version": "200",
        ]
        if let context = HotwordStore.contextJSON() {
            requestBody["context"] = context  // 热词直传，提升专业术语识别
        }
        let body: [String: Any] = [
            "user": ["uid": config.uid],
            "audio": [
                "format": format,
                "url": audioURL.absoluteString,
                "rate": rate,
                "channel": 1,
            ],
            "request": requestBody,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AsrError.badResponse }
        let code = http.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
        let msg = http.value(forHTTPHeaderField: "X-Api-Message") ?? ""
        guard code == "20000000" else { throw AsrError.submitFailed(code, msg) }
        return taskID
    }

    // MARK: - 查询轮询

    func poll(taskID: String) async throws -> AsrResult {
        for _ in 0..<maxPolls {
            let (result, done) = try await query(taskID: taskID)
            if done, let result { return result }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw AsrError.timeout
    }

    func query(taskID: String) async throws -> (AsrResult?, Bool) {
        var request = URLRequest(url: Self.queryURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.setValue(Self.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(taskID, forHTTPHeaderField: "X-Api-Request-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: [String: Any]())

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AsrError.badResponse }
        let code = http.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
        if code == "20000000" { return (try Self.parse(data: data), true) }
        if code == "20000003" { return (AsrResult(text: "", utterances: [], duration: nil), true) }  // 静音音频，无文字
        if code == "20000001" || code == "20000002" { return (nil, false) }  // 处理中 / 排队
        let msg = http.value(forHTTPHeaderField: "X-Api-Message") ?? ""
        throw AsrError.queryFailed(code, msg)
    }

    // MARK: - 鉴权（新版 / 旧版）

    private func applyAuth(to request: inout URLRequest) {
        if let apiKey = config.doubaoApiKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        } else {
            request.setValue(config.doubaoAppId, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(config.doubaoAccessToken, forHTTPHeaderField: "X-Api-Access-Key")
        }
    }

    // MARK: - 结果解析

    private static func parse(data: Data) throws -> AsrResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            throw AsrError.parseFailed
        }
        let text = result["text"] as? String ?? ""
        var utterances: [Utterance] = []
        if let arr = result["utterances"] as? [[String: Any]] {
            for u in arr {
                utterances.append(Utterance(
                    text: u["text"] as? String ?? "",
                    startTime: u["start_time"] as? Int,
                    endTime: u["end_time"] as? Int,
                    // 说话人字段在 additions.speaker（实测确认）。
                    speaker: (u["speaker"] as? String) ?? ((u["additions"] as? [String: Any])?["speaker"] as? String)
                ))
            }
        }
        let duration = (json["audio_info"] as? [String: Any])?["duration"] as? Int
        return AsrResult(text: text, utterances: utterances, duration: duration)
    }
}

struct AsrResult {
    let text: String
    let utterances: [Utterance]
    let duration: Int?
}

struct Utterance {
    let text: String
    let startTime: Int?  // 毫秒
    let endTime: Int?    // 毫秒
    let speaker: String?
}

enum AsrError: LocalizedError {
    case badResponse
    case submitFailed(String, String)
    case queryFailed(String, String)
    case timeout
    case parseFailed
    var errorDescription: String? {
        switch self {
        case .badResponse: return "ASR 响应异常"
        case .submitFailed(let c, let m): return "ASR 提交失败: \(c) \(m)"
        case .queryFailed(let c, let m): return "ASR 查询失败: \(c) \(m)"
        case .timeout: return "ASR 转写超时"
        case .parseFailed: return "ASR 结果解析失败"
        }
    }
}
