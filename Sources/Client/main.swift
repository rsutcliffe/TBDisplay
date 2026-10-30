// tbdisplay-client: run on the iMac.
// Finds the MacBook over the Thunderbolt Bridge, tells it the iMac's screen size,
// then decodes and shows the HEVC stream full screen with no buffering.
// Press Esc or Q on the iMac keyboard to quit.

import AppKit
import AVFoundation
import CoreMedia
import IOKit.pwr_mgt
import Network

let usage = """
Usage: tbdisplay-client [options]
  --host ADDRESS      Connect to this address instead of finding the MacBook automatically
  --port N            TCP port (default \(defaultPort))
  --interface NAME    Only use this network interface (default \(defaultInterfaceName))
  --any-interface     Allow any interface, including Wi-Fi (not recommended)
  --windowed          Show in a normal window for testing
  --screen N          Which iMac screen to use (default 0, the main screen)
  --input             Send this Mac's keyboard and mouse to the MacBook (the MacBook must allow it in its menu bar item).
                      Esc and Q then go to the MacBook. Quit with Control-Option-Command-Q.

Pairing: this Mac needs the same pairing key as the MacBook, in the same place. Copy pairing-key from the
MacBook by AirDrop into ~/Library/Application Support/tbdisplay/ on this Mac.
  --check             Print the connection check (what the Check connection button shows) and exit
  --help              Show this help
"""

LogFile.shared = LogFile(url: LogFile.defaultURL(name: "client"))

let args = Arguments(flagNames: ["any-interface", "windowed", "input", "check", "help"])
if args.flag("help") { print(usage); exit(0) }

struct ClientOptions {
    var host: String?
    var port: UInt16 = defaultPort
    var policy: InterfacePolicy = .mode(ConnectionMode.saved())
    var windowed = false
    var screenIndex = 0
    var input = false
}

var options = ClientOptions()
options.host = args.string("host")
if let port = args.int("port") { options.port = UInt16(clamping: port) }
if let name = args.string("interface") { options.policy = .named(name) }
if args.flag("any-interface") { options.policy = .any }
options.windowed = args.flag("windowed")
if let screen = args.int("screen") { options.screenIndex = screen }
if CommandLine.arguments.contains("--pin") {
    log("--pin was removed. Pairing uses a key file now. See --help.")
    exit(1)
}
options.input = args.flag("input")

// --check: the same check as the Check connection button, printed here, for support and for the tests
if args.flag("check") {
    print(DiagnosticsRunner.run(appVersion: appVersion, protocolVersion: protocolVersion, extra: MacBookProbe.run(policy: options.policy)))
    exit(0)
}

