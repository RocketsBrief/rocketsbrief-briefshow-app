// What a turn of the wheel over the editor means — run, not read.
//
// The real decision is pasted in below by run-zoom-original-test.py straight
// out of BriefShow/Develop.swift, so nothing here is a copy of it.
//
// Three things are being held down, and each is a way the client loses the
// gesture he asked for:
//
//   1. ⌘ + wheel zooms the PICTURE, even with a brush armed — which is
//      precisely when he wants to zoom in and look at what the brush did,
//   2. a plain wheel still resizes that brush, and still only over the canvas,
//   3. the two gestures never spend each other's travel.
//
//     scroll-wheel
import Foundation
import AppKit

var failures = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    if passed {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "   \(detail)")")
    }
}

// ---- the real decision, pasted in by the extractor at run time -------------

// MARK: - ⌘ + wheel is the zoom

print("\n⌘ + wheel zooms the picture")

do {
    var travel = ScrollWheelTravel()
    let action = briefShowScrollWheelAction(commandHeld: true, otherModifiersHeld: false,
                                            delta: 1, hasPreciseDeltas: false,
                                            pointerOverCanvas: true,
                                            toolHasAdjustableSize: false,
                                            travel: &travel)
    check("one wheel detent up is one rung in", action == .zoom(steps: 1), "\(action)")
}

do {
    var travel = ScrollWheelTravel()
    let action = briefShowScrollWheelAction(commandHeld: true, otherModifiersHeld: false,
                                            delta: -1, hasPreciseDeltas: false,
                                            pointerOverCanvas: true,
                                            toolHasAdjustableSize: false,
                                            travel: &travel)
    check("one detent down is one rung out", action == .zoom(steps: -1), "\(action)")
}

do {
    // THE POINT OF THE WHOLE BRANCH: a brush is armed and ⌘ still zooms.
    var travel = ScrollWheelTravel()
    let action = briefShowScrollWheelAction(commandHeld: true, otherModifiersHeld: false,
                                            delta: 1, hasPreciseDeltas: false,
                                            pointerOverCanvas: true,
                                            toolHasAdjustableSize: true,
                                            travel: &travel)
    check("⌘ zooms even with a sizeable tool armed", action == .zoom(steps: 1), "\(action)")
}

do {
    var travel = ScrollWheelTravel()
    let action = briefShowScrollWheelAction(commandHeld: true, otherModifiersHeld: false,
                                            delta: 4, hasPreciseDeltas: false,
                                            pointerOverCanvas: true,
                                            toolHasAdjustableSize: false,
                                            travel: &travel)
    check("four detents are four rungs, not one", action == .zoom(steps: 4), "\(action)")
}

do {
    // A trackpad's fractions: one flick must not cross the whole ladder.
    var travel = ScrollWheelTravel()
    var steps = 0
    for _ in 0..<12 {
        if case .zoom(let s) = briefShowScrollWheelAction(commandHeld: true, otherModifiersHeld: false,
                                                          delta: 1, hasPreciseDeltas: true,
                                                          pointerOverCanvas: true,
                                                          toolHasAdjustableSize: false,
                                                          travel: &travel) {
            steps += s
        }
    }
    check("a trackpad needs \(Int(briefShowScrollZoomStep)) of travel for one rung",
          steps == 1, "twelve fractions gave \(steps)")
}

do {
    var travel = ScrollWheelTravel()
    let action = briefShowScrollWheelAction(commandHeld: true, otherModifiersHeld: false,
                                            delta: 1, hasPreciseDeltas: false,
                                            pointerOverCanvas: false,
                                            toolHasAdjustableSize: false,
                                            travel: &travel)
    // Off the picture the panel is a scroll view, and ⌘-scrolling it must not
    // zoom a photograph the pointer is not even over.
    check("⌘ off the canvas is handed back", action == .pass, "\(action)")
    check("and nothing was spent", travel == ScrollWheelTravel())
}

do {
    var travel = ScrollWheelTravel()
    let action = briefShowScrollWheelAction(commandHeld: true, otherModifiersHeld: true,
                                            delta: 1, hasPreciseDeltas: false,
                                            pointerOverCanvas: true,
                                            toolHasAdjustableSize: true,
                                            travel: &travel)
    check("⌘⇧ is somebody else's gesture", action == .pass, "\(action)")
}

// MARK: - The plain wheel still belongs to the tool

print("\nthe plain wheel still resizes the tool")

do {
    var travel = ScrollWheelTravel()
    let action = briefShowScrollWheelAction(commandHeld: false, otherModifiersHeld: false,
                                            delta: 1, hasPreciseDeltas: false,
                                            pointerOverCanvas: true,
                                            toolHasAdjustableSize: true,
                                            travel: &travel)
    check("a detent up is one size bigger", action == .resizeTool(steps: 1), "\(action)")
}

