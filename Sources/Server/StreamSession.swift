// One connected iMac: creates the virtual display, captures it, encodes and sends frames.
//
// Latency control: at most `maxInFlight` frames may be inside the encoder or the socket
// at once. Newer captured frames replace any waiting frame ("latest frame wins"), so a
// slow moment never builds a queue of stale frames, which is where AirPlay-style lag grows.
//
// Bitrate control: once a second the session looks at how long frames take to leave the
// socket. Slow sends cut the bitrate, steady fast sends raise it again up to the cap.

import AppKit
import ApplicationServices
import CoreMedia
import Network
@preconcurrency import ScreenCaptureKit

struct ServerOptions {
    var port: UInt16 = defaultPort
    var bitrate = 150_000_000          // the cap when adaptive bitrate is on
    var adaptBitrate = true
    var fps = 60
    var maxInFlight = 2
    var policy: InterfacePolicy = .mode(ConnectionMode.saved())     // the menu changes it while the app runs
    var pausedNotice: String?          // set while Disconnect has paused this MacBook: the iMac is told, then closed
    var hiDPI = true
}

// All state is touched on `queue` only, so crossing threads through it is safe. The compiler cannot see that.
final class StreamSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let connection: NWConnection
    private let options: ServerOptions
    private let state: ServerState
    private let queue = DispatchQueue(label: "tbdisplay.session", qos: .userInteractive)
    var onClose: (() -> Void)?
    var onAuthenticated: (() -> Void)?       // the client has sent a good hello (the TLS handshake alone is not enough)
    var onHandshakeFailed: (() -> Void)?     // wrong key, no key, or not TLS at all

    // Pipeline state, only touched on `queue`
    private var started = false
    private var closed = false
    private var encoder: HEVCEncoder?
    private var stream: SCStream?
    private var inFlight = 0
    private var ageStats = LatencyStats()      // capture to the start of encoding: delivery plus any wait while parked
    private var totalStats = LatencyStats()    // capture to the last byte handed to the network
    private var parked: (CVPixelBuffer, CMTime)?
    private var handshakeDone = false
    private var inputRefusedLogged = false
    private var unknownTypeLogged = false
    private var keysDown = Set<UInt32>()
    private var inputThisSecond = 0
    private var secFrames = 0, secEncodeMs = 0.0, secSendMs = 0.0, secTimed = 0
    private var hello: Hello?
    private var controller: BitrateController
    private var secondTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var virtualDisplayID = kCGNullDirectDisplay
    private var buttonsDown = Set<UInt8>()
    private var statFrames = 0
    private var statBytes = 0
    private var statSkipped = 0
    private var statEncodeMs = 0.0, statSendMs = 0.0, statTimed = 0
    private var winSendMs = 0.0, winFrames = 0, winBytes = 0
    private var lastStatsIdle = false
    private var cursorTracker = CursorTracker()
    private var cursorTimer: DispatchSourceTimer?
    private var cursorShapeTimer: DispatchSourceTimer?     // runs on the main thread, where NSCursor is read
    private var cursorSendsPending = 0                     // pointer messages handed to the network and not yet sent
    private var lastCursorShape: CursorShape?              // main thread only

    // Main-thread state
    private var display: VirtualDisplay?
    private var mainClosed = false     // set once the session is closed, so a retry loop stops

    init(connection: NWConnection, options: ServerOptions, state: ServerState) {
        self.connection = connection
        self.options = options
        self.state = state
        self.controller = BitrateController(cap: options.bitrate)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let name = interfaceName(of: self.connection)
                if let paused = self.options.pausedNotice {
                    log("Turned away \(self.connection.endpoint): connections are paused.")
                    self.connection.send(content: frameMessage(.notice, Data(paused.utf8)), completion: .contentProcessed { [weak self] _ in
                        self?.queue.async { self?.close() }
                    })
                    return
                }
                if !self.options.policy.allows(interfaceName: name ?? "", kind: interfaceKind(of: self.connection)) {
                    log("Rejected \(self.connection.endpoint) on \(name ?? "an unknown interface"). This Mac accepts connections \(self.options.policy.summary) (change Connect over in the menu bar item).")
                    // The iMac is told why, so its window can say so instead of just losing the connection.
                    self.connection.send(content: frameMessage(.notice, Data(self.options.policy.refusalNotice.utf8)), completion: .contentProcessed { [weak self] _ in
                        self?.queue.async { self?.close() }
                    })
                    return
                }
                guard negotiatedAsExpected(self.connection) else {
                    log("Refusing \(self.connection.endpoint): the connection did not negotiate the expected encryption (\(encryptionSummary(of: self.connection))).")
                    DispatchQueue.main.async { self.onHandshakeFailed?() }
                    self.close()
                    return
                }
                log("Client connected from \(self.connection.endpoint) via \(name ?? "unknown interface"), \(encryptionSummary(of: self.connection))")
                self.handshakeDone = true
                // It counts as a client, and may replace the live one, only once it sends a hello. A connection check
                // never does, so it cannot drop a stream. One that never says hello is closed.
                self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, !self.started, !self.closed else { return }
                    log("A client connected but never said hello within 10 seconds. Dropping it.")
                    self.close()
                }
                receiveMessages(on: self.connection, maxMessage: 4096,   // the client sends tiny messages only
                                onMessage: { [weak self] type, payload in self?.handle(type, payload) },
                                onClose: { [weak self] error in
                                    if let error { log("Connection closed: \(error)") } else { log("Client disconnected") }
                                    self?.close()
                                })
            case .failed(let error):
                if self.handshakeDone {
                    log("Connection failed: \(error)")
                } else {
                    log("Handshake failed from \(self.connection.endpoint): \(error). Wrong pairing key, or not a TBDisplay client.")
                    DispatchQueue.main.async { self.onHandshakeFailed?() }
                }
                self.close()
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        // A connection that never finishes the handshake is cut off and counted as a failure.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.handshakeDone, !self.closed else { return }
            log("Handshake from \(self.connection.endpoint) timed out.")
            DispatchQueue.main.async { self.onHandshakeFailed?() }
            self.close()
        }
    }

    // MARK: Messages (on queue)

    private func handle(_ rawType: UInt8, _ payload: Data) {
        switch MessageType(rawValue: rawType) {
        case .hello:
            guard !started else { return }
            do {
                let hello = try Hello.decode(payload)
                guard hello.version == protocolVersion else {
                    let who = hello.appVersion.isEmpty ? "an older TBDisplay" : "TBDisplay \(hello.appVersion)"
                    log("Client protocol \(hello.version) (\(who)) does not match server \(protocolVersion) (TBDisplay \(appVersion)). Telling it to update.")
                    let notice = VersionCheck.refusalNotice(clientProtocol: hello.version, clientApp: hello.appVersion,
                                                            serverProtocol: protocolVersion, serverApp: appVersion)
                    connection.send(content: frameMessage(.notice, Data(notice.utf8)), completion: .contentProcessed { [weak self] _ in
                        self?.queue.async { self?.close() }
                    })
                    return
                }
                guard hello.isSane else {
                    log("Refusing a screen size no Mac reports: \(hello.pixelWidth)x\(hello.pixelHeight) at \(hello.scale)x, \(hello.refreshRate) Hz.")
                    close()
                    return
                }
                started = true
                DispatchQueue.main.async { self.onAuthenticated?() }
                self.hello = hello
                log("iMac screen: \(hello.pixelWidth)x\(hello.pixelHeight) px at \(hello.scale)x, \(hello.refreshRate) Hz, TBDisplay \(hello.appVersion.isEmpty ? "(version not given)" : hello.appVersion)")
                startPipeline(hello)
            } catch {
                log("Bad hello: \(error)")
                close()
            }
        case .keyframeRequest:
            encoder?.forceKeyframe = true
        case .input:
            guard started, let event = try? InputEvent.decode(payload) else { return }
            guard state.allowInput else {
                if !inputRefusedLogged {
                    inputRefusedLogged = true
                    log("Ignoring keyboard and mouse from the iMac. Switch them on in the menu bar item.")
                }
                return
            }
            guard inputThisSecond < 3000, event.isSane else { return }   // a person cannot produce more than this
            inputThisSecond += 1
            var safe = event
            safe.flags = event.flags & 0x00FF_0000      // modifier keys only
            inject(safe)
        default:
            if !unknownTypeLogged {
                unknownTypeLogged = true
                log("Ignoring message type \(rawType)")
            }
        }
    }

    // MARK: Input from the iMac (on queue)

    private func inject(_ event: InputEvent) {
        let bounds = CGDisplayBounds(virtualDisplayID)
        guard bounds.width > 0 else { return }
        let here = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let flags = CGEventFlags(rawValue: UInt64(event.flags))

        func mouse(_ type: CGEventType, _ button: CGMouseButton, at point: CGPoint, delta: (Int64, Int64) = (0, 0)) {
            let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            cg?.flags = flags
            cg?.setIntegerValueField(.mouseEventDeltaX, value: delta.0)
            cg?.setIntegerValueField(.mouseEventDeltaY, value: delta.1)
            cg?.post(tap: .cghidEventTap)
        }
        func downType(_ b: UInt8) -> CGEventType { b == 0 ? .leftMouseDown : b == 1 ? .rightMouseDown : .otherMouseDown }
        func upType(_ b: UInt8) -> CGEventType { b == 0 ? .leftMouseUp : b == 1 ? .rightMouseUp : .otherMouseUp }
        func dragType(_ b: UInt8) -> CGEventType { b == 0 ? .leftMouseDragged : b == 1 ? .rightMouseDragged : .otherMouseDragged }
        func cgButton(_ b: UInt8) -> CGMouseButton { b == 0 ? .left : b == 1 ? .right : .center }

        switch event.kind {
        case .mouseMove:
            // The movement is a share of the iMac screen. The virtual display is the same shape, so scale by it.
            let moveX = Double(event.dx) / 1_000_000 * bounds.width
            let moveY = Double(event.dy) / 1_000_000 * bounds.height
            let target = clampToDisplays(CGPoint(x: here.x + moveX, y: here.y + moveY))
            let delta = (Int64(moveX.rounded()), Int64(moveY.rounded()))
            if let held = buttonsDown.sorted().first { mouse(dragType(held), cgButton(held), at: target, delta: delta) }
            else { mouse(.mouseMoved, .left, at: target, delta: delta) }
        case .mouseDown:
            buttonsDown.insert(event.button)
            mouse(downType(event.button), cgButton(event.button), at: here)
        case .mouseUp:
            buttonsDown.remove(event.button)
            mouse(upType(event.button), cgButton(event.button), at: here)
        case .scroll:
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                             wheel1: Int32(event.scrollY / 100), wheel2: Int32(event.scrollX / 100), wheel3: 0)
            cg?.flags = flags
            cg?.post(tap: .cghidEventTap)
        case .keyDown, .keyUp:
            if event.kind == .keyDown { keysDown.insert(event.keyCode) } else { keysDown.remove(event.keyCode) }
            let cg = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(event.keyCode), keyDown: event.kind == .keyDown)
            cg?.flags = flags
            cg?.post(tap: .cghidEventTap)
        }
    }

    /// Lets go of anything still held, so a dropped connection cannot leave a button or key stuck down.
    private func releaseInput() {
        let here = CGEvent(source: nil)?.location ?? .zero
        for b in buttonsDown {
            let type: CGEventType = b == 0 ? .leftMouseUp : b == 1 ? .rightMouseUp : .otherMouseUp
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: here,
                    mouseButton: b == 0 ? .left : b == 1 ? .right : .center)?.post(tap: .cghidEventTap)
        }
        for code in keysDown {
            CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false)?.post(tap: .cghidEventTap)
        }
        buttonsDown.removeAll(); keysDown.removeAll()
    }

    /// Keeps the pointer on a real display. A point outside every display moves to the nearest edge.
    private func clampToDisplays(_ point: CGPoint) -> CGPoint {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return point }
        return DisplayGeometry.clamp(point, to: ids.prefix(Int(count)).map { CGDisplayBounds($0) })
    }

    // MARK: Pipeline setup

    private func startPipeline(_ hello: Hello) {
        let width = Int(hello.pixelWidth), height = Int(hello.pixelHeight)
        let scale = Int(max(hello.scale, 1))
        let fps = min(options.fps, Int(max(hello.refreshRate, 30)))

        do {
            encoder = try HEVCEncoder(width: width, height: height, fps: fps, bitrate: options.bitrate)
        } catch {
            log("\(error.localizedDescription)")
            close()
            return
        }

        // macOS can keep a removed virtual display for a while after a messy shutdown, and then refuses to
        // make another with the same identity. Retry for up to 20 seconds before giving up.
        func createDisplay(_ left: Int) {
            guard !mainClosed else { return }
            if let display = VirtualDisplay(name: "iMac via Thunderbolt", pixelWidth: width, pixelHeight: height,
                                            refreshRate: Double(fps), hiDPI: options.hiDPI, scale: scale, quiet: left > 0) {
                self.display = display
                continuePipeline(display: display, width: width, height: height, fps: fps, scale: scale)
                return
            }
            if left == 0 {
                log("Could not create the virtual display. macOS may still be clearing a previous one: wait a few minutes, or log out and in.")
                queue.async { self.close() }
                return
            }
            if left == 19 { log("Waiting for macOS to free the previous virtual display…") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { createDisplay(left - 1) }
        }
        DispatchQueue.main.async { createDisplay(19) }
    }

    /// Main thread. Waits for the new display's modes, then starts capturing it.
    private func continuePipeline(display: VirtualDisplay, width: Int, height: Int, fps: Int, scale: Int) {
        let displayID = display.displayID
        queue.async { self.virtualDisplayID = displayID }
        let begin = {
            display.restoreArrangement()
            Task { await self.startCapture(displayID: displayID, width: width, height: height, fps: fps) }
        }
        guard options.hiDPI else { begin(); return }
        // The mode list is empty for a moment after creation, so retry for up to 3 seconds.
        func attempt(_ left: Int) {
            if display.selectMode(scale: scale, quiet: left > 0) || left == 0 { begin(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { attempt(left - 1) }
        }
        attempt(10)
    }

    private func startCapture(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async {
        // The new display takes a moment to appear in ScreenCaptureKit.
        var scDisplay: SCDisplay?
        for _ in 0..<40 {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let match = content.displays.first(where: { $0.displayID == displayID }) {
                scDisplay = match
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let scDisplay else {
            log("The virtual display never appeared for capture. Check Screen Recording permission for Terminal.")
            queue.async { self.close() }
            return
        }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 5
        config.showsCursor = false     // the pointer travels as its own small messages (see startCursor)
        config.scalesToFit = false

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            log("Could not start capture: \(error.localizedDescription)")
            queue.async { self.close() }
            return
        }

        queue.async {
            guard !self.closed else {
                stream.stopCapture { _ in }
                return
            }
            self.stream = stream
            self.startTimers()
            log("Streaming \(width)x\(height) at up to \(fps) fps")
        }
    }

    // MARK: Capture and encode (on queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !closed, let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // Skip idle and blank callbacks. ScreenCaptureKit only sends complete frames when content changes.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let info = attachments.first,
           let rawStatus = info[.status] as? Int,
           let status = SCFrameStatus(rawValue: rawStatus),
           status != .complete {
            return
        }
        submit(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    private func submit(_ pixelBuffer: CVPixelBuffer, _ pts: CMTime) {
        guard let encoder, !closed else { return }
        if inFlight >= options.maxInFlight {
            if parked != nil { statSkipped += 1 }
            parked = (pixelBuffer, pts)
            return
        }
        inFlight += 1
        let encodeStart = DispatchTime.now()
        let captureSeconds = pts.seconds
        func sinceCaptureMs() -> Double { (CMClockGetTime(CMClockGetHostTimeClock()).seconds - captureSeconds) * 1000 }
        ageStats.add(sinceCaptureMs())
        encoder.encode(pixelBuffer, pts: pts) { [weak self] frame in
            guard let self else { return }
            let sendStart = DispatchTime.now()
            let encodeMs = Double(sendStart.uptimeNanoseconds - encodeStart.uptimeNanoseconds) / 1e6
            guard let frame else {
                self.queue.async { self.frameFinished() }
                return
            }
            var message = Data()
            if let config = frame.config {
                message.append(frameMessage(.videoConfig, config.encode()))
            }
            var payload = VideoFrameHeader(isKeyframe: frame.isKeyframe, ptsMicros: frame.ptsMicros).encode()
            payload.append(frame.data)
            message.append(frameMessage(.videoFrame, payload))
            let size = message.count
            self.connection.send(content: message, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    if error == nil {
                        let sendMs = Double(DispatchTime.now().uptimeNanoseconds - sendStart.uptimeNanoseconds) / 1e6
                        self.totalStats.add(sinceCaptureMs())
                        self.statFrames += 1; self.statBytes += size
                        self.statEncodeMs += encodeMs; self.statSendMs += sendMs; self.statTimed += 1
                        self.secFrames += 1; self.secEncodeMs += encodeMs; self.secSendMs += sendMs; self.secTimed += 1
                        // Keyframes are many times larger than other frames, so one would read as a slow link.
                        if !frame.isKeyframe { self.winSendMs += sendMs; self.winFrames += 1; self.winBytes += size }
                    }
                    self.frameFinished()
                }
            })
        }
    }

    private func frameFinished() {
        inFlight = max(0, inFlight - 1)
        if inFlight < options.maxInFlight, let waiting = parked {
            parked = nil
            submit(waiting.0, waiting.1)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("Capture stopped: \(error.localizedDescription)")
        queue.async { self.close() }
    }

    // MARK: Heartbeat, bitrate and stats (on queue)

    private func startTimers() {
        let second = DispatchSource.makeTimerSource(queue: queue)
        second.schedule(deadline: .now() + 1, repeating: 1)
        second.setEventHandler { [weak self] in self?.everySecond() }
        second.resume()
        secondTimer = second

        let stats = DispatchSource.makeTimerSource(queue: queue)
        stats.schedule(deadline: .now() + 5, repeating: 5)
        stats.setEventHandler { [weak self] in self?.logStats() }
        stats.resume()
        statsTimer = stats
        startCursor()
    }

    // MARK: Pointer (on queue, shape on main)

    /// The pointer is drawn by the iMac. Its place is sent up to 120 times a second, only when it moved, and its
    /// look is sent when it changes. If the network is behind, positions are skipped instead of queued.
    private func startCursor() {
        let position = DispatchSource.makeTimerSource(queue: queue)
        position.schedule(deadline: .now(), repeating: .milliseconds(8))
        position.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            let point = CGEvent(source: nil)?.location ?? .zero
            guard let message = self.cursorTracker.update(point: point, bounds: CGDisplayBounds(self.virtualDisplayID)) else { return }
            guard self.cursorSendsPending < 50 else { self.cursorTracker.reset(); return }   // sent again once it drains
            self.sendCursor(.cursorPosition, message.encode())
        }
        position.resume()
        cursorTimer = position

        let shape = DispatchSource.makeTimerSource(queue: .main)
        shape.schedule(deadline: .now(), repeating: .milliseconds(50))
        shape.setEventHandler { [weak self] in
            guard let self, !self.mainClosed, let next = StreamSession.currentCursorShape(), next != self.lastCursorShape else { return }
            self.lastCursorShape = next
            self.queue.async { if !self.closed { self.sendCursor(.cursorShape, next.encode()) } }
        }
        shape.resume()
        cursorShapeTimer = shape
    }

    private func sendCursor(_ type: MessageType, _ payload: Data) {
        cursorSendsPending += 1
        connection.send(content: frameMessage(type, payload), completion: .contentProcessed { [weak self] _ in
            self?.queue.async { self?.cursorSendsPending -= 1 }
        })
    }

    /// The system pointer as a PNG. Falls back to the arrow when macOS gives none, so the pointer always shows.
    private static func currentCursorShape() -> CursorShape? {
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let image = cursor.image
        guard image.size.width > 0, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        let scale = UInt8(max(1, min(3, (Double(cg.width) / image.size.width).rounded())))
        return CursorShape(hotspotX: UInt32(max(0, cursor.hotSpot.x * 100)), hotspotY: UInt32(max(0, cursor.hotSpot.y * 100)),
                           scale: scale, png: png)
    }

    private func everySecond() {
        connection.send(content: frameMessage(.heartbeat, Data()), completion: .idempotent)
        inputThisSecond = 0
        let n = Double(max(secTimed, 1))
        state.stats = StreamStats(connected: true, width: Int(hello?.pixelWidth ?? 0), height: Int(hello?.pixelHeight ?? 0),
                                  bitrate: options.adaptBitrate ? controller.current : options.bitrate,
                                  fps: Double(secFrames), encodeMs: secEncodeMs / n, sendMs: secSendMs / n)
        secFrames = 0; secEncodeMs = 0; secSendMs = 0; secTimed = 0
        guard options.adaptBitrate else { return }
        let avg = winSendMs / Double(max(winFrames, 1))
        if let next = controller.update(avgSendMs: avg, frames: winFrames, sentBps: Double(winBytes) * 8) {
            encoder?.setBitrate(next)
            log(String(format: "Bitrate now %d Mbps (frames took %.0f ms to send)", next / 1_000_000, avg))
        }
        winSendMs = 0; winFrames = 0; winBytes = 0
    }

    private func logStats() {
        let idle = statFrames == 0 && statSkipped == 0
        defer {
            statFrames = 0; statBytes = 0; statSkipped = 0
            statEncodeMs = 0; statSendMs = 0; statTimed = 0
            lastStatsIdle = idle
        }
        if idle && lastStatsIdle { return }   // say "idle" once, not every five seconds
        defer { ageStats.reset(); totalStats.reset() }
        if !idle { log("Latency on this Mac: \(ageStats.summary("capture to encode start")); \(totalStats.summary("capture to sent"))") }
        let fps = Double(statFrames) / 5
        let mbps = Double(statBytes) * 8 / 5 / 1_000_000
        let n = Double(max(statTimed, 1))
        log(String(format: "%.1f fps sent, %.1f Mbps, %d stale frames skipped, encode %.0f ms, send %.0f ms, %.0f KB/frame",
                   fps, mbps, statSkipped, statEncodeMs / n, statSendMs / n,
                   Double(statBytes) / Double(max(statFrames, 1)) / 1000))
    }

    /// Safe to call from any thread.
    func stop() {
        queue.async { self.close() }
    }

    /// The person chose Disconnect. The client is told so it stops retrying, then the session closes.
    func end() {
        queue.async {
            guard !self.closed else { return }
            self.connection.send(content: frameMessage(.ended, Data()), completion: .contentProcessed { [weak self] _ in
                self?.queue.async { self?.close() }
            })
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        DispatchQueue.main.async { self.mainClosed = true }
        if started {
            releaseInput()
            state.allowInput = false      // permission is for one connection, so the next one must be allowed again
        }
        state.stats = StreamStats()
        secondTimer?.cancel()
        secondTimer = nil
        statsTimer?.cancel()
        statsTimer = nil
        cursorTimer?.cancel()
        cursorTimer = nil
        let shapeTimer = cursorShapeTimer
        cursorShapeTimer = nil
        DispatchQueue.main.async { shapeTimer?.cancel() }
        parked = nil
        let stream = self.stream
        self.stream = nil
        encoder?.invalidate()
        encoder = nil
        connection.cancel()

        let finish = { [weak self] in
            DispatchQueue.main.async {
                self?.display?.saveArrangement()
                self?.display?.remove()
                self?.display = nil
                self?.onClose?()
            }
        }
        if let stream {
            stream.stopCapture { _ in finish() }
        } else {
            finish()
        }
    }
}