// MARK: - Window and video view

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class VideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private let statusLabel = NSTextField(labelWithString: "")
    var onQuit: (() -> Void)?
    var onInput: ((InputEvent) -> Void)?   // set only when --input is on

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)

        statusLabel.textColor = NSColor(white: 0.6, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 22, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        displayLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    // MARK: Keyboard and mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if onInput != nil {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }
    }

    override func keyDown(with event: NSEvent) {
        if onInput != nil {
            let chord: NSEvent.ModifierFlags = [.control, .option, .command]
            if event.modifierFlags.isSuperset(of: chord), event.charactersIgnoringModifiers?.lowercased() == "q" {
                onQuit?()
            } else {
                forward(.keyDown, event)
            }
        } else if event.keyCode == 53 || event.charactersIgnoringModifiers?.lowercased() == "q" {
            onQuit?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) { onInput != nil ? forward(.keyUp, event) : super.keyUp(with: event) }

    override func flagsChanged(with event: NSEvent) {
        guard onInput != nil else { return super.flagsChanged(with: event) }
        // A modifier key arrives as a flags change. Work out whether it went down or up.
        let masks: [UInt16: NSEvent.ModifierFlags] = [54: .command, 55: .command, 56: .shift, 60: .shift,
                                                      58: .option, 61: .option, 59: .control, 62: .control,
                                                      57: .capsLock, 63: .function]
        guard let mask = masks[event.keyCode] else { return }
        forward(event.modifierFlags.contains(mask) ? .keyDown : .keyUp, event)
    }

    override func mouseMoved(with event: NSEvent) { onInput != nil ? forward(.mouseMove, event) : super.mouseMoved(with: event) }
    override func mouseDragged(with event: NSEvent) { onInput != nil ? forward(.mouseMove, event) : super.mouseDragged(with: event) }
    override func rightMouseDragged(with event: NSEvent) { onInput != nil ? forward(.mouseMove, event) : super.rightMouseDragged(with: event) }
    override func otherMouseDragged(with event: NSEvent) { onInput != nil ? forward(.mouseMove, event) : super.otherMouseDragged(with: event) }
    override func mouseDown(with event: NSEvent) { onInput != nil ? forward(.mouseDown, event, button: 0) : super.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { onInput != nil ? forward(.mouseUp, event, button: 0) : super.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { onInput != nil ? forward(.mouseDown, event, button: 1) : super.rightMouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { onInput != nil ? forward(.mouseUp, event, button: 1) : super.rightMouseUp(with: event) }
    override func otherMouseDown(with event: NSEvent) { onInput != nil ? forward(.mouseDown, event, button: 2) : super.otherMouseDown(with: event) }
    override func otherMouseUp(with event: NSEvent) { onInput != nil ? forward(.mouseUp, event, button: 2) : super.otherMouseUp(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard onInput != nil else { return super.scrollWheel(with: event) }
        // Trackpads report pixels. A mouse wheel reports lines, so treat a line as 10 pixels.
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 100 : 1000
        forward(.scroll, event, scrollX: Int32(event.scrollingDeltaX * unit), scrollY: Int32(event.scrollingDeltaY * unit))
    }

    private func forward(_ kind: InputEvent.Kind, _ event: NSEvent, button: UInt8 = 0, scrollX: Int32 = 0, scrollY: Int32 = 0) {
        var e = InputEvent(kind: kind)
        if kind == .mouseMove {
            // Relative movement as a share of this screen, so the MacBook decides where the pointer goes.
            e.dx = Int32(max(-2_000_000, min(2_000_000, event.deltaX / max(bounds.width, 1) * 1_000_000)))
            e.dy = Int32(max(-2_000_000, min(2_000_000, event.deltaY / max(bounds.height, 1) * 1_000_000)))
        }
        e.button = button; e.scrollX = scrollX; e.scrollY = scrollY
        if kind == .keyDown || kind == .keyUp { e.keyCode = UInt32(event.keyCode) }
        e.flags = UInt32(truncatingIfNeeded: event.modifierFlags.rawValue)
        onInput?(e)
    }

    func setStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = (text == nil)
    }
}

// MARK: - Client

final class Client {
    private var options: ClientOptions
    private let hello: Hello
    private let view: VideoView
    private let queue = DispatchQueue(label: "tbdisplay.client", qos: .userInteractive)
    var onModel: ((ClientModel) -> Void)?      // called on the main thread whenever the model changes

    // State on `queue`
    private var model = ClientModel()
    private static let connectTimeout: TimeInterval = 8
    // After Disconnect the client asks the MacBook every so often whether it is allowing connections again.
    // TBDISPLAY_ENDED_POLL_SECONDS lets the tests shorten it.
    private static let endedPollSeconds: TimeInterval = ProcessInfo.processInfo.environment["TBDISPLAY_ENDED_POLL_SECONDS"].flatMap(TimeInterval.init) ?? 30
    private var endedPollStartedAt = Date()
    private var endedPolling = false
    private var browseStartedAt = Date()     // when the current search for the MacBook began
    private var ended = false              // the MacBook said Disconnect: no retrying until the person presses Reconnect
    private var connection: NWConnection?
    private var key = Data()
    private var browser: NWBrowser?
    private var format: CMVideoFormatDescription?
    private var awaitingKeyframe = true
    private var lastKeyframeRequest = Date.distantPast
    private var lastMessage = Date()
    private var gotServerData = false      // heartbeat or video seen on this connection
    private var lastProgress = Date()      // when the MacBook last sent anything, or when the client started
    private var stallReported = false
    private var shownPicture = false
    private var mouseCaptured = false
    private var watchdog: DispatchSourceTimer?
    private var statFrames = 0
    private var statBytes = 0
    private var statsTimer: DispatchSourceTimer?

    init(options: ClientOptions, screen: NSScreen, view: VideoView) {
        self.options = options
        self.view = view
        let scale = screen.backingScaleFactor
        // Report the panel's native pixels, not the current scaled mode, so the stream stays sharp.
        var pixelW = Int(screen.frame.width * scale), pixelH = Int(screen.frame.height * scale)
        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode],
           let native = modes.first(where: { $0.ioFlags & 0x02000000 != 0 }) {   // kDisplayModeNativeFlag
            pixelW = native.pixelWidth
            pixelH = native.pixelHeight
        }
        self.hello = Hello(version: protocolVersion,
                           pixelWidth: UInt32(pixelW),
                           pixelHeight: UInt32(pixelH),
                           scale: UInt32(scale.rounded()),
                           refreshRate: UInt32(max(screen.maximumFramesPerSecond, 60)),
                           appVersion: appVersion)
    }

    private var renderer: AVSampleBufferVideoRenderer { view.displayLayer.sampleBufferRenderer }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.connection != nil, self.statFrames > 0 else { return }
            log(String(format: "%.1f fps received, %.1f Mbps", Double(self.statFrames) / 5,
                       Double(self.statBytes) * 8 / 5 / 1_000_000))
            self.statFrames = 0; self.statBytes = 0
        }
        timer.resume()
        statsTimer = timer

        // The server sends a heartbeat every second. Silence for 4 seconds means the link is dead,
        // which an idle screen alone would never show.
        let dog = DispatchSource.makeTimerSource(queue: queue)
        dog.schedule(deadline: .now() + 1, repeating: 1)
        dog.setEventHandler { [weak self] in
            guard let self else { return }
            // Fifteen seconds with nothing from the MacBook: the window starts giving advice about the cable.
            if !self.stallReported, Date().timeIntervalSince(self.lastProgress) > 15,
               self.model.phase != .streaming, self.model.phase != .waitingForPicture {
                self.stallReported = true
                self.event(.stalled)
            }
            // A search that has found nothing for a while is started afresh: after a cable link returns, Bonjour can
            // stay silent about the Thunderbolt Bridge until the client is restarted.
            if self.ended, !self.endedPolling, self.connection == nil,
               BrowseRefresh.due(startedAt: self.endedPollStartedAt, now: Date(), interval: Client.endedPollSeconds) {
                self.endedPolling = true
                let policy = self.options.policy
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let result = MacBookProbe.run(policy: policy)
                    self?.queue.async {
                        guard let self else { return }
                        self.endedPolling = false
                        self.endedPollStartedAt = Date()
                        if self.ended, ConnectionProbe.canReconnect(result.outcome) {
                            log("The MacBook is allowing connections again. Reconnecting.")
                            self.reconnect()
                        }
                    }
                }
            }
            if self.connection == nil, self.browser != nil, !self.ended,
               BrowseRefresh.due(startedAt: self.browseStartedAt, now: Date()) {
                self.browse()
            }
            guard self.connection != nil,
                  Watchdog.shouldDrop(armed: self.gotServerData, lastMessage: self.lastMessage, now: Date(), limit: 4) else { return }
            log("No data from the MacBook for 4 seconds")
            self.disconnected(nil, lost: true)
        }
        dog.resume()
        watchdog = dog

        queue.async { self.connect() }
    }

    /// With --input the iMac pointer is detached from the screen while connected, so its movement
    /// goes to the MacBook and can run past the edge of this display. It is released when the link drops.
    private func captureMouse(_ on: Bool) {
        guard options.input, on != mouseCaptured else { return }
        mouseCaptured = on
        DispatchQueue.main.async { _ = CGAssociateMouseAndMouseCursorPosition(on ? 0 : 1) }
    }

    func sendInput(_ event: InputEvent) {
        queue.async { [weak self] in
            self?.connection?.send(content: frameMessage(.input, event.encode()), completion: .idempotent)
        }
    }

    /// Feeds an event to the model and tells the window what to show.
    private func event(_ e: ClientEvent) {
        model.handle(e)
        let snapshot = model
        DispatchQueue.main.async { self.onModel?(snapshot) }
    }

    // MARK: Connecting (on queue)

    private func connect() {
        guard !ended else { return }
        // The pairing key is read each time, so copying it in while the client waits is enough.
        guard let loaded = PairingKey.load() else {
            log("No pairing key. Copy pairing-key from the MacBook to \(PairingKey.defaultURL.path)")
            event(.keyMissing)
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in if self?.connection == nil { self?.connect() } }
            return
        }
        key = loaded
        event(.keyFound)
        if let host = options.host {
            let params = makeTCPParameters(key: key)
            if case .named(let name) = options.policy {
                if let iface = findInterface(named: name) {
                    params.requiredInterface = iface
                } else {
                    log("Interface \(name) not found. Connecting to \(host) by normal routing.")
                }
            }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                               port: NWEndpoint.Port(rawValue: options.port) ?? 47800)
            open(endpoint, params: params)
        } else {
            browse()
        }
    }

    private func browse() {
        browser?.cancel()
        browseStartedAt = Date()
        log("Looking for the MacBook \(options.policy.summary)")

        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: makeTCPParameters(key: key))
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil else { return }
            let policy = self.options.policy
            let match: (NWBrowser.Result, NWInterface?)?
            if case .any = policy {
                match = results.first.map { ($0, nil) }
            } else {
                match = results.lazy.compactMap { result -> (NWBrowser.Result, NWInterface?)? in
                    guard let iface = result.interfaces.first(where: { policy.allows(interfaceName: $0.name, kind: interfaceKind($0.type)) }) else { return nil }
                    return (result, iface)
                }.first
                if match == nil, !results.isEmpty {
                    let seen = results.flatMap { $0.interfaces.map(\.name) }
                    log("MacBook found on \(Set(seen).sorted().joined(separator: ", ")) but not \(policy.summary). Check the cable, or change Connect over on both Macs.")
                }
            }
            guard let found = match else { return }
            let (result, iface) = found
            self.browser?.cancel()
            self.browser = nil
            let params = makeTCPParameters(key: key)
            if let iface { params.requiredInterface = iface }
            self.open(result.endpoint, params: params)
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { log("Discovery failed: \(error)") }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func open(_ endpoint: NWEndpoint, params: NWParameters) {
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        event(.connecting)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === conn else { return }
            switch state {
            case .ready:
                guard negotiatedAsExpected(conn) else {
                    log("Refusing the connection: it did not negotiate the expected encryption (\(encryptionSummary(of: conn))).")
                    self.disconnected(nil)
                    return
                }
                log("Connected to \(endpoint) via \(interfaceName(of: conn) ?? "unknown interface"), \(encryptionSummary(of: conn))")
                self.lastMessage = Date()
                self.gotServerData = false
                self.shownPicture = false
                self.sendHello()
                self.requestKeyframe(force: true)
                receiveMessages(on: conn,
                                onMessage: { [weak self] type, payload in self?.handle(type, payload) },
                                onClose: { [weak self] error in self?.disconnected(error) })
            case .failed(let error):
                self.disconnected(error)
            case .waiting(let error):
                log("Waiting to connect: \(error)")
                // macOS leaves a refused connection waiting and may never retry, so retry ourselves.
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.connection === conn else { return }
                    if case .ready = conn.state { return }
                    self.disconnected(error)
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
        // A connection that never gets going (a handshake nobody answers, an address that went stale) waits for ever
        // otherwise, and the client sits on "Connecting..." until it is quit.
        queue.asyncAfter(deadline: .now() + Client.connectTimeout) { [weak self] in
            guard let self, self.connection === conn else { return }
            if case .ready = conn.state { return }
            log("No answer from the MacBook after \(Int(Client.connectTimeout)) seconds. Trying again.")
            self.disconnected(nil)
        }
    }

    private func disconnected(_ error: Error?, lost: Bool = false) {
        guard let conn = connection else { return }
        log("Disconnected\(error.map { ": \($0)" } ?? "")")
        conn.cancel()
        connection = nil
        format = nil
        awaitingKeyframe = true
        renderer.flush(removingDisplayedImage: true) { }
        event(lost ? .lost : .closed(hadData: gotServerData))
        captureMouse(false)
        if gotServerData { lastProgress = Date(); stallReported = false }      // a link that was working starts a fresh wait
        gotServerData = false   // so the watchdog leaves the next attempt alone until it has data
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
    }

    /// The person chose a different way to connect. It is saved, and the search starts again that way.
    func setMode(_ mode: ConnectionMode) {
        mode.save()
        queue.async { [weak self] in
            guard let self else { return }
            self.options.policy = .mode(mode)
            self.ended = false
            log("Connect over: \(mode.title).")
            if self.connection != nil { self.disconnected(nil) } else { self.connect() }
        }
    }

    /// The person pressed Reconnect after the MacBook ended the connection.
    func reconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.ended = false
            self.lastProgress = Date()
            self.stallReported = false
            self.connect()
        }
    }

    private func sendHello() {
        connection?.send(content: frameMessage(.hello, hello.encode()), completion: .idempotent)
    }

    private func requestKeyframe(force: Bool = false) {
        // Avoid flooding the server while waiting for one keyframe to arrive.
        guard force || Date().timeIntervalSince(lastKeyframeRequest) > 0.5 else { return }
        lastKeyframeRequest = Date()
        connection?.send(content: frameMessage(.keyframeRequest, Data()), completion: .idempotent)
    }

    // MARK: Decoding (on queue)

    private func handle(_ rawType: UInt8, _ payload: Data) {
        lastMessage = Date()
        switch MessageType(rawValue: rawType) {
        case .notice:
            let text = String(decoding: payload.prefix(300), as: UTF8.self)
            log("The MacBook says: \(text)")
            event(.refused(text))
        case .ended:
            log("The MacBook ended the connection. Asking every \(Int(Client.endedPollSeconds)) seconds whether it allows connections again.")
            ended = true
            endedPollStartedAt = Date()
            event(.endedByMacBook)
        case .heartbeat:
            markServerData()
        case .videoConfig:
            do {
                let config = try VideoConfig.decode(payload)
                format = makeFormat(config)
                if format == nil { log("Could not read video parameters") }
            } catch {
                log("Bad video config: \(error)")
            }
        case .videoFrame:
            markServerData()
            statFrames += 1
            statBytes += payload.count
            decodeFrame(payload)
        default:
            log("Ignoring message type \(rawType)")
        }
    }

    private func makeFormat(_ config: VideoConfig) -> CMVideoFormatDescription? {
        let buffers: [UnsafeMutablePointer<UInt8>] = config.parameterSets.map { set in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = config.parameterSets.map(\.count)
        let extensions = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        ] as CFDictionary

        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: pointers.count,
            parameterSetPointers: pointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: Int32(config.nalUnitHeaderLength),
            extensions: extensions,
            formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    private func decodeFrame(_ payload: Data) {
        guard payload.count > VideoFrameHeader.size else { return }
        let isKeyframe = payload[payload.startIndex] & 1 == 1
        let frameData = payload.dropFirst(VideoFrameHeader.size)

        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            log("Decoder reset\(renderer.error.map { ": \($0.localizedDescription)" } ?? "")")
            renderer.flush()
            awaitingKeyframe = true
        }
        if awaitingKeyframe && !isKeyframe {
            requestKeyframe()
            return
        }
        guard let format else {
            requestKeyframe()
            return
        }

        // Copy the frame into a block buffer the decoder owns.
        let length = frameData.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return }
        let copyStatus = frameData.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        var sample: CMSampleBuffer?
        var sampleSize = length
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
              let sample else { return }

        // Show each frame as soon as it is decoded, with no presentation clock or buffering.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        renderer.enqueue(sample)
        if isKeyframe { awaitingKeyframe = false }
        if !shownPicture {
            shownPicture = true
            event(.pictureShown)
        }
    }

    /// The first heartbeat or frame of a connection tells the model the MacBook is really talking.
    private func markServerData() {
        guard !gotServerData else { return }
        gotServerData = true
        lastProgress = Date()
        stallReported = false
        captureMouse(true)
        event(.dataReceived)
    }
}

