import AVFoundation
import Foundation

/// User-imported replacements for the built-in tones (for example your own recordings of the
/// original Nextel sounds). Files live in Application Support/Sounds.
enum SoundLibrary {
    static let maxSeconds: Double = 5

    enum ImportError: LocalizedError {
        case unreadable, tooLong

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file isn't an audio format iOS can read."
            case .tooLong: return "Sounds can be at most 5 seconds long."
            }
        }
    }

    private static let lock = NSLock()
    private static var cache: [Tone: AVAudioPCMBuffer] = [:]

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func customURL(for tone: Tone) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent == tone.rawValue }
    }

    static func hasCustom(_ tone: Tone) -> Bool { customURL(for: tone) != nil }

    /// Copies a user-picked file in as the sound for `tone`.
    static func importSound(from source: URL, for tone: Tone) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let file = try? AVAudioFile(forReading: source) else { throw ImportError.unreadable }
        guard Double(file.length) / file.fileFormat.sampleRate <= maxSeconds else { throw ImportError.tooLong }
        reset(tone)
        let ext = source.pathExtension.isEmpty ? "caf" : source.pathExtension
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("\(tone.rawValue).\(ext)"))
        invalidate(tone)
    }

    static func reset(_ tone: Tone) {
        if let url = customURL(for: tone) { try? FileManager.default.removeItem(at: url) }
        invalidate(tone)
    }

    static func invalidate(_ tone: Tone? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let tone { cache[tone] = nil } else { cache.removeAll() }
    }

    /// The custom sound converted to `format`, or nil to use the synthesized tone.
    static func buffer(for tone: Tone, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        lock.lock()
        if let cached = cache[tone], cached.format == format { lock.unlock(); return cached }
        lock.unlock()
        guard let url = customURL(for: tone), let file = try? AVAudioFile(forReading: url),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        let ratio = format.sampleRate / file.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024)
        else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        lock.lock()
        cache[tone] = output
        lock.unlock()
        return output
    }

    /// Audio data for previewing a tone in Settings (custom file or synthesized WAV).
    static func previewData(for tone: Tone) -> Data {
        if let url = customURL(for: tone), let data = try? Data(contentsOf: url) { return data }
        return ToneSynth.wav(for: tone)
    }
}
