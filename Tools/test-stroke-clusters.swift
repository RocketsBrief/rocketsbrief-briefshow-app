// Drives the REAL briefShowStrokeBox / briefShowStrokeClusters extracted from
// Develop.swift, rather than a copy of them. A copy drifts silently; every bug
// in BRIEFSHOW_DEVELOP_NOTES.md that cost a session "looked correct" on
// inspection.
//
// Run:  Tools/run-stroke-cluster-test.py
//
// Why this exists: clustering is what decides whether "AI Clean Up" repairs
// what was painted or quietly repairs nothing at all. The failure it was
// written for is not visible in the code — two marks at opposite edges of the
// frame put the model's square working region in the empty middle and it
// returns nil — so the grouping itself is proved here and only the pixels are
// left for the eyes.
import Foundation

// ---- the real functions, pasted in by the extractor below at run time ------
// (kept as a marker so it is obvious this file does not define them itself)

var failures = 0
func check(_ label: String, _ pass: Bool, _ detail: String = "") {
    print("  \(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — " + detail)")
    if !pass { failures += 1 }
}

// A stroke that covers one dab at (x, y) of the given size.
func dab(_ x: Double, _ y: Double, size: Double = 0.02) -> BrushStroke {
    BrushStroke(points: [CGPoint(x: x, y: y)], size: size)
}

func shape(_ clusters: [[BrushStroke]]) -> [Int] {
    clusters.map(\.count).sorted()
}

print("stroke clustering")

// The reported bug, as a test: two marks at opposite edges of the frame have
// to come out as TWO removals. As one, the square region lands between them
// and repairs nothing.
check("far apart marks split",
      shape(briefShowStrokeClusters([dab(0.05, 0.5), dab(0.95, 0.5)])) == [1, 1],
      "got \(shape(briefShowStrokeClusters([dab(0.05, 0.5), dab(0.95, 0.5)])))")

// Two dabs laid side by side are one object, not two.
check("touching marks merge",
      shape(briefShowStrokeClusters([dab(0.50, 0.5), dab(0.51, 0.5)])) == [2])

// Transitivity, and the case that decides whether one pass is enough: at size
// 0.02 a mark reaches 0.03 either side, so 0.30 and 0.40 do NOT touch each
// other — they only meet THROUGH 0.35. All three still have to come out as one
// removal. Painted in the order 0.30, 0.40, 0.35 so the bridging mark arrives
// LAST, which is what a single merging pass would get wrong.
let chain = [dab(0.30, 0.5), dab(0.40, 0.5), dab(0.35, 0.5)]
check("chain merges through the middle",
      shape(briefShowStrokeClusters(chain)) == [3],
      "got \(shape(briefShowStrokeClusters(chain)))")

// The other half of that: the ends alone stay apart, so the test above really
// is proving the bridge and not just a generous reach.
check("the ends of that chain do not touch on their own",
      shape(briefShowStrokeClusters([dab(0.30, 0.5), dab(0.40, 0.5)])) == [1, 1])

// ...and the same three, spread out, do not.
let spread = [dab(0.10, 0.5), dab(0.50, 0.5), dab(0.90, 0.5)]
check("spread out marks stay separate",
      shape(briefShowStrokeClusters(spread)) == [1, 1, 1])

// Order must not change the answer: clustering is a property of the marks,
// not of which one happened to be painted first.
var orderStable = true
let sample = [dab(0.10, 0.1), dab(0.11, 0.1), dab(0.80, 0.8), dab(0.50, 0.5)]
let expected = shape(briefShowStrokeClusters(sample))
for _ in 0..<200 {
    if shape(briefShowStrokeClusters(sample.shuffled())) != expected { orderStable = false }
}
check("independent of paint order", orderStable, "expected \(expected)")

// A bigger brush reaches further, so the SAME two positions merge at a size
// that spans the gap and split at one that does not.
check("gap is judged against brush width",
      shape(briefShowStrokeClusters([dab(0.40, 0.5, size: 0.30), dab(0.60, 0.5, size: 0.30)])) == [2]
      && shape(briefShowStrokeClusters([dab(0.40, 0.5, size: 0.01), dab(0.60, 0.5, size: 0.01)])) == [1, 1])

// Degenerate input must not crash or invent clusters.
check("no strokes, no clusters", briefShowStrokeClusters([]).isEmpty)
check("a pointless stroke is dropped",
      briefShowStrokeClusters([BrushStroke(points: [], size: 0.02)]).isEmpty)

