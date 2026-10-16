import Foundation

let SUITE = "wallpaper-overlay-settings-test"
var failed = false

func check(_ name: String, _ ok: Bool) {
    print(ok ? "PASS \(name)" : "FAIL \(name)")
    if !ok { failed = true }
}

func freshDefaults() -> UserDefaults {
    let d = UserDefaults(suiteName: SUITE)!
    d.removePersistentDomain(forName: SUITE)
    return d
}

let d = freshDefaults()
var s = Settings(defaults: d)

check("default clock", s.isClockVisible == true)
check("default effects", s.isEffectsVisible == true)
check("default style", s.transitionStyleRaw == 1)
check("default glow", s.isMusicGlowEnabled == true)
check("default lyrics", s.isLyricsEnabled == true)
check("default romaji", s.isRomajiEnabled == false)

s.isClockVisible = false
s.isEffectsVisible = false
s.transitionStyleRaw = 3
s.isMusicGlowEnabled = false
s.isLyricsEnabled = false
s.isRomajiEnabled = true
s = Settings(defaults: d)
check("persist clock", !s.isClockVisible)
check("persist effects", !s.isEffectsVisible)
check("persist style", s.transitionStyleRaw == 3)
check("persist glow", !s.isMusicGlowEnabled)
check("persist lyrics", !s.isLyricsEnabled)
check("persist romaji", s.isRomajiEnabled)

check("key names", SettingKey.allCases.map(\.rawValue) ==
      ["clockVisible", "effectsVisible", "transitionStyle", "musicGlowEnabled", "lyricsEnabled", "romajiEnabled"])
check("written under existing key", d.object(forKey: "clockVisible") as? Bool == false
      && d.object(forKey: "transitionStyle") as? Int == 3)

var seen: [SettingKey] = []
let id = s.observe { seen.append($0) }
s.isRomajiEnabled = true
s.transitionStyleRaw = 3
check("no fire on same value", seen.isEmpty)
s.isRomajiEnabled = false
s.transitionStyleRaw = 2
check("fires on change", seen == [.romajiEnabled, .transitionStyle])

s.removeObserver(id)
s.isLyricsEnabled = true
check("removed observer silent", seen.count == 2)

d.removePersistentDomain(forName: SUITE)
let missing = Settings(defaults: d)
check("default after clear", missing.isClockVisible && !missing.isRomajiEnabled)

d.removePersistentDomain(forName: SUITE)
if failed { exit(1) }
print("ALL PASS")
