import UIKit

/// Draws the ONGEKI controls over the game picture: a lever strip, two 3-button clusters (each with a SIDE and a
/// MENU button), and small Test/Service/Coin/Card/Settings/Video buttons. Landscape only, to match the cabinet.
final class GekiPadView: UIView {
    var onLever: ((Int) -> Void)?
    var onGameButtons: ((String) -> Void)?     // 10 bits: left btn1,btn2,btn3,side,menu, then right same
    var onExtraButtons: ((String) -> Void)?    // 4 bits: test, service, coin, card
    var onVideoToggle: ((Bool) -> Void)?
    var onVideoSettingsChanged: (() -> Void)?
    var onPickBackground: (() -> Void)?

    private let settings = Settings.shared
    private let click = ClickPlayer()

    // game button order: 0=btn1 1=btn2 2=btn3 3=side 4=menu (left), 5..9 same for right.
    // Layout (per the reference sketch): SIDE = a tall bar at the outer edge of the screen; MENU = a small square
    // flanking the lever directly; 1/2/3 = a horizontal row near the bottom, each cluster with a gap between them.
    private let gameLabels = ["1", "2", "3", "SIDE", "MENU", "1", "2", "3", "SIDE", "MENU"]
    private let gameColors: [UIColor] = [
        UIColor(red: 1.0, green: 0.34, blue: 0.34, alpha: 1),   // 0 left btn1 red
        UIColor(red: 0.36, green: 0.88, blue: 0.44, alpha: 1),  // 1 left btn2 green
        UIColor(red: 0.35, green: 0.58, blue: 1.0, alpha: 1),   // 2 left btn3 blue
        UIColor(red: 0.62, green: 0.24, blue: 0.72, alpha: 1),  // 3 left side (purple)
        UIColor(red: 0.55, green: 0.08, blue: 0.14, alpha: 1),  // 4 left menu (maroon)
        UIColor(red: 1.0, green: 0.34, blue: 0.34, alpha: 1),   // 5 right btn1 red
        UIColor(red: 0.36, green: 0.88, blue: 0.44, alpha: 1),  // 6 right btn2 green
        UIColor(red: 0.35, green: 0.58, blue: 1.0, alpha: 1),   // 7 right btn3 blue
        UIColor(red: 0.62, green: 0.24, blue: 0.72, alpha: 1),  // 8 right side (purple)
        UIColor(red: 0.95, green: 0.8, blue: 0.25, alpha: 1)    // 9 right menu (gold)
    ]
    private let extraTitles = ["TEST", "SERVICE", "COIN", "CARD"]

    private let videoLayer = CALayer()
    private let backgroundLayer = CALayer()
    private var gotFrame = false
    private var pendingFrame: CGImage?
    private let frameLock = NSLock()
    private var frameScheduled = false
    private var videoOn = true
    private var backgroundImage: UIImage?

    private let leverTrack = CAShapeLayer()
    private let leverFill = CAShapeLayer()
    private let leverHandle = CAShapeLayer()
    private var leverRect = CGRect.zero
    private var leverValue: CGFloat = 0          // -1..1
    private weak var leverTouch: UITouch?

    private var gameButtonViews: [UIButton] = []
    private var gameButtonFrames = [CGRect](repeating: .zero, count: 10)
    private var gameOn = [Bool](repeating: false, count: 10)
    private var gameTouches: [ObjectIdentifier: Int] = [:]

    private var extraButtonViews: [UILabel] = []
    private var extraFrames = [CGRect](repeating: .zero, count: 4)
    private var extraOn = [Bool](repeating: false, count: 4)
    private var extraTouches: [ObjectIdentifier: Int] = [:]

    private let toggleLabel = UILabel()
    private let settingsLabel = UILabel()
    private var toggleFrame = CGRect.zero
    private var settingsFrame = CGRect.zero
    private let statusLabel = UILabel()
    private var connected = false
    private var lastStats = LinkStats()
    private var panel: SettingsPanel?

