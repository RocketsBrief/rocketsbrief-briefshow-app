// Drives the REAL briefShowFolderClickAction and briefShowRenameDestination
// extracted from ContentView.swift, rather than copies of them.
//
// Run:  Tools/run-folder-rename-test.py
//
// Why this exists: the client asked for Finder's two ways into a rename —
// *„Right click on the folder should show rename button. Or click once and wait
// for a bit click another one to enable renaming, like usually"* — and the
// second one is a rule about TIME. A click that comes too late is a rename, one
// that comes fast is an open, and the two cannot be told apart by looking at
// either click on its own. That rule is proved here; the feel of it is left for
// the eyes.
import Foundation

// ---- the real functions, pasted in by the extractor at run time ------------

var failures = 0
func check(_ label: String, _ pass: Bool, _ detail: String = "") {
    print("  \(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — " + detail)")
    if !pass { failures += 1 }
}

let trip = URL(fileURLWithPath: "/photos/Trip")
let other = URL(fileURLWithPath: "/photos/Other")
let t0 = Date(timeIntervalSince1970: 2_000_000)
func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

let doubleInterval: TimeInterval = 0.5
let renameDelay: TimeInterval = 0.6

func action(_ previous: (url: URL, at: Date)?, _ url: URL, _ when: TimeInterval) -> BriefShowFolderClick {
    briefShowFolderClickAction(previous: previous, url: url, at: at(when),
                               doubleClickInterval: doubleInterval, renameDelay: renameDelay)
}

print("what a click on a folder means")

check("the first click of a session only remembers",
      action(nil, trip, 0) == .remember)

// The reported behaviour: click, wait, click the SAME folder again.
check("a second click after the delay renames",
      action((trip, t0), trip, 0.8) == .beginRename)

check("a fast second click opens",
      action((trip, t0), trip, 0.2) == .open)

// ⛔ THE ONE THAT MATTERS. A double-click to OPEN passes through the same
// handler twice: its first click lands while some earlier click is remembered,
// its second click lands ~0.2 s later. Neither may start a rename, or every
// attempt to open a folder would put its name into a text field instead.
check("the gap between a double-click's own two clicks never renames",
      action((trip, t0), trip, 0.2) == .open)

// Between the two rules is a gap: too slow to be a double click, too fast to be
// a deliberate second click. Finder does nothing there, and so does this.
check("in between, it only remembers",
      action((trip, t0), trip, 0.55) == .remember)

check("exactly on the double-click interval still opens",
      action((trip, t0), trip, 0.5) == .open)

check("exactly on the rename delay renames",
      action((trip, t0), trip, 0.6) == .beginRename)

// Two clicks on two different folders is someone browsing.
check("a click on another folder only remembers, however slow",
      action((trip, t0), other, 5) == .remember
      && action((trip, t0), other, 0.1) == .remember)

// A clock that steps backwards (NTP, sleep/wake) must not rename anything.
check("a backwards clock renames nothing",
      action((trip, at(3)), trip, 0) == .remember)

// The system setting is honoured rather than a number chosen here.
check("a slower double-click setting still leaves the rename gap intact",
      briefShowFolderClickAction(previous: (trip, t0), url: trip, at: at(0.55),
                                 doubleClickInterval: 0.9, renameDelay: 1.2) == .open)

print("\nthe name a rename lands on")

let taken: Set<String> = ["/photos/Holiday", "/photos/Holiday 2"]
func exists(_ url: URL) -> Bool { taken.contains(url.path) }
func destination(_ name: String, from url: URL = URL(fileURLWithPath: "/photos/Trip")) -> URL? {
    briefShowRenameDestination(for: url, to: name, exists: exists)
}

check("a plain name moves the folder next to itself",
      destination("Summer")?.path == "/photos/Summer")

check("spaces around the name are not part of it",
      destination("  Summer  ")?.path == "/photos/Summer")

// A "/" typed into a name is a path separator, not a letter: without this the
// rename would try to move the folder somewhere else entirely.
check("a slash or a colon becomes a dash, never a path",
      destination("Trip/2026")?.path == "/photos/Trip-2026"
      && destination("Trip:2026")?.path == "/photos/Trip-2026")

check("an empty name is not a rename", destination("") == nil && destination("   ") == nil)

// A leading dot hides the folder from Finder and from the app's own listing —
// the client would watch a folder disappear.
check("a name starting with a dot is refused", destination(".hidden") == nil)

check("the same name is not a rename", destination("Trip") == nil)

// The name is taken: the app's own numbered-suffix convention, the one paste
// and New Folder already use, rather than failing silently.
check("a taken name gets the next free number",
      destination("Holiday")?.path == "/photos/Holiday 3")

check("a free name is never numbered",
      destination("Holidays")?.path == "/photos/Holidays")

// The parent is kept, whatever it is: a rename moves nothing between folders.
check("the folder stays where it is",
      briefShowRenameDestination(for: URL(fileURLWithPath: "/a/b/c/Trip"), to: "Summer",
                                 exists: { _ in false })?.path == "/a/b/c/Summer")

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
