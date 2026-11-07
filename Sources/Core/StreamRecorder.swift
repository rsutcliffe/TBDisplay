// An optional recording of the encoded stream, for finding where a picture fault comes from.
// The file is plain HEVC with start codes, so ffmpeg and other tools open it. It holds whatever was on the
// screen, so it is written owner-only, switched off unless asked for, and stops after a set time.

import Foundation

enum AnnexB {
    private static let startCode = Data([0, 0, 0, 1])

    /// Turns length-prefixed NAL units (the encoder's form) into start-code NAL units. Nil if the lengths do not fit.
    static func convert(_ frame: Data, nalHeaderLength: Int) -> Data? {
        guard (1...4).contains(nalHeaderLength), !frame.isEmpty else { return nil }
        var out = Data()
        var i = frame.startIndex
        while i < frame.endIndex {
            guard frame.endIndex - i >= nalHeaderLength else { return nil }
            var length = 0
            for k in 0..<nalHeaderLength { length = length << 8 | Int(frame[i + k]) }
            i += nalHeaderLength
            guard length > 0, frame.endIndex - i >= length else { return nil }
            out.append(startCode)
            out.append(frame[i..<(i + length)])
            i += length
        }
        return out
    }

    /// Writes each parameter set (VPS, SPS, PPS) with a start code.
    static func parameterSets(_ sets: [Data]) -> Data {
        var out = Data()
        for set in sets { out.append(startCode); out.append(set) }
        return out
    }
}

final class StreamRecorder {
    private(set) var isActive = true

    private let directory: URL
    private let maxSeconds: Double
    private let now: () -> Date
    private var started: Date?
    private var stream: FileHandle?
    private var list: FileHandle?
    private var index = 0
    private var nalHeaderLength = 4
    private var sawKeyframe = false

    init(directory: URL, maxSeconds: Double, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.maxSeconds = maxSeconds
        self.now = now
    }

    deinit { finish() }

    /// Adds one encoded frame. Frames before the first keyframe are skipped, since they cannot be decoded without its parameter sets.
    func record(frame: Data, isKeyframe: Bool, ptsMicros: Int64, config: VideoConfig?) {
        guard isActive else { return }
        if let started, now().timeIntervalSince(started) > maxSeconds { finish(); return }
        if let config { nalHeaderLength = Int(config.nalUnitHeaderLength) }
        if !sawKeyframe {
            guard isKeyframe, config != nil else { return }
            guard open() else { isActive = false; return }
            sawKeyframe = true
            started = now()
        }
        guard let body = AnnexB.convert(frame, nalHeaderLength: nalHeaderLength) else { return }   // a broken frame is skipped
        var chunk = Data()
        if isKeyframe, let config { chunk.append(AnnexB.parameterSets(config.parameterSets)) }
        chunk.append(body)
        stream?.write(chunk)
        let seconds = started.map { now().timeIntervalSince($0) } ?? 0
        list?.write(Data("\(index),\(ptsMicros),\(body.count),\(isKeyframe ? 1 : 0),\(String(format: "%.3f", seconds))\n".utf8))
        index += 1
    }

    /// The folder and both files are owner-only, because the recording shows the screen.
    private func open() -> Bool {
        let files = FileManager.default
        do { try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { return false }
        let streamURL = directory.appendingPathComponent("stream.hevc"), listURL = directory.appendingPathComponent("frames.csv")
        guard files.createFile(atPath: streamURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              files.createFile(atPath: listURL.path, contents: Data("index,pts_us,bytes,keyframe,seconds\n".utf8), attributes: [.posixPermissions: 0o600]),
              let s = try? FileHandle(forWritingTo: streamURL), let l = try? FileHandle(forWritingTo: listURL) else { return false }
        _ = try? l.seekToEnd()
        stream = s; list = l
        return true
    }

    private func finish() {
        try? stream?.close(); try? list?.close()
        stream = nil; list = nil
        isActive = false
    }
}