// Every stroke handed in comes back exactly once — a removal that silently
// dropped a mark would repair less than was painted, which is the same class
// of failure this whole change exists to fix.
var conserved = true
for trial in 0..<2000 {
    var strokes: [BrushStroke] = []
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<Int.random(in: 0...12, using: &generator) {
        strokes.append(dab(Double.random(in: 0...1), Double.random(in: 0...1),
                           size: Double.random(in: 0.005...0.2)))
    }
    let out = briefShowStrokeClusters(strokes)
    let ids = Set(out.flatMap { $0.map(\.id) })
    if ids.count != strokes.count || out.reduce(0, { $0 + $1.count }) != strokes.count {
        conserved = false
        print("  trial \(trial): \(strokes.count) in, \(out.reduce(0, { $0 + $1.count })) out")
        break
    }
}
check("every stroke survives, exactly once (2000 random cases)", conserved)

// ---- the job list, which the size gate on the buttons also reads ----------

print("\nremoval jobs")

func jobs(_ strokes: [BrushStroke], vision: CGRect? = nil) -> [BriefShowRemovalJob] {
    briefShowRemovalJobs(strokes: strokes, hasVisionMask: vision != nil, visionBox: vision)
}

// The reported case, end to end: two small marks at opposite edges. Two jobs,
// and — this is what re-enables Quick — each job's box is SMALL. Measured as
// one union it spanned 0.9 of the frame and the button switched itself off.
let farApart = jobs([dab(0.05, 0.5), dab(0.95, 0.5)])
check("two far apart marks are two jobs", farApart.count == 2)
check("and neither job is a large one",
      farApart.allSatisfy { max($0.box.width, $0.box.height) < 0.05 },
      "boxes \(farApart.map { max($0.box.width, $0.box.height) })")

// An erase stroke has to SHRINK the measured job, never grow it — the exact
// bug reported as "he counts when the brush is put on, but does not subtract
// when it is erased".
let painted = [dab(0.40, 0.5), dab(0.42, 0.5), dab(0.44, 0.5)]
let before = jobs(painted).map { max($0.box.width, $0.box.height) }.max() ?? 0
var rubbed = painted
rubbed.append(BrushStroke(points: [CGPoint(x: 0.44, y: 0.5)], size: 0.02, isErase: true))
let after = jobs(rubbed).map { max($0.box.width, $0.box.height) }.max() ?? 0
check("erasing shrinks the measured job", after < before, "\(before) -> \(after)")

// Erasing the middle of a chain really does break it in two, rather than
// leaving one job spanning ground that is no longer selected.
let broken = [dab(0.30, 0.5), dab(0.35, 0.5), dab(0.40, 0.5),
              BrushStroke(points: [CGPoint(x: 0.35, y: 0.5)], size: 0.02, isErase: true)]
check("erasing the bridge splits the chain", jobs(broken).count == 2,
      "got \(jobs(broken).count)")

// A Vision mask is its own job; a mark painted on top of it joins that job
// rather than becoming a second repair beside the first.
let visionBox = CGRect(x: 0.40, y: 0.40, width: 0.15, height: 0.15)
let onTop = jobs([dab(0.45, 0.45)], vision: visionBox)
check("a mark on the Vision mask joins it", onTop.count == 1 && onTop[0].usesVisionMask)
let beside = jobs([dab(0.90, 0.90)], vision: visionBox)
check("a mark away from it stays separate", beside.count == 2)

// Nothing painted, no Vision mask: no jobs, so the gate has nothing to measure
// and the buttons stay off rather than reading a size out of thin air.
check("nothing painted, no jobs", jobs([]).isEmpty)

// Every painted stroke has to land in exactly one job — a stroke silently
// dropped here is paint the client can see that would never be repaired.
var allPlaced = true
for _ in 0..<2000 {
    var strokes: [BrushStroke] = []
    for _ in 0..<Int.random(in: 1...10) {
        strokes.append(dab(Double.random(in: 0...1), Double.random(in: 0...1),
                           size: Double.random(in: 0.005...0.15)))
    }
    let placed = jobs(strokes).flatMap { $0.strokes.map(\.id) }
    if Set(placed).count != strokes.count || placed.count != strokes.count { allPlaced = false; break }
}
check("every painted stroke lands in exactly one job (2000 random cases)", allPlaced)

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
