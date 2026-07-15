import AVFoundation

/// 把 PCM 音频流增量写成 wav 文件。线程安全（串行队列）。
///
/// M1 阶段先用 wav（16-bit PCM, 48k, mono）避免 AAC 编码的格式转换坑；
/// 长录音压缩成 m4a 留到接 ASR 前再做（5h wav 约 1.6GB 超 ASR 512MB 上限）。
/// 采集器输出的 buffer format 可能与目标不同（采样率/声道/float-vs-int），
/// 内部用 AVAudioConverter 自动对齐到目标 format。
final class AudioFileWriter {
    private let url: URL
    private let queue = DispatchQueue(label: "doubao-recorder.writer")
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var failed = false

    init(url: URL) {
        self.url = url
    }

    /// 写入一个 PCM buffer。非阻塞，丢入串行队列。
    func write(pcmBuffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, !self.failed else { return }
            do {
                try self.ensureFile(for: pcmBuffer.format)
                guard let file = self.file else { return }
                if let converter = self.converter {
                    guard let out = self.convert(pcmBuffer, using: converter) else {
                        return  // convert 失败，跳过该 buffer，不停止整轨
                    }
                    try file.write(from: out)
                } else {
                    try file.write(from: pcmBuffer)
                }
            } catch {
                self.failed = true
                FileHandle.standardError.write(Data("[writer \(self.url.lastPathComponent)] 写入失败，停止该轨: \(error.localizedDescription) bufferFormat=\(pcmBuffer.format)\n".utf8))
            }
        }
    }

    /// 关闭文件。同步等待队列排空，保证所有 buffer 落盘。
    func close() {
        queue.sync { [weak self] in
            self?.file = nil
            self?.converter = nil
        }
    }

    // MARK: - Private

    private func ensureFile(for inputFormat: AVAudioFormat) throws {
        guard file == nil else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let f = try AVAudioFile(forWriting: url, settings: settings)
        let target = f.processingFormat
        self.file = f
        if inputFormat != target {
            self.converter = AVAudioConverter(from: inputFormat, to: target)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let inRate = converter.inputFormat.sampleRate
        let ratio = inRate > 0 ? converter.outputFormat.sampleRate / inRate : 1
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, statusPtr in
            if fed {
                statusPtr.pointee = .endOfStream
                return nil
            }
            fed = true
            statusPtr.pointee = .haveData
            return buffer
        }
        if status == .error || out.frameLength == 0 { return nil }
        return out
    }
}