do {
    var travel = ScrollWheelTravel()
    let action = briefShowScrollWheelAction(commandHeld: false, otherModifiersHeld: false,
                                            delta: 1, hasPreciseDeltas: false,
                                            pointerOverCanvas: true,
                                            toolHasAdjustableSize: false,
                                            travel: &travel)
    check("with no sizeable tool it is handed back", action == .pass, "\(action)")
}

do {
    var travel = ScrollWheelTravel()
    let action = briefShowScrollWheelAction(commandHeld: false, otherModifiersHeld: false,
                                            delta: 1, hasPreciseDeltas: false,
                                            pointerOverCanvas: false,
                                            toolHasAdjustableSize: true,
                                            travel: &travel)
    check("off the canvas the panel keeps scrolling", action == .pass, "\(action)")
}

do {
    var travel = ScrollWheelTravel()
    var steps = 0
    for _ in 0..<6 {
        if case .resizeTool(let s) = briefShowScrollWheelAction(commandHeld: false, otherModifiersHeld: false,
                                                                delta: 1, hasPreciseDeltas: true,
                                                                pointerOverCanvas: true,
                                                                toolHasAdjustableSize: true,
                                                                travel: &travel) {
            steps += s
        }
    }
    check("a trackpad needs \(Int(briefShowScrollToolStep)) of travel for one size",
          steps == 1, "six fractions gave \(steps)")
}

// MARK: - Changing your mind, and the two counters

print("\nthe travel of one gesture is never spent by the other")

do {
    // Half a brush rung held, then ⌘ — the zoom must start from nothing.
    var travel = ScrollWheelTravel()
    _ = briefShowScrollWheelAction(commandHeld: false, otherModifiersHeld: false,
                                   delta: briefShowScrollToolStep - 1, hasPreciseDeltas: true,
                                   pointerOverCanvas: true, toolHasAdjustableSize: true,
                                   travel: &travel)
    check("the tool holds what it has not spent", travel.toolSize > 0 && travel.zoom == 0,
          "tool \(travel.toolSize), zoom \(travel.zoom)")

    let action = briefShowScrollWheelAction(commandHeld: true, otherModifiersHeld: false,
                                            delta: 1, hasPreciseDeltas: true,
                                            pointerOverCanvas: true, toolHasAdjustableSize: true,
                                            travel: &travel)
    check("and the first ⌘-scroll does not cash it in", action == .swallow, "\(action)")
}

do {
    // The other way round, and it is the one that BITES: the zoom's rung is
    // longer than the brush's, so travel held for a zoom is already more than
    // a whole brush rung. Shared, the next plain scroll would resize the brush
    // TWO sizes on a single fraction of a flick.
    var travel = ScrollWheelTravel()
    _ = briefShowScrollWheelAction(commandHeld: true, otherModifiersHeld: false,
                                   delta: briefShowScrollZoomStep - 1, hasPreciseDeltas: true,
                                   pointerOverCanvas: true, toolHasAdjustableSize: true,
                                   travel: &travel)
    check("the zoom holds what it has not spent", travel.zoom > 0 && travel.toolSize == 0,
          "tool \(travel.toolSize), zoom \(travel.zoom)")

    let plain = briefShowScrollWheelAction(commandHeld: false, otherModifiersHeld: false,
                                           delta: 1, hasPreciseDeltas: true,
                                           pointerOverCanvas: true, toolHasAdjustableSize: true,
                                           travel: &travel)
    check("and the next plain scroll does not cash IT in", plain == .swallow, "\(plain)")
}

do {
    var travel = ScrollWheelTravel()
    _ = briefShowScrollWheelAction(commandHeld: true, otherModifiersHeld: false,
                                   delta: briefShowScrollZoomStep - 1, hasPreciseDeltas: true,
                                   pointerOverCanvas: true, toolHasAdjustableSize: false,
                                   travel: &travel)
    // A reversal clears what is held, so changing your mind zooms back out on
    // the NEXT full rung rather than after paying the other way first.
    var steps = 0
    for _ in 0..<Int(briefShowScrollZoomStep) {
        if case .zoom(let s) = briefShowScrollWheelAction(commandHeld: true, otherModifiersHeld: false,
                                                          delta: -1, hasPreciseDeltas: true,
                                                          pointerOverCanvas: true,
                                                          toolHasAdjustableSize: false,
                                                          travel: &travel) {
            steps += s
        }
    }
    check("a reversal clears the held travel first", steps == -1, "gave \(steps)")
}

do {
    var travel = ScrollWheelTravel()
    let action = briefShowScrollWheelAction(commandHeld: true, otherModifiersHeld: false,
                                            delta: 0, hasPreciseDeltas: false,
                                            pointerOverCanvas: true,
                                            toolHasAdjustableSize: false,
                                            travel: &travel)
    // A horizontal scroll over the picture with ⌘ down: ours, and it does
    // nothing — but it must not fall through to the panel underneath.
    check("a sideways ⌘-scroll is swallowed, not passed", action == .swallow, "\(action)")
}

print(failures == 0 ? "\nall passed\n" : "\n\(failures) FAILED\n")
exit(failures == 0 ? 0 : 1)
