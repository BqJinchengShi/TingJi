import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// 用 ScreenCaptureKit 录制系统音频（电脑内播放的声音）。
///
/// macOS 出于版权限制不提供直接录系统输出的 API，ScreenCaptureKit 是苹果原生方案：
/// 它本是录屏框架，但可配置只捕获音频流（不录画面）。代价是用户需授予「屏幕录制」权限
/// （苹果如此归类，即使只录音频）。
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var writer: AudioFileWriter?
    private let callbackQueue = DispatchQueue(label: "doubao-recorder.sc-audio", qos: .userInitiated)

    func start(outputURL: URL) async throws {
        let writer = AudioFileWriter(url: outputURL)
        self.writer = writer

        // 获取可共享内容，会触发「屏幕录制」权限弹窗。
        let content = try await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(
                domain: "SystemAudioCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "没有找到可用的显示器（ScreenCaptureKit 需要至少一块屏幕）"]
            )
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        // 通道数/采样率由系统给定（通常 48000/单声道）；writer 侧用实际 buffer format 兜底转 16k mono。

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callbackQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        writer?.close()
        writer = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let writer else { return }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        writer.write(pcmBuffer: pcm)
    }

    /// 从 CMSampleBuffer 提取 PCM。新 SDK 移除了 AVAudioPCMBuffer(cmSampleBuffer:)，改用 CoreMedia 手动拷贝。
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == kCMBlockBufferNoErr else { return nil }
        // SCStream 系统音频常是立体声，writer target 是单声道；先 downmix 到 mono，绕开 AVAudioConverter 的 stereo->mono 失败问题。
        if audioFormat.channelCount > 1 {
            return downmixToMono(buffer)
        }
        return buffer
    }

    /// 多声道 -> mono（各声道平均）。
    private static func downmixToMono(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let monoFormat = AVAudioFormat(commonFormat: input.format.commonFormat,
                                             sampleRate: input.format.sampleRate,
                                             channels: 1, interleaved: false) else { return nil }
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: input.frameLength) else { return nil }
        out.frameLength = input.frameLength
        guard let inChannels = input.floatChannelData, let outCh = out.floatChannelData?[0] else { return nil }
        let chCount = Int(input.format.channelCount)
        let frames = Int(input.frameLength)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<chCount {
                sum += inChannels[c][i]
            }
            outCh[i] = sum / Float(chCount)
        }
        return out
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("[system-audio] 流停止: \(error.localizedDescription)\n".utf8))
    }
}
