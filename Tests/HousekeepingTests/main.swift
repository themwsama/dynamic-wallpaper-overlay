import Foundation

var failed = false
func check(_ name: String, _ ok: Bool) {
    print(ok ? "PASS \(name)" : "FAIL \(name)")
    if !ok { failed = true }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("housekeeping-tests-\(UUID().uuidString)")
try? fm.removeItem(at: root)
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
let now = Date()
let day: TimeInterval = 86400

func make(_ dir: URL, _ name: String, age: TimeInterval, body: String = "{}") -> URL {
    let u = dir.appendingPathComponent(name)
    try! body.write(to: u, atomically: true, encoding: .utf8)
    try! fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: u.path)
    return u
}
func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }

// age pruning + untouched items
let c1 = root.appendingPathComponent("c1")
try! fm.createDirectory(at: c1, withIntermediateDirectories: true)
let old = make(c1, "old.json", age: 90 * day)
let fresh = make(c1, "fresh.json", age: 1 * day)
let txt = make(c1, "old.txt", age: 90 * day)
let sub = c1.appendingPathComponent("old.json.d")
try! fm.createDirectory(at: sub, withIntermediateDirectories: true)
try! fm.setAttributes([.modificationDate: now.addingTimeInterval(-90 * day)], ofItemAtPath: sub.path)
let n1 = Housekeeping.pruneCache(directory: c1, maxAge: 60 * day, maxFiles: 400, now: now)
check("age prune returns 1", n1 == 1)
check("old json deleted", !exists(old))
check("fresh json kept", exists(fresh))
check("old non-json untouched", exists(txt))
check("subdirectory untouched", exists(sub))

// count cap keeps newest
let c2 = root.appendingPathComponent("c2")
try! fm.createDirectory(at: c2, withIntermediateDirectories: true)
let files = (0..<10).map { make(c2, "f\($0).json", age: Double($0 + 1) * day) }
let n2 = Housekeeping.pruneCache(directory: c2, maxAge: 60 * day, maxFiles: 4, now: now)
check("cap returns 6", n2 == 6)
check("cap keeps 4 newest", files[0..<4].allSatisfy(exists) && files[4...].allSatisfy { !exists($0) })

// missing directory
check("missing dir returns 0", Housekeeping.pruneCache(directory: root.appendingPathComponent("nope"), maxAge: day, maxFiles: 1, now: now) == 0)

// trimLog
let line = String(repeating: "x", count: 99) + "\n"
let log = root.appendingPathComponent("a.log")
try! String(repeating: line, count: 10).write(to: log, atomically: true, encoding: .utf8)
check("under limit untouched", !Housekeeping.trimLog(at: log, maxBytes: 5000, keepBytes: 500) && (try! Data(contentsOf: log)).count == 1000)

let log2 = root.appendingPathComponent("b.log")
try! (0..<100).map { "line \($0) " + String(repeating: "y", count: 90) + "\n" }.joined().write(to: log2, atomically: true, encoding: .utf8)
let inodeBefore = (try! fm.attributesOfItem(atPath: log2.path))[.systemFileNumber] as! Int
check("over limit trimmed", Housekeeping.trimLog(at: log2, maxBytes: 2000, keepBytes: 1000))
let inodeAfter = (try! fm.attributesOfItem(atPath: log2.path))[.systemFileNumber] as! Int
check("same inode", inodeBefore == inodeAfter)
let data = try! Data(contentsOf: log2)
let text = String(decoding: data, as: UTF8.self)
check("size <= keepBytes", data.count <= 1000 && data.count > 0)
check("starts at line boundary", text.hasPrefix("line ") && text.hasSuffix("\n"))
check("keeps newest line", text.contains("line 99 "))
check("missing log returns false", !Housekeeping.trimLog(at: root.appendingPathComponent("none.log"), maxBytes: 1, keepBytes: 1))

// append-mode descriptor held across trim
let log3 = root.appendingPathComponent("c.log")
try! (0..<100).map { "row \($0) " + String(repeating: "z", count: 90) + "\n" }.joined().write(to: log3, atomically: true, encoding: .utf8)
let fd = open(log3.path, O_WRONLY | O_APPEND)
check("append fd opened", fd >= 0)
check("trim with open fd", Housekeeping.trimLog(at: log3, maxBytes: 2000, keepBytes: 1000))
let more = "AFTER-TRIM\n"
_ = more.withCString { write(fd, $0, strlen($0)) }
close(fd)
let d3 = try! Data(contentsOf: log3)
check("no zero gap", !d3.contains(0))
check("new text at end", String(decoding: d3, as: UTF8.self).hasSuffix("z\nAFTER-TRIM\n"))
check("size bounded after append", d3.count <= 1000 + more.utf8.count)

// log path from the environment (WALLPAPER_OVERLAY_LOG)
let defaultLog = NSHomeDirectory() + "/Library/Logs/wallpaper-overlay.log"
check("log path default", resolveLogURL(env: [:]).path == defaultLog)
check("log path empty env uses default", resolveLogURL(env: ["WALLPAPER_OVERLAY_LOG": ""]).path == defaultLog)
check("log path absolute override", resolveLogURL(env: ["WALLPAPER_OVERLAY_LOG": "/var/tmp/x.log"]).path == "/var/tmp/x.log")
check("log path tilde expanded", resolveLogURL(env: ["WALLPAPER_OVERLAY_LOG": "~/logs/x.log"]).path == NSHomeDirectory() + "/logs/x.log")

try? fm.removeItem(at: root)
if failed { print("FAILED"); exit(1) }
print("ALL PASS")
