// Times the project's own HEVC encoder at the iMac's full size. Prints "avg <ms>" and exits 1 above the limit.
// Run through Tests/encoder_latency.sh.

import Foundation
import CoreMedia
import CoreVideo

let width = 4480, height = 2520
let limitMs = 25.0

func makeFrame(_ i: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    let b = buffer!
    CVPixelBufferLockBaseAddress(b, [])
    for plane in 0..<2 {
        let p = CVPixelBufferGetBaseAddressOfPlane(b, plane)!.assumingMemoryBound(to: UInt8.self)
        let n = CVPixelBufferGetBytesPerRowOfPlane(b, plane) * CVPixelBufferGetHeightOfPlane(b, plane)
        for k in stride(from: 0, to: n, by: 7) { p[k] = UInt8(truncatingIfNeeded: (k / 997 + i * 13) & 0xFF) }   // moves every frame
    }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

guard let encoder = try? HEVCEncoder(width: width, height: height, fps: 60, bitrate: 150_000_000) else { print("could not create the encoder"); exit(2) }
let frames = (0..<6).map(makeFrame)
var timings: [Double] = []
let lock = NSLock(), gate = DispatchSemaphore(value: 2), group = DispatchGroup()
for i in 0..<90 {
    gate.wait(); group.enter()
    let start = DispatchTime.now()
    encoder.encode(frames[i % 6], pts: CMTime(value: Int64(i), timescale: 60)) { _ in
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        lock.lock(); timings.append(ms); lock.unlock()
        gate.signal(); group.leave()
    }
    usleep(16_000)
}
group.wait()
let steady = Array(timings.dropFirst(10))      // the first frames include warm-up and the keyframe
let average = steady.reduce(0, +) / Double(steady.count)
print(String(format: "avg %.1f ms (limit %.0f ms)", average, limitMs))
exit(average <= limitMs ? 0 : 1)
