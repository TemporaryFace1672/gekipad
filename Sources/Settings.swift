import Foundation

/// User settings, saved between launches.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private func num(_ key: String, _ def: Double) -> Double {
        return d.object(forKey: key) == nil ? def : d.double(forKey: key)
    }

    private func flag(_ key: String, _ def: Bool) -> Bool {
        return d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }

    // video (the game's own picture, full window - no ring/mask like maimai)
    var videoOn: Bool {
        get { return flag("videoOn", true) }
        set { d.set(newValue, forKey: "videoOn") }
    }
    var videoWidth: Int {
        get { return Int(num("videoWidth", 1280)) }
        set { d.set(newValue, forKey: "videoWidth") }
    }
    var videoQuality: Int {
        get { return Int(num("videoQuality", 75)) }
        set { d.set(newValue, forKey: "videoQuality") }
    }

    // overlay
    var controlsOpacity: Double {
        get { return num("controlsOpacity", 0.55) }
        set { d.set(newValue, forKey: "controlsOpacity") }
    }
    var glowOpacity: Double {
        get { return num("glowOpacity", 0.9) }
        set { d.set(newValue, forKey: "glowOpacity") }
    }
    var leftHanded: Bool {
        get { return flag("leftHanded", false) }
        set { d.set(newValue, forKey: "leftHanded") }
    }

    // lever
    var leverSensitivity: Double {   // 1.0 = 1:1 with finger travel; higher = less finger travel needed for full swing
        get { return num("leverSensitivity", 1.3) }
        set { d.set(newValue, forKey: "leverSensitivity") }
    }

    // sound
    var soundOn: Bool {
        get { return flag("soundOn", false) }
        set { d.set(newValue, forKey: "soundOn") }
    }
    var soundVolume: Double {
        get { return num("soundVolume", 0.5) }
        set { d.set(newValue, forKey: "soundVolume") }
    }

    // info
    var showReadout: Bool {
        get { return flag("showReadout", false) }
        set { d.set(newValue, forKey: "showReadout") }
    }

    // custom background photo (shown behind the picture when video is off)
    var customBackgroundOn: Bool {
        get { return flag("customBackgroundOn", false) }
        set { d.set(newValue, forKey: "customBackgroundOn") }
    }
    static var backgroundURL: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("background.jpg")
    }
    var hasBackgroundFile: Bool {
        return FileManager.default.fileExists(atPath: Settings.backgroundURL.path)
    }

    func reset() {
        for k in ["videoOn", "videoWidth", "videoQuality", "controlsOpacity", "glowOpacity", "leftHanded",
                  "leverSensitivity", "soundOn", "soundVolume", "showReadout", "customBackgroundOn"] {
            d.removeObject(forKey: k)
        }
    }
}
