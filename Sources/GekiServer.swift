import Foundation
import Network
import ImageIO
import QuartzCore

struct LinkStats {
    var fps = 0
    var dropped = 0
    var decodeMs = 0.0
    var rttMs = 0.0
    var pcMs = 0.0
    var frameKB = 0
}

/// Listens on a TCP port. The PC reaches it through the USB cable (usbmuxd), so nothing here touches Wi-Fi.
/// App -> PC (text lines, '\n' terminated):
///   "L<signed int>" lever position, "G" + 10 bits (left btn1,btn2,btn3,side,menu; right same) game buttons,
///   "X" + 4 bits (test,service,coin,card), "V<width>,<quality>" asks for the game picture ("V0" = off), "P<id>" ping.
/// PC -> app: frames, each [UInt32 little-endian length][bytes]. A length with the top bit set is a short ASCII
/// control message ("O<id>" ping answer, "T<pcMs>,<fps>" capture timing); otherwise the bytes are a JPEG picture.
final class GekiServer {
    static let port: UInt16 = 24880

    var onStatus: ((Bool) -> Void)?
    var onFrame: ((CGImage) -> Void)?
    var onStats: ((LinkStats) -> Void)?

    private let queue = DispatchQueue(label: "gekipad.server")
    private let decodeQueue = DispatchQueue(label: "gekipad.decode")
    private var listener: NWListener?
    private var conn: NWConnection?
    private var lastLever = "L0"
    private var lastG = "G0000000000"
    private var lastX = "X0000"
    private var videoWanted = Settings.shared.videoOn
    private var inbox = Data()
    private var decoding = false
    private var pendingJpeg: Data?

    private var timer: DispatchSourceTimer?
    private var framesThisSec = 0
    private var droppedThisSec = 0
    private var bytesThisSec = 0
    private var decodeMsSum = 0.0
    private var decodeCount = 0
    private var rttMs = 0.0
    private var pcMs = 0.0
    private var stallSeconds = 0

    func start() {
        queue.async {
            self.startListener()
            self.startTimer()
        }
    }

    func setLever(_ pos: Int) {
        queue.async {
            self.lastLever = "L\(pos)"
            self.sendLine(self.lastLever)
        }
    }

    func setGameButtons(_ bits: String) {
        queue.async {
            self.lastG = "G" + bits
            self.sendLine(self.lastG)
        }
    }

    func setExtraButtons(_ bits: String) {
        queue.async {
            self.lastX = "X" + bits
            self.sendLine(self.lastX)
        }
    }

    func setVideo(_ on: Bool) {
        queue.async {
            self.videoWanted = on
            self.sendVideoRequest()
        }
    }

    func videoSettingsChanged() {
        queue.async { self.sendVideoRequest() }
    }

    private func sendVideoRequest() {
        let st = Settings.shared
        guard videoWanted else { sendLine("V0"); return }
        sendLine("V\(st.videoWidth),\(st.videoQuality)")
    }

    private func startListener() {
        listener?.cancel()
        listener = nil
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: GekiServer.port),
              let l = try? NWListener(using: params, on: port) else {
            queue.asyncAfter(deadline: .now() + 2) { self.startListener() }
            return
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.queue.asyncAfter(deadline: .now() + 2) { self?.startListener() }
            }
        }
        listener = l
        l.start(queue: queue)
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if conn != nil { sendLine("P\(Int(CACurrentMediaTime() * 1_000_000))") }
        let decode = decodeCount > 0 ? decodeMsSum / Double(decodeCount) : 0
        let kb = framesThisSec > 0 ? bytesThisSec / framesThisSec / 1024 : 0
        let stats = LinkStats(fps: framesThisSec, dropped: droppedThisSec, decodeMs: decode, rttMs: rttMs, pcMs: pcMs, frameKB: kb)
        if conn != nil && videoWanted && framesThisSec == 0 {
            stallSeconds += 1
            if stallSeconds >= 3 { stallSeconds = 0; sendVideoRequest() }
        } else {
            stallSeconds = 0
        }
        framesThisSec = 0; droppedThisSec = 0; bytesThisSec = 0; decodeMsSum = 0; decodeCount = 0
        DispatchQueue.main.async { self.onStats?(stats) }
    }

    private func accept(_ c: NWConnection) {
        conn?.cancel()
        conn = c
        inbox = Data()
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self = self, let c = c, c === self.conn else { return }
            switch state {
            case .ready:
                self.report(true)
                self.sendLine(self.lastLever)
                self.sendLine(self.lastG)
                self.sendLine(self.lastX)
                self.sendVideoRequest()
            case .failed, .cancelled:
                self.conn = nil
                self.report(false)
            default: break
            }
        }
        c.start(queue: queue)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data, _, isComplete, error in
            guard let self = self, let c = c else { return }
            if let data = data, !data.isEmpty, c === self.conn {
                self.inbox.append(data)
                self.drainFrames()
            }
            if isComplete || error != nil {
                if c === self.conn { self.conn = nil; self.report(false) }
                c.cancel()
            } else {
                self.receive(c)
            }
        }
    }

    private func drainFrames() {
        var newest: Data?
        while inbox.count >= 4 {
            let raw = UInt32(inbox[0]) | (UInt32(inbox[1]) << 8) | (UInt32(inbox[2]) << 16) | (UInt32(inbox[3]) << 24)
            let isControl = (raw & 0x8000_0000) != 0
            let len = Int(raw & 0x7FFF_FFFF)
            if len <= 0 || len > 4_000_000 { inbox = Data(); return }
            if inbox.count < 4 + len { break }
            let payload = inbox.subdata(in: 4..<(4 + len))
            inbox = inbox.subdata(in: (4 + len)..<inbox.count)
            if isControl {
                handleControl(payload)
            } else {
                framesThisSec += 1
                bytesThisSec += payload.count
                if newest != nil { droppedThisSec += 1 }
                newest = payload
            }
        }
        if let jpeg = newest { decode(jpeg) }
    }

    private func handleControl(_ payload: Data) {
        guard let text = String(data: payload, encoding: .ascii), let kind = text.first else { return }
        let rest = String(text.dropFirst())
        if kind == "O", let sent = Double(rest) {
            rttMs = (CACurrentMediaTime() * 1_000_000 - sent) / 1000
        } else if kind == "T", let first = rest.split(separator: ",").first, let ms = Double(first) {
            pcMs = ms
        }
    }

    private func decode(_ jpeg: Data) {
        if pendingJpeg != nil { droppedThisSec += 1 }
        pendingJpeg = jpeg
        if decoding { return }
        decoding = true
        decodeQueue.async {
            while true {
                var next: Data?
                self.queue.sync {
                    next = self.pendingJpeg
                    self.pendingJpeg = nil
                    if next == nil { self.decoding = false }
                }
                guard let jpg = next else { return }
                let started = CACurrentMediaTime()
                let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                if let src = CGImageSourceCreateWithData(jpg as CFData, nil),
                   let img = CGImageSourceCreateImageAtIndex(src, 0, opts) {
                    let ms = (CACurrentMediaTime() - started) * 1000
                    self.queue.async { self.decodeMsSum += ms; self.decodeCount += 1 }
                    self.onFrame?(img)
                }
            }
        }
    }

    private func sendLine(_ line: String) {
        guard let c = conn, let data = (line + "\n").data(using: .utf8) else { return }
        c.send(content: data, completion: .contentProcessed({ _ in }))
    }

    private func report(_ connected: Bool) {
        DispatchQueue.main.async { self.onStatus?(connected) }
    }
}
