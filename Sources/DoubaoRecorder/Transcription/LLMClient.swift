import Foundation

/// 调豆包大模型（火山方舟 Ark，OpenAI 兼容）优化转写文本。
final class LLMClient {
    static let endpoint = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!

    let apiKey: String
    let model: String

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    /// 优化字幕文本：按 ASR 后处理 prompt 清理（删冗余、修错别字、归一格式、热词匹配）。
    func optimize(_ transcript: String, hotwords: [String]) async throws -> String {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let hotwordList = hotwords.isEmpty ? "（无）" : hotwords.joined(separator: "、")
        let prompt = """
你是一个 ASR 字幕后处理引擎。输入是一段语音识别的原始字幕（含说话人标签和时间戳），输出是清理后的字幕。不输出任何解释，只输出清理后的字幕。

【任务】
逐段清理 ASR 字幕，处理以下问题：
1. 删除口语冗余词（嗯、啊、呢、吧、那个、这个、就是、然后等填充词）。
2. 修复重复口吃（如"我们我们""他他""是是"）。
3. 修正明显错别字（如"贾勤->考勤""来临版->蓝领版""被调->背调"）。
4. 归一标点：句末单个句号，去掉"。。"。
5. 归一英文缩写：被 ASR 拆散的字母重新拼合（如"c o e"->COE、"m c p"->MCP、"s a a s"->SaaS）。
6. 归一数字格式：版本号、百分比、数量统一为中阿混排规范（如"三点零"->3.0、"百分之四十"->40%）。

【硬性规则】
1. 保持「说话人N HH:MM:SS」时间戳标签与段落数量、顺序完全一致。输入 N 段，必须输出 N 段，逐段对应。
2. 不得合并、拆分、删除、新增段落。不得改变段落的先后顺序。
3. 只在段内做清理，不做句式重构，不增删语义信息。
4. 数字（百分比、版本号、数量、金额、日期）一律保留原值，只做中阿混排格式归一，不得改写数值。
5. 专有名词以【热词库】为准。遇到发音相近、被拆散的词，优先匹配热词库中的形态。
6. 遇到无法确定的词（疑似专有名词但不在热词库、且无法从上下文确认），保留原样并在其后加 [?] 标记，不得自行脑补或编造。
7. 不输出任何解释、说明、过程，只输出清理后的字幕文本。

【热词库】
\(hotwordList)

【字幕】
\(transcript)
"""
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LLMError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.parseFailed
        }
        return content
    }
}

enum LLMError: LocalizedError {
    case requestFailed(Int)
    case parseFailed
    var errorDescription: String? {
        switch self {
        case .requestFailed(let code): return "大模型请求失败，HTTP \(code)"
        case .parseFailed: return "大模型返回解析失败"
        }
    }
}