    private var lastG = "", lastX = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = UIColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1)
        isMultipleTouchEnabled = true
        videoOn = settings.videoOn

        backgroundLayer.contentsGravity = .resizeAspectFill
        backgroundLayer.masksToBounds = true
        layer.addSublayer(backgroundLayer)

        videoLayer.contentsGravity = .resizeAspect
        videoLayer.masksToBounds = true
        videoLayer.isHidden = true
        layer.addSublayer(videoLayer)

        leverTrack.fillColor = UIColor(red: 0.09, green: 0.1, blue: 0.15, alpha: 1).cgColor
        leverTrack.strokeColor = UIColor(red: 0.3, green: 0.34, blue: 0.46, alpha: 1).cgColor
        leverTrack.lineWidth = 2
        layer.addSublayer(leverTrack)
        leverFill.fillColor = UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.35).cgColor
        layer.addSublayer(leverFill)
        leverHandle.fillColor = UIColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1).cgColor
        leverHandle.strokeColor = UIColor.white.cgColor
        leverHandle.lineWidth = 2
        layer.addSublayer(leverHandle)

        for i in 0..<10 {
            let b = UIButton(type: .custom)
            let isSideOrMenu = i % 5 >= 3
            b.setTitle(isSideOrMenu ? "" : gameLabels[i], for: .normal)
            b.titleLabel?.font = UIFont.systemFont(ofSize: 22, weight: .bold)
            b.setTitleColor(.black, for: .normal)
            b.backgroundColor = gameColors[i]
            b.isUserInteractionEnabled = false
            addSubview(b)
            gameButtonViews.append(b)
        }

        for i in 0..<4 {
            let l = UILabel()
            l.text = extraTitles[i]
            styleUtilityLabel(l)
            addSubview(l)
            extraButtonViews.append(l)
        }
        for l in [toggleLabel, settingsLabel] { styleUtilityLabel(l) ; addSubview(l) }
        settingsLabel.text = "SETTINGS"
        updateToggleLabel()

        statusLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusLabel.numberOfLines = 0
        statusLabel.isUserInteractionEnabled = false
        addSubview(statusLabel)
        setConnected(false)
        loadBackgroundImage()
    }

    private func styleUtilityLabel(_ l: UILabel) {
        l.textAlignment = .center
        l.textColor = .white
        l.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        l.backgroundColor = UIColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1)
        l.layer.cornerRadius = 8
        l.layer.borderWidth = 2
        l.layer.borderColor = UIColor(red: 0.2, green: 0.23, blue: 0.36, alpha: 1).cgColor
        l.clipsToBounds = true
        l.isUserInteractionEnabled = false
    }

    // MARK: status / background / video (same pattern as MaiPad)

    func setConnected(_ c: Bool) {
        connected = c
        if !c && gotFrame {
            gotFrame = false
            videoLayer.isHidden = true
        }
        updateStatusText()
    }

    func showStats(_ s: LinkStats) {
        lastStats = s
        updateStatusText()
    }

    private func updateStatusText() {
        var text = connected ? "PC connected" : "Waiting for PC (USB)"
        statusLabel.textColor = connected ? UIColor(red: 0.36, green: 0.88, blue: 0.54, alpha: 1) : UIColor(red: 1, green: 0.42, blue: 0.42, alpha: 1)
        if settings.showReadout && connected {
            let s = lastStats
            let refreshMs = 1000.0 / Double(max(UIScreen.main.maximumFramesPerSecond, 1))
            let estimate = s.pcMs + s.rttMs / 2 + s.decodeMs + refreshMs / 2
            text += String(format: "\nvideo %ld fps  %ld KB/frame  dropped %ld", s.fps, s.frameKB, s.dropped)
            text += String(format: "\nUSB round trip %.1f ms", s.rttMs)
            text += String(format: "\nPC capture+encode %.1f ms  decode %.1f ms", s.pcMs, s.decodeMs)
            if videoOn && s.fps > 0 { text += String(format: "\nvideo delay ~%.0f ms (estimate)", estimate) }
        }
        statusLabel.text = text
        setNeedsLayout()
    }

    private func loadBackgroundImage() {
        backgroundImage = settings.customBackgroundOn ? UIImage(contentsOfFile: Settings.backgroundURL.path) : nil
        backgroundLayer.contents = backgroundImage?.cgImage
    }

    func backgroundSettingChanged() {
        loadBackgroundImage()
        panel?.updateBackgroundStatus()
    }

    func showFrame(_ img: CGImage) {
        frameLock.lock()
        pendingFrame = img
        let schedule = !frameScheduled
        frameScheduled = true
        frameLock.unlock()
        if !schedule { return }
        DispatchQueue.main.async {
            self.frameLock.lock()
            let f = self.pendingFrame
            self.pendingFrame = nil
            self.frameScheduled = false
            self.frameLock.unlock()
            guard let frame = f, self.videoOn else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.videoLayer.contents = frame
            self.videoLayer.isHidden = false
            CATransaction.commit()
            self.gotFrame = true
        }
    }

    private func updateToggleLabel() {
        toggleLabel.text = videoOn ? "VIDEO ON" : "VIDEO OFF"
        toggleLabel.textColor = videoOn ? .black : .white
        toggleLabel.backgroundColor = videoOn ? UIColor(red: 0.3, green: 0.88, blue: 1.0, alpha: 1) : UIColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1)
    }

    private func setVideoOn(_ on: Bool) {
        videoOn = on
        settings.videoOn = on
        if !on { gotFrame = false; videoLayer.isHidden = true; videoLayer.contents = nil }
        updateToggleLabel()
        updateStatusText()
        onVideoToggle?(on)
    }

    // MARK: settings

    private func openSettings() {
        panel?.removeFromSuperview()
        leverTouch = nil; leverValue = 0; sendLever()
        gameTouches.removeAll(); recomputeGame()
        extraTouches.removeAll(); recomputeExtra()
        let p = SettingsPanel(frame: bounds)
        p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        p.onClose = { [weak self] in self?.panel?.removeFromSuperview(); self?.panel = nil }
        p.onChanged = { [weak self] in self?.setNeedsLayout(); self?.updateStatusText() }
        p.onVideoParamsCommitted = { [weak self] in self?.onVideoSettingsChanged?() }
        p.onVideoSwitch = { [weak self] on in self?.setVideoOn(on) }
        p.onBackgroundSwitch = { [weak self] _ in self?.backgroundSettingChanged() }
        p.onPickBackground = { [weak self] in self?.onPickBackground?() }
        p.onRemoveBackground = { [weak self] in
            try? FileManager.default.removeItem(at: Settings.backgroundURL)
            self?.backgroundSettingChanged()
        }
        p.onReset = { [weak self] in
            Settings.shared.reset()
            self?.videoOn = Settings.shared.videoOn
            self?.updateToggleLabel()
            self?.loadBackgroundImage()
            self?.setNeedsLayout()
            self?.updateStatusText()
            self?.onVideoSettingsChanged?()
            self?.onVideoToggle?(Settings.shared.videoOn)
            self?.openSettings()
        }
        addSubview(p)
        panel = p
    }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = bounds.inset(by: safeAreaInsets)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        videoLayer.frame = safe
        CATransaction.commit()

        let margin: CGFloat = 10
        var left = [0, 1, 2, 3, 4], right = [5, 6, 7, 8, 9]
        if settings.leftHanded { swap(&left, &right) }

        // SIDE buttons: tall bars at the very outer edges of the screen.
        let sideW = max(48, safe.width * 0.05)
        let sideInsetY = safe.height * 0.08
        let leftSideF = CGRect(x: safe.minX, y: safe.minY + sideInsetY, width: sideW, height: safe.height - sideInsetY * 2)
        let rightSideF = CGRect(x: safe.maxX - sideW, y: safe.minY + sideInsetY, width: sideW, height: safe.height - sideInsetY * 2)
        place(left[3], leftSideF, radius: 6)
        place(right[3], rightSideF, radius: 6)

        // The lever + its two MENU buttons sit in a band in the upper-middle area, between the side bars.
        let midLeft = safe.minX + sideW + margin
        let midRight = safe.maxX - sideW - margin
        let midWidth = midRight - midLeft
        let leverBandH = max(44, safe.height * 0.075)
        let leverBandY = safe.minY + safe.height * 0.22
        let menuW = max(44, midWidth * 0.07)
        let leftMenuF = CGRect(x: midLeft, y: leverBandY, width: menuW, height: leverBandH)
        let rightMenuF = CGRect(x: midRight - menuW, y: leverBandY, width: menuW, height: leverBandH)
        place(left[4], leftMenuF, radius: 8)
        place(right[4], rightMenuF, radius: 8)
        leverRect = CGRect(x: leftMenuF.maxX + margin, y: leverBandY, width: rightMenuF.minX - leftMenuF.maxX - margin * 2, height: leverBandH)

        // The two 1/2/3 button rows sit near the bottom, each a horizontal row, with a gap between the clusters.
        let rowH = max(80, safe.height * 0.165)
        let rowY = safe.minY + safe.height * 0.64
        let clusterW = midWidth * 0.30
        placeRow(indices: [left[0], left[1], left[2]], x: midLeft, w: clusterW, y: rowY, h: rowH, gap: margin)
        placeRow(indices: [right[0], right[1], right[2]], x: midRight - clusterW, w: clusterW, y: rowY, h: rowH, gap: margin)

        // Small utility buttons along the very top, between the side bars, above the lever band.
        let uw: CGFloat = 84, uh: CGFloat = 34
        let utilY = safe.minY + margin
        for i in 0..<4 {
            let f = CGRect(x: safe.midX - (uw * 4 + margin * 3) / 2 + CGFloat(i) * (uw + margin), y: utilY, width: uw, height: uh)
            extraFrames[i] = f
            extraButtonViews[i].frame = f
        }
        toggleLabel.frame = CGRect(x: safe.midX - uw - margin / 2, y: utilY + uh + 6, width: uw, height: uh)
        settingsLabel.frame = CGRect(x: safe.midX + margin / 2, y: utilY + uh + 6, width: uw, height: uh)
        toggleFrame = toggleLabel.frame.insetBy(dx: -4, dy: -4)
        settingsFrame = settingsLabel.frame.insetBy(dx: -4, dy: -4)

        CATransaction.begin(); CATransaction.setDisableActions(true)
        leverTrack.path = UIBezierPath(roundedRect: leverRect, cornerRadius: leverRect.height / 2).cgPath
        CATransaction.commit()
        layoutLever()

        let maxW = max(safe.width - 20, 100)
        let fit = statusLabel.sizeThatFits(CGSize(width: maxW, height: .greatestFiniteMagnitude))
        statusLabel.frame = CGRect(x: safe.minX + 10, y: safe.maxY - fit.height - margin, width: fit.width, height: fit.height)
    }

    private func place(_ index: Int, _ frame: CGRect, radius: CGFloat) {
        gameButtonFrames[index] = frame
        gameButtonViews[index].frame = frame
        gameButtonViews[index].layer.cornerRadius = radius
    }

    private func placeRow(indices: [Int], x: CGFloat, w: CGFloat, y: CGFloat, h: CGFloat, gap: CGFloat) {
        let bw = (w - gap * 2) / 3
        for (k, idx) in indices.enumerated() {
            let f = CGRect(x: x + CGFloat(k) * (bw + gap), y: y, width: bw, height: h)
            place(idx, f, radius: 10)
        }
    }

    private func layoutLever() {
        let r = leverRect.height / 2 - 4
        let cx = leverRect.midX + leverValue * (leverRect.width / 2 - r - 4)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        leverFill.path = UIBezierPath(rect: CGRect(x: leverRect.midX, y: leverRect.minY, width: cx - leverRect.midX, height: leverRect.height)).cgPath
        leverHandle.path = UIBezierPath(ovalIn: CGRect(x: cx - r, y: leverRect.midY - r, width: r * 2, height: r * 2)).cgPath
        CATransaction.commit()
    }

    // MARK: colours

    private func render() {
        let op = CGFloat(settings.controlsOpacity)
        let glow = CGFloat(settings.glowOpacity)
        for i in 0..<10 {
            let base = gameColors[i]
            gameButtonViews[i].backgroundColor = base.withAlphaComponent(gameOn[i] ? glow : op)
        }
        for i in 0..<4 {
            let on = extraOn[i]
            extraButtonViews[i].backgroundColor = on ? UIColor(red: 0.3, green: 0.88, blue: 1.0, alpha: 1) : UIColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1)
            extraButtonViews[i].textColor = on ? .black : .white
        }
    }

    // MARK: touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            if toggleFrame.contains(p) { setVideoOn(!videoOn); continue }
            if settingsFrame.contains(p) { openSettings(); return }
            if leverTouch == nil && leverRect.insetBy(dx: -10, dy: -10).contains(p) {
                leverTouch = t
                updateLever(from: p)
                continue
            }
            var placed = false
            for i in 0..<10 where gameButtonFrames[i].insetBy(dx: -4, dy: -4).contains(p) {
                gameTouches[ObjectIdentifier(t)] = i; placed = true; break
            }
            if placed { continue }
            for i in 0..<4 where extraFrames[i].insetBy(dx: -4, dy: -4).contains(p) {
                extraTouches[ObjectIdentifier(t)] = i; break
            }
        }
        recomputeGame(); recomputeExtra()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let lt = leverTouch, touches.contains(lt) { updateLever(from: lt.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    private func endTouches(_ touches: Set<UITouch>) {
        for t in touches {
            if t === leverTouch { leverTouch = nil }   // lever holds its last position, no snap-back
            gameTouches.removeValue(forKey: ObjectIdentifier(t))
            extraTouches.removeValue(forKey: ObjectIdentifier(t))
        }
        recomputeGame(); recomputeExtra()
    }

    private func updateLever(from p: CGPoint) {
        let half = leverRect.width / 2
        var v = (p.x - leverRect.midX) / half
        v = max(-1, min(1, v * CGFloat(settings.leverSensitivity)))
        leverValue = v
        layoutLever()
        onLever?(Int((v * 32767).rounded()))
    }

    private func sendLever() {
        layoutLever()
        onLever?(Int((leverValue * 32767).rounded()))
    }

    private func recomputeGame() {
        var on = [Bool](repeating: false, count: 10)
        for i in gameTouches.values { on[i] = true }
        let changed = on != gameOn
        let wasOn = gameOn
        gameOn = on
        render()
        if !changed { return }
        if settings.soundOn {
            for i in 0..<10 where on[i] && !wasOn[i] { click.click(volume: Float(settings.soundVolume)); break }
        }
        let bits = on.map { $0 ? "1" : "0" }.joined()
        if bits != lastG { lastG = bits; onGameButtons?(bits) }
    }

    private func recomputeExtra() {
        var on = [Bool](repeating: false, count: 4)
        for i in extraTouches.values { on[i] = true }
        let wasOn = extraOn
        extraOn = on
        render()
        if settings.soundOn {
            for i in 0..<4 where on[i] && !wasOn[i] { click.click(volume: Float(settings.soundVolume)); break }
        }
        let bits = on.map { $0 ? "1" : "0" }.joined()
        if bits != lastX { lastX = bits; onExtraButtons?(bits) }
    }
}
