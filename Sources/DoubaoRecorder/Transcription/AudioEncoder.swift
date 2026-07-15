import Foundation

/// 把混音后的 wav 转成 ASR 可接受的格式。
///
/// 优先用系统 ffmpeg 转 mp3（体积小，长录音单文件 <512M）；
/// 无 ffmpeg 时直接用 wav（长录音需分段逻辑兜底）。
/// Apple 平台不提供 mp3 编码器，只能借助 ffmpeg。
enum AudioEncoder {
    /// 编码结果：文件 URL + 对应 ASR 请求里的 audio.format / rate。
    struct Output {
        let url: URL
        let format: String  // "mp3" / "wav"
        let rate: Int        // 16000
    }

    /// 查找 ffmpeg 可执行路径。先查 homebrew 常见路径，再用 which 兜底。
    /// 直接用 /usr/bin/env which 会因 PATH 不含 homebrew 而漏判。
    static func ffmpegPath() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", "ffmpeg"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty { return path }
            }
        } catch {}
        return nil
    }

    static var hasFFmpeg: Bool { ffmpegPath() != nil }

    /// 编码 wav -> mp3（ffmpeg）；无 ffmpeg 时直接返回 wav。
    static func encode(wav: URL, outputDir: URL) throws -> Output {
        if let ffmpeg = ffmpegPath() {
            let mp3 = outputDir.appendingPathComponent("mixed.mp3")
            try runFFmpeg(ffmpeg: ffmpeg, input: wav, output: mp3)
            return Output(url: mp3, format: "mp3", rate: 16000)
        } else {
            // wav 已是 16k mono，直接用。长录音体积大，分段由调用层处理。
            return Output(url: wav, format: "wav", rate: 16000)
        }
    }

    private static func runFFmpeg(ffmpeg: String, input: URL, output: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ffmpeg)
        task.arguments = [
            "-y", "-i", input.path,
            "-ar", "16000", "-ac", "1", "-b:a", "64k",
            output.path
        ]
        // stdin/stdout/stderr 都指向 /dev/null，避免 Pipe 缓冲死锁或 stdin 等待。
        task.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw EncoderError.ffmpegFailed("exit \(task.terminationStatus)")
        }
    }
}

enum EncoderError: LocalizedError {
    case ffmpegFailed(String)
    var errorDescription: String? {
        switch self {
        case .ffmpegFailed(let msg): return "ffmpeg 转码失败: \(msg)"
        }
    }
}
