// The stream recorder: a diagnostic copy of the encoded stream that ffmpeg can open.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runStreamRecorderTests() {
    let start: [UInt8] = [0, 0, 0, 1]

    // Annex B conversion
    let frame4 = Data([0, 0, 0, 3, 0xAA, 0xBB, 0xCC, 0, 0, 0, 2, 0xDD, 0xEE])
    check(AnnexB.convert(frame4, nalHeaderLength: 4) == Data(start + [0xAA, 0xBB, 0xCC] + start + [0xDD, 0xEE]), "two NAL units with 4-byte lengths get start codes")
    let frame2 = Data([0, 1, 0x11, 0, 2, 0x22, 0x33])
    check(AnnexB.convert(frame2, nalHeaderLength: 2) == Data(start + [0x11] + start + [0x22, 0x33]), "the length prefix size is respected (2 bytes)")
    check(AnnexB.convert(Data([0, 0, 0, 9, 1, 2]), nalHeaderLength: 4) == nil, "a length longer than the data is refused")
    check(AnnexB.convert(Data([0, 0]), nalHeaderLength: 4) == nil, "data shorter than one length prefix is refused")
    check(AnnexB.convert(Data(), nalHeaderLength: 4) == nil, "an empty frame is refused")
    check(AnnexB.parameterSets([Data([1, 2]), Data([3])]) == Data(start + [1, 2] + start + [3]), "parameter sets each get a start code")

    // The recorder
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    var clock = Date(timeIntervalSince1970: 1000)
    let out = dir.appendingPathComponent("rec")
    let rec = StreamRecorder(directory: out, maxSeconds: 5, now: { clock })
    let config = VideoConfig(width: 640, height: 360, nalUnitHeaderLength: 4, parameterSets: [Data([0x40]), Data([0x42]), Data([0x44])])

    rec.record(frame: Data([0, 0, 0, 1, 0x99]), isKeyframe: false, ptsMicros: 1, config: nil)
    check(!FileManager.default.fileExists(atPath: out.appendingPathComponent("stream.hevc").path) ||
          ((try? Data(contentsOf: out.appendingPathComponent("stream.hevc")))?.isEmpty ?? true), "a frame before the first keyframe is not written")

    rec.record(frame: Data([0, 0, 0, 2, 0xAA, 0xBB]), isKeyframe: true, ptsMicros: 100, config: config)
    clock = clock.addingTimeInterval(1)
    rec.record(frame: Data([0, 0, 0, 1, 0xCC]), isKeyframe: false, ptsMicros: 200, config: nil)
    let stream = (try? Data(contentsOf: out.appendingPathComponent("stream.hevc"))) ?? Data()
    let expected = Data(start + [0x40] + start + [0x42] + start + [0x44] + start + [0xAA, 0xBB] + start + [0xCC])
    check(stream == expected, "the stream holds the parameter sets, the keyframe, then the next frame, in start-code form")

    let csv = (try? String(contentsOf: out.appendingPathComponent("frames.csv"), encoding: .utf8)) ?? ""
    let lines = csv.split(separator: "\n").map(String.init)
    check(lines.first == "index,pts_us,bytes,keyframe,seconds", "the frame list has a header")
    check(lines.count == 3 && lines[1].hasPrefix("0,100,") && lines[1].contains(",1,") && lines[2].hasPrefix("1,200,"), "each written frame has one line, numbered from 0")

    func mode(_ url: URL) -> Int? { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue }
    check(mode(out) == 0o700, "the folder is owner-only")
    check(mode(out.appendingPathComponent("stream.hevc")) == 0o600 && mode(out.appendingPathComponent("frames.csv")) == 0o600, "the files are owner-only")

    check(rec.isActive, "recording is active inside the time limit")
    clock = clock.addingTimeInterval(10)
    rec.record(frame: Data([0, 0, 0, 1, 0xEE]), isKeyframe: false, ptsMicros: 300, config: nil)
    check(!rec.isActive, "recording stops after the time limit")
    check(((try? Data(contentsOf: out.appendingPathComponent("stream.hevc"))) ?? Data()) == stream, "nothing is written after it stops")

    // A frame that cannot be converted is skipped and does not stop the recording
    let rec2 = StreamRecorder(directory: dir.appendingPathComponent("rec2"), maxSeconds: 5, now: { clock })
    rec2.record(frame: Data([0, 0, 0, 1, 0x01]), isKeyframe: true, ptsMicros: 1, config: config)
    rec2.record(frame: Data([0, 0, 0, 99, 0x02]), isKeyframe: false, ptsMicros: 2, config: nil)
    check(rec2.isActive, "a broken frame does not stop the recording")
}
