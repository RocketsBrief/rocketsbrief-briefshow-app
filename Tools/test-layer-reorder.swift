// Drives the REAL LayerDropDelegate.reorder(_:moving:onto:) extracted from
// Develop.swift, rather than a copy of it. A copy drifts silently; every bug
// in BRIEFSHOW_DEVELOP_NOTES.md that cost a session "looked correct" on
// inspection.
//
// Run:  swift Tools/test-layer-reorder.swift
//
// Why this exists at all: the Layers list is reordered by dragging, and a drag
// cannot be scripted from here (osascript already failed on this window once —
// see the notes). The array move underneath the drag CAN be, so that is the
// part that gets proved, and only the gesture is left for the eyes.
import Foundation

// ---- the real function, pasted in by the extractor below at run time -------
// (kept as a marker so it is obvious this file does not define it itself)

struct Item: Identifiable, Equatable { let id: Int }

func order(_ xs: [Item]) -> [Int] { xs.map(\.id) }

var failures = 0
func check(_ label: String, _ pass: Bool, _ detail: String = "") {
    print("  \(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — " + detail)")
    if !pass { failures += 1 }
}

print("\nLayer reorder")

// 1. Move up one (toward the end of the array = toward the top of the photo).
do {
    var a = [Item(id: 1), Item(id: 2), Item(id: 3)]
    let moved = LayerDropDelegate.reorder(&a, moving: 1, onto: 2)
    check("dragging 1 onto 2 swaps them", moved && order(a) == [2, 1, 3], "\(order(a))")
}

// 2. Move down one.
do {
    var a = [Item(id: 1), Item(id: 2), Item(id: 3)]
    LayerDropDelegate.reorder(&a, moving: 3, onto: 2)
    check("dragging 3 onto 2 swaps them back", order(a) == [1, 3, 2], "\(order(a))")
}

// 3. Across the whole list, both directions.
do {
    var a = [Item(id: 1), Item(id: 2), Item(id: 3), Item(id: 4)]
    LayerDropDelegate.reorder(&a, moving: 1, onto: 4)
    check("bottom to top lands at the end", order(a) == [2, 3, 4, 1], "\(order(a))")

    var b = [Item(id: 1), Item(id: 2), Item(id: 3), Item(id: 4)]
    LayerDropDelegate.reorder(&b, moving: 4, onto: 1)
    check("top to bottom lands at the start", order(b) == [4, 1, 2, 3], "\(order(b))")
}

// 4. No-ops must leave the array byte-identical AND report false, so a caller
//    can never mistake "nothing to do" for "moved".
do {
    var a = [Item(id: 1), Item(id: 2), Item(id: 3)]
    let before = order(a)
    check("dropping a layer onto itself does nothing",
          LayerDropDelegate.reorder(&a, moving: 2, onto: 2) == false && order(a) == before, "\(order(a))")

    check("a dragged id that is gone (deleted mid-drag) does nothing",
          LayerDropDelegate.reorder(&a, moving: 99, onto: 1) == false && order(a) == before, "\(order(a))")

    check("a target id that is gone does nothing",
          LayerDropDelegate.reorder(&a, moving: 1, onto: 99) == false && order(a) == before, "\(order(a))")

    var empty: [Item] = []
    check("an empty list does nothing rather than trapping",
          LayerDropDelegate.reorder(&empty, moving: 1, onto: 2) == false && empty.isEmpty)
}

// 5. The property that actually matters: a reorder is a PERMUTATION. It must
//    never drop a layer or duplicate one — that would silently lose pixels the
//    user cut out of a photo, and the render would just look wrong.
do {
    var rng = SystemRandomNumberGenerator()
    var permutationHeld = true
    var countHeld = true
    for _ in 0..<200_000 {
        let n = Int.random(in: 2...8, using: &rng)
        var a = (0..<n).map { Item(id: $0) }
        let from = Int.random(in: 0..<n, using: &rng)
        let to = Int.random(in: 0..<n, using: &rng)
        LayerDropDelegate.reorder(&a, moving: from, onto: to)
        if a.count != n { countHeld = false }
        if Set(order(a)) != Set(0..<n) { permutationHeld = false }
    }
    check("200 000 random drops never lose or duplicate a layer", permutationHeld && countHeld)
}

// 6. Display is reversed (topmost first) while the array is bottom-to-top, so
//    check the thing a user actually sees: dragging the row ABOVE another must
//    put it above in the rendered list too.
do {
    var a = [Item(id: 1), Item(id: 2), Item(id: 3)]     // rendered: 3, 2, 1
    LayerDropDelegate.reorder(&a, moving: 3, onto: 1)   // drag topmost onto bottom row
    let rendered = order(a).reversed().map { $0 }
    check("dragging the top row to the bottom row shows it at the bottom",
          rendered == [2, 1, 3], "rendered \(rendered)")
}

print(failures == 0 ? "  all checks passed\n" : "  \(failures) check(s) FAILED\n")
exit(failures == 0 ? 0 : 1)
