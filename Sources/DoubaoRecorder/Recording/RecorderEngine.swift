import Foundation

/// 编排双源录音：系统音频 + 麦克风，各自落盘一个 wav。
///
/// 设计为双轨存储（保留原始数据、可分别回放、未来可分轨转写），
/// 转写前再由 AudioMixer 离线混成一个文件上传，避免实时混音的时间戳对齐问题。
public actor RecorderEngine {
    private let system = SystemAudioCapture()
    private let mic = MicrophoneCapture()

    public struct Output: Sendable {
        public let system: URL
        public let mic: URL
    }

    public init() {}

    public func start(outputDir: URL) async throws -> Output {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let systemURL = outputDir.appendingPathComponent("system.wav")
        let micURL = outputDir.appendingPathComponent("mic.wav")

        // 先起系统音频（更可能因权限失败），再起麦克风；麦克风失败则回滚系统音频。
        try await system.start(outputURL: systemURL)
        do {
            try mic.start(outputURL: micURL)
        } catch {
            await system.stop()
            throw error
        }
        return Output(system: systemURL, mic: micURL)
    }

    public func stop() async {
        await system.stop()
        mic.stop()
    }
}
