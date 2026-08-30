// Drives the REAL briefShowIsDoubleClick extracted from ContentView.swift,
// rather than a copy of it.
//
// Run:  Tools/run-double-click-test.py
//
// Why this exists: a double click cannot be scripted against this window —
// osascript has already failed on it once, see BRIEFSHOW_DEVELOP_NOTES.md — so
// the timing rule that replaced SwiftUI's own gesture arbitration is proved
// here and only the feel of the click is left for the eyes.
import Foundation

// ---- the real function, pasted in by the extractor below at run time -------

var failures = 0
func check(_ label: String, _ pass: Bool, _ detail: String = "") {
    print("  \(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — " + detail)")
    if !pass { failures += 1 }
}

let a = URL(fileURLWithPath: "/photos/a.jpg")
let b = URL(fileURLWithPath: "/photos/b.jpg")
let t0 = Date(timeIntervalSince1970: 1_000_000)
let interval: TimeInterval = 0.5

func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

print("double click")

// The very first click of a session has nothing to pair with.
check("no previous click is not a double",
      !briefShowIsDoubleClick(previous: nil, url: a, at: t0, interval: interval))

check("same photo, well inside the interval",
      briefShowIsDoubleClick(previous: (a, t0), url: a, at: at(0.2), interval: interval))

check("same photo, too slow",
      !briefShowIsDoubleClick(previous: (a, t0), url: a, at: at(0.7), interval: interval))

// Two fast clicks on DIFFERENT photos is someone picking quickly, not asking
// for Develop. Getting this wrong would open the editor while they browse.
check("different photos, however fast",
      !briefShowIsDoubleClick(previous: (a, t0), url: b, at: at(0.05), interval: interval))

// Exactly on the boundary counts, so the rule has no dead spot at the edge of
// whatever the client set in System Settings.
check("exactly at the interval still counts",
      briefShowIsDoubleClick(previous: (a, t0), url: a, at: at(0.5), interval: interval))

// Zero gap is the degenerate case of a fast machine, not an error.
check("a zero gap is a double",
      briefShowIsDoubleClick(previous: (a, t0), url: a, at: t0, interval: interval))

// A clock that steps backwards (NTP, sleep/wake) must not be read as a double
// click, and must not trap on a negative interval either.
check("a backwards clock is not a double",
      !briefShowIsDoubleClick(previous: (a, at(1)), url: a, at: t0, interval: interval))

// The system interval is honoured rather than a number chosen here: the same
// pair of clicks flips answer when the client's setting does.
check("a slower setting accepts a slower pair",
      !briefShowIsDoubleClick(previous: (a, t0), url: a, at: at(0.6), interval: 0.4)
      && briefShowIsDoubleClick(previous: (a, t0), url: a, at: at(0.6), interval: 0.9))

// The property that matters for the reported bug: NOTHING about the decision
// can delay the first click, because the first click never has a previous one
// on that photo to compare against, so it can only ever answer false — which
// is the branch that just selects.
var firstClickAlwaysPlain = true
for _ in 0..<10_000 {
    let gap = Double.random(in: -2...2)
    if briefShowIsDoubleClick(previous: nil, url: a, at: at(gap), interval: interval) {
        firstClickAlwaysPlain = false
    }
}
check("a first click is never a double, at any timing (10 000 cases)", firstClickAlwaysPlain)

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
