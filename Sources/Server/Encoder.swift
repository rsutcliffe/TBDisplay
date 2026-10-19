// Hardware HEVC encoder tuned for interactive, low-latency desktop streaming.

import CoreMedia
import CoreVideo
import VideoToolbox

struct EncodedFrame {
    var isKeyframe: Bool
    var ptsMicros: Int64
    var data: Data                     // length-prefixed NAL units (HVCC style)
    var config: VideoConfig?           // present on keyframes
}

final class HEVCEncoder {
    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32

    /// Set to true to make the next encoded frame a keyframe.
    /// Only touch this from the pipeline queue.
    var forceKeyframe = true

    init(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        self.width = Int32(width)
        self.height = Int32(height)

        // Plain real-time hardware encoding. The low-latency rate control mode was tried first and measured 41 ms per
        // frame at 4480x2520, against 11 ms for this one (Tests/encoder_latency.sh keeps it that way).
        let specs: [(String, [CFString: Any])] = [
            ("real-time hardware", [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            ]),
        ]

        var lastStatus: OSStatus = noErr
        for (label, spec) in specs {
            var created: VTCompressionSession?
            lastStatus = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: self.width,
                height: self.height,
                codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &created)
            if lastStatus == noErr, let created {
                session = created
                log("Encoder: HEVC \(width)x\(height), \(label) mode, \(bitrate / 1_000_000) Mbps")
                break
            }
        }
        guard let session else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(lastStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Could not create HEVC encoder (\(lastStatus))"])
        }

        set(session, kVTCompressionPropertyKey_RealTime, true)
        set(session, kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set(session, kVTCompressionPropertyKey_AverageBitRate, bitrate)
        set(session, kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 10)
        set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10)
        set(session, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(session, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(session, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// Changes the target bitrate while encoding. Safe to call from the pipeline queue.
    func setBitrate(_ bitrate: Int) {
        guard let session else { return }
        set(session, kVTCompressionPropertyKey_AverageBitRate, bitrate)
    }

    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: Any) {
        let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        if status != noErr {
            log("Encoder ignored \(key) (\(status))")
        }
    }

    /// Encodes one frame. `completion` runs on a VideoToolbox thread with nil if the frame
    /// was dropped or failed.
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, completion: @escaping (EncodedFrame?) -> Void) {
        guard let session else { completion(nil); return }

        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKeyframe = false
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { completion(nil); return }
            completion(HEVCEncoder.extract(sampleBuffer))
        }

        if status != noErr {
            log("Encode failed (\(status))")
            forceKeyframe = true
            completion(nil)
        }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    deinit { invalidate() }

    private static func extract(_ sampleBuffer: CMSampleBuffer) -> EncodedFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [NSDictionary],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool, notSync {
            isKeyframe = false
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsMicros = pts.isValid ? Int64(CMTimeGetSeconds(pts) * 1_000_000) : 0

        var config: VideoConfig?
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            var nalLength: Int32 = 4
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
            var sets: [Data] = []
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if status == noErr, let pointer { sets.append(Data(bytes: pointer, count: size)) }
            }
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            config = VideoConfig(width: UInt32(dims.width), height: UInt32(dims.height),
                                 nalUnitHeaderLength: UInt8(nalLength), parameterSets: sets)
        }

        return EncodedFrame(isKeyframe: isKeyframe, ptsMicros: ptsMicros, data: data, config: config)
    }
}
