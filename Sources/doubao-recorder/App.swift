import Foundation

@main
struct RecorderCLI {
    static func main() async {
        let args = CommandLine.arguments
        let cmd = args.count > 1 ? args[1] : "run"

        do {
            switch cmd {
            case "record":
                let duration = args.count > 2 ? (Int(args[2]) ?? 10) : 10
                try await record(duration: duration)
            case "transcribe":
                guard args.count > 2 else { fail("用法: doubao-recorder transcribe <录音目录>") }
                try await transcribe(dir: URL(fileURLWithPath: args[2]))
            case "help", "-h", "--help":
                printHelp()
            default:
                // 兼容旧用法：doubao-recorder <duration> = 录音 + 转写
                let duration = Int(cmd) ?? 10
                try await run(duration: duration)
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - 命令

    /// 录音 + 转写（端到端，默认）。
    static func run(duration: Int) async throws {
        let dir = newOutputDir()
        print("🎙️  录音 \(duration) 秒 + 转写")
        print("    输出目录: \(dir.path)")
        try await recordOnly(duration: duration, outputDir: dir)
        try await transcribeDir(dir)
    }

    /// 仅录音。
    static func record(duration: Int) async throws {
        let dir = newOutputDir()
        print("🎙️  录音 \(duration) 秒（仅录音，不转写）")
        print("    输出目录: \(dir.path)")
        try await recordOnly(duration: duration, outputDir: dir)
        print("✅ 录音完成: \(dir.path)")
    }

    /// 对已有录音目录转写（目录需含 system.wav + mic.wav）。
    static func transcribe(dir: URL) async throws {
        print("📝 转写: \(dir.path)")
        try await transcribeDir(dir)
    }

    // MARK: - 录音

    private static func recordOnly(duration: Int, outputDir: URL) async throws {
        // 记录录音开始时间（东八区），供转写时生成实际时间戳。
        let startTime = Date()
        let meta = ["start": ISO8601DateFormatter().string(from: startTime)]
        if let data = try? JSONSerialization.data(withJSONObject: meta) {
            try? data.write(to: outputDir.appendingPathComponent("meta.json"))
        }
        print("    首次运行会弹「屏幕录制」「麦克风」权限，需在系统设置授权后重试。")
        let engine = RecorderEngine()
        let urls = try await engine.start(outputDir: outputDir)
        for remaining in stride(from: duration, through: 1, by: -1) {
            print("\r    录音中... 剩余 \(remaining)s  ", terminator: "")
            fflush(stdout)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        await engine.stop()
        print("\n    系统音频: \(urls.system.path)")
        print("    麦克风  : \(urls.mic.path)")
    }

    // MARK: - 转写链路：混音 -> 编码 -> 上传 -> ASR -> 输出

    private static func transcribeDir(_ dir: URL) async throws {
        let baseTime = TranscriptionService.readBaseTime(dir)
            ?? TranscriptionService.fileModDate(dir.appendingPathComponent("system.wav"))
        _ = try await TranscriptionService.transcribe(dir: dir, baseTime: baseTime) { step in
            print(step)
        }
        let transcriptURL = dir.appendingPathComponent("transcript.txt")
        let jsonURL = dir.appendingPathComponent("transcript.json")
        let text = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        print("✅ 完成")
        print("   文本: \(transcriptURL.path)")
        print("   JSON: \(jsonURL.path)")
        if !text.isEmpty {
            print("   摘要: \(text.prefix(200))")
        }
    }

    // MARK: - 辅助

    private static func newOutputDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("doubao-recorder-\(UUID().uuidString)", isDirectory: true)
    }

    private static func printHelp() {
        print("""
        用法:
          doubao-recorder [duration]      录音 N 秒并转写（默认，N 默认 10）
          doubao-recorder record <N>      仅录音 N 秒
          doubao-recorder transcribe <dir> 对已有录音目录转写（需含 system.wav + mic.wav）

        配置: 复制 .env.example 为 .env，填 ASR 鉴权与 TOS 配置。
        依赖: 建议安装 ffmpeg（brew install ffmpeg）以转 mp3；否则用 wav（长录音需分段）。
        """)
    }

    private static func fail(_ msg: String) -> Never {
        fflush(stdout)
        FileHandle.standardError.write(Data("❌ \(msg)\n".utf8))
        exit(1)
    }
}
