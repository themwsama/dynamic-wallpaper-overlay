// Persisted user settings, backed by UserDefaults and shared across the overlay.
import Foundation

// TransitionStyle.stormRewind; main.swift falls back to the same value for unknown raws
let DEFAULT_TRANSITION_STYLE_RAW = 1

// Raw values are the on-disk UserDefaults keys; existing ones must never be renamed
enum SettingKey: String, CaseIterable {
    case clockVisible, effectsVisible, transitionStyle
    case musicGlowEnabled, lyricsEnabled, romajiEnabled
}

final class Settings {
    private let defaults: UserDefaults
    private var observers: [UUID: (SettingKey) -> Void] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isClockVisible: Bool {
        get { bool(.clockVisible, default: true) }
        set { setBool(.clockVisible, newValue, default: true) }
    }

    var isEffectsVisible: Bool {
        get { bool(.effectsVisible, default: true) }
        set { setBool(.effectsVisible, newValue, default: true) }
    }

    // Raw value of the transition style enum, which lives elsewhere
    var transitionStyleRaw: Int {
        get { (defaults.object(forKey: SettingKey.transitionStyle.rawValue) as? Int) ?? DEFAULT_TRANSITION_STYLE_RAW }
        set {
            guard newValue != transitionStyleRaw else { return }
            defaults.set(newValue, forKey: SettingKey.transitionStyle.rawValue)
            notify(.transitionStyle)
        }
    }

    var isMusicGlowEnabled: Bool {
        get { bool(.musicGlowEnabled, default: true) }
        set { setBool(.musicGlowEnabled, newValue, default: true) }
    }

    var isLyricsEnabled: Bool {
        get { bool(.lyricsEnabled, default: true) }
        set { setBool(.lyricsEnabled, newValue, default: true) }
    }

    var isRomajiEnabled: Bool {
        get { bool(.romajiEnabled, default: false) }
        set { setBool(.romajiEnabled, newValue, default: false) }
    }

    @discardableResult
    func observe(_ handler: @escaping (SettingKey) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    // A missing key must read as its default, not false
    private func bool(_ key: SettingKey, default fallback: Bool) -> Bool {
        (defaults.object(forKey: key.rawValue) as? Bool) ?? fallback
    }

    private func setBool(_ key: SettingKey, _ value: Bool, default fallback: Bool) {
        guard value != bool(key, default: fallback) else { return }
        defaults.set(value, forKey: key.rawValue)
        notify(key)
    }

    private func notify(_ key: SettingKey) {
        for handler in Array(observers.values) { handler(key) }
    }
}
