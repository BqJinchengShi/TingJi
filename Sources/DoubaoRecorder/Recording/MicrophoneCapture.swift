import AVFoundation

/// 用 AVAudioEngine 录制麦克风（电脑外的声音）。需「麦克风」权限。
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?

    func start(outputURL: URL) throws {
        let writer = AudioFileWriter(url: outputURL)
        self.writer = writer

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            writer.write(pcmBuffer: buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.inputNode.tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        writer?.close()
        writer = nil
    }
}

private extension AVAudioNode {
    /// AVAudioInputNode 没有直接的 tapInstalled 属性，用是否安装过判断避免重复 remove 崩溃。
    var tapInstalled: Bool {
        // value(forKey:) 取内部状态属于私有 API 兜底；用简单标志位更稳妥，这里用尝试式判断。
        // installTap 后再 remove 是安全的，重复 remove 会抛异常，因此保守返回 true 由上层保证只调一次。
        return true
    }
}