// MARK: - Start up

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let screens = NSScreen.screens
guard !screens.isEmpty else { log("No screen found"); exit(1) }
let screen = screens[min(max(options.screenIndex, 0), screens.count - 1)]

let window: NSWindow
if options.windowed {
    window = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
    window.title = "tbdisplay"
    window.center()
} else {
    window = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
    window.setFrame(screen.frame, display: true)
    window.level = .screenSaver
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
}
window.backgroundColor = .black
window.isReleasedWhenClosed = false

let videoView = VideoView(frame: window.contentLayoutRect)
videoView.autoresizingMask = [.width, .height]
window.acceptsMouseMovedEvents = options.input
videoView.onQuit = {
    log("Quitting")
    _ = CGAssociateMouseAndMouseCursorPosition(1)   // give the iMac pointer back
    NSApp.terminate(nil)
}
NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
    _ = CGAssociateMouseAndMouseCursorPosition(1)
}
window.contentView = videoView
window.makeFirstResponder(videoView)

// Outside --windowed there are two things to show: the setup window while nothing is streaming, and the
// full-screen picture once it is. The model decides which.
let setupWindow: SetupWindow? = options.windowed ? nil : SetupWindow()
UpdateController.shared.checkAtLaunchIfDue()
setupWindow?.onQuit = videoView.onQuit
var cursorHidden = false
let displayAwake = DisplayAwake()      // held only while a picture is streaming
func present(_ model: ClientModel) {
    displayAwake.set(model.keepsDisplayAwake)
    guard let setupWindow else {
        videoView.setStatus(model.statusMessage.isEmpty ? nil : model.statusMessage)
        return
    }
    setupWindow.update(model)
    switch model.presentation {
    case .fullScreen:
        setupWindow.window.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(videoView)
        if !cursorHidden { cursorHidden = true; _ = CGDisplayHideCursor(CGMainDisplayID()) }
    case .setupWindow:
        window.orderOut(nil)
        if cursorHidden { cursorHidden = false; _ = CGDisplayShowCursor(CGMainDisplayID()) }
        setupWindow.window.makeKeyAndOrderFront(nil)
    }
    app.activate(ignoringOtherApps: true)
}
if options.windowed { window.makeKeyAndOrderFront(nil) }
let reportWindow = ReportWindow()
reportWindow.extra = { MacBookProbe.run(policy: options.policy) }
setupWindow?.onCheck = { reportWindow.show() }
let pairingController = PairingGuestController()
pairingController.onChange = { setupWindow?.pairing = $0 }
if let setupWindow {
    setupWindow.onPairingAnswer = { pairingController.answer($0) }
    setupWindow.pairButton.target = pairingController
    setupWindow.pairButton.action = #selector(PairingGuestController.pairPressed)
}
let checklistWindow = ChecklistWindow(role: .client) { action in
    switch action {
    case .openSettings(let url): NSWorkspace.shared.open(url)
    case .startPairing: pairingController.start()
    case .checkConnection: reportWindow.show()
    }
}
present(ClientModel())
if setupWindow != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { checklistWindow.showIfNeeded() } }

PowerLog.start()

// A minimal menu so Cmd-Q works.
let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
let quitItem = NSMenuItem(title: "Quit tbdisplay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
// With --input, plain Command-Q belongs to the MacBook.
if options.input { quitItem.keyEquivalentModifierMask = [.control, .option, .command] }
appMenu.addItem(quitItem)
appItem.submenu = appMenu
app.mainMenu = mainMenu

let client = Client(options: options, screen: screen, view: videoView)
client.onModel = present
setupWindow?.onReconnect = { client.reconnect() }
setupWindow?.onModeChange = { client.setMode($0) }
if options.input { videoView.onInput = { client.sendInput($0) } }
client.start()

app.run()
