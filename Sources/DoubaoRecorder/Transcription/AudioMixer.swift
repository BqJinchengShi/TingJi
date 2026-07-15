import AVFoundation

/// 离线混合 system.wav + mic.wav 为单个 16k mono wav。
///
/// 双轨合并便于单任务转写。如需保留分轨信息，后续可改为合成双声道 wav
/// 并在 ASR 请求里开启 enable_channel_split（见阶段五增强）。
enum AudioMixer {
    /// 混音目标格式：16k mono float32（中间表示，写盘时再转 int16）。
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// 混合两个 wav 文件，输出 16k mono 16-bit wav。
    static func mix(system: URL, mic: URL, output: URL) throws {
        let systemBuf = try readAndResample(system)
        let micBuf = try readAndResample(mic)
        let mixed = average(systemBuf, micBuf)
        try writeWav(mixed, to: output)
    }

    /// 读 wav 并转 16k mono float。
    private static func readAndResample(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw MixerError.bufferAllocFailed
        }
        try file.read(into: srcBuf)
        srcBuf.frameLength = AVAudioFrameCount(file.length)
        if srcFormat == outputFormat { return srcBuf }
        guard let out = convert(srcBuf, to: outputFormat) else {
            throw MixerError.convertFailed
        }
        return out
    }

    /// 两轨等权平均，取较长时长（短的补零），避免相加溢出。
    private static func average(_ a: AVAudioPCMBuffer, _ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let n = max(a.frameLength, b.frameLength)
        let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: n)!
        out.frameLength = n
        let aCh = a.floatChannelData![0]
        let bCh = b.floatChannelData![0]
        let outCh = out.floatChannelData![0]
        for i in 0..<Int(n) {
            let av = i < Int(a.frameLength) ? aCh[i] : Float(0)
            let bv = i < Int(b.frameLength) ? bCh[i] : Float(0)
            outCh[i] = min(max(av + bv, -1.0), 1.0)
        }
        return out
    }

    /// 写 16k mono 16-bit wav（ASR 接受 wav，但长录音体积大，通常再经 AudioEncoder 转 mp3）。
    private static func writeWav(_ buf: AVAudioPCMBuffer, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let target = file.processingFormat
        let toWrite: AVAudioPCMBuffer
        if buf.format == target {
            toWrite = buf
        } else if let converted = convert(buf, to: target) {
            toWrite = converted
        } else {
            throw MixerError.convertFailed
        }
        try file.write(from: toWrite)
    }

    /// AVAudioConverter 通用转换（采样率/格式/声道），单次喂入整个 buffer。
    private static func convert(_ input: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else { return nil }
        let inRate = input.format.sampleRate
        let ratio = inRate > 0 ? outputFormat.sampleRate / inRate : 1
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error || out.frameLength == 0 { return nil }
        return out
    }
}

enum MixerError: LocalizedError {
    case bufferAllocFailed
    case convertFailed
    var errorDescription: String? {
        switch self {
        case .bufferAllocFailed: return "音频缓冲区分配失败"
        case .convertFailed: return "音频格式转换失败"
        }
    }
}
