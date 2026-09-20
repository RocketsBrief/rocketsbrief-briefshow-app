import Foundation
import CoreGraphics

// ---- the real function, pasted in by the extractor at run time -------------

// Exercises the REAL headerBarColumns and headerBarRows pulled out of
// Develop.swift by run-header-bar-test.py, at the REAL button count and with
// the REAL cell size. Nothing here re-implements any of it — if the rule in
// the app changes, these numbers change with it.
//
// ⚠️ THE FAILURE THIS HARNESS DID NOT CATCH, and the reason it now reads
// everything off the source. Until 20.09 the cells stretched to fill their
// row, so the column count had to be a DIVISOR of the button count or a row
// would end in a hole. That worked for twelve buttons. Templates made it
// THIRTEEN — a prime — and thirteen cells do not fit at 300 pt, so the only
// legal split left was 13 × 1: the bar became one button per line down the
// whole panel, and the client sent a photograph of it. Every check here went
// on passing, because the harness carried its own `buttonCount = 12`.
//
// What is being defended now:
//
//  1. *„horizontalni kockasti dugmici jedan do drugog"* (20.09) — the cells are
//     SQUARES of a fixed side, so a row holds as many as fit and the count no
//     longer has to divide anything.
//  2. *„uvek isto gore isto dole"* — the rows are balanced to within one
//     button, which is what the divisor rule used to give for free.
//  3. *„zavisno kako se desna strana siri ili suzava.. moze i tri reda i
//     cetri"* — the count actually CHANGES across the panel's real drag range
//     (300…560) rather than ignoring the width.
//  4. Widening the panel never gives FEWER per row.
//  5. AT NO WIDTH does the bar fall back to one button per line while two
//     would fit — the regression above, as a check of its own.

var failures = 0

func check(_ condition: Bool, _ what: String) {
    if !condition {
        failures += 1
        print("FAIL  \(what)")
    }
}

// The panel is draggable between these two, and the header sits inside it at
// every width in between.
let minPanel: CGFloat = 300
let maxPanel: CGFloat = 560
let buttonCount = shippingButtonCount
let padding: CGFloat = 28          // the panel's own, which the bar may not use

print("      \(buttonCount) buttons, \(Int(headerCellHeight)) pt square, \(Int(headerCellGap)) pt apart")

var seen: [Int: (CGFloat, CGFloat)] = [:]   // columns -> (first width, last width)
var previousColumns = 0

for step in 0...Int(maxPanel - minPanel) {
    let width = minPanel + CGFloat(step)
    let columns = headerBarColumns(for: width, count: buttonCount)

    check(columns > 0, "columns is positive at \(Int(width))")
    check(columns <= buttonCount, "never more columns than buttons at \(Int(width))")

    // The row has to FIT: squares plus the gaps between them, inside what the
    // panel leaves after its own padding.
    let used = CGFloat(columns) * headerCellHeight + CGFloat(columns - 1) * headerCellGap
    let available = width - padding
    check(used <= available + 0.001,
          String(format: "%d squares fit in %.0f pt at panel %.0f", columns, available, width))

    // …and it has to USE the width it has: one more square must not fit,
    // unless every button is already up there.
    if columns < buttonCount {
        let oneMore = CGFloat(columns + 1) * headerCellHeight + CGFloat(columns) * headerCellGap
        check(oneMore > available + 0.001,
              String(format: "at panel %.0f another square would have fitted (%d used, %.0f pt free)",
                     width, columns, available - used))
    }

    check(columns >= previousColumns,
          "widening never gives fewer per row (at \(Int(width)): \(previousColumns) → \(columns))")
    previousColumns = columns

    // ⚠️ The regression itself, checked at every width: one per line is only
    // ever right when two genuinely do not fit.
    if columns == 1 && buttonCount > 1 {
        let two = 2 * headerCellHeight + headerCellGap
        check(two > available + 0.001,
              String(format: "one button per line at panel %.0f, where two would have fitted", width))
    }

    // The rows themselves: every button once, in order, none longer than the
    // column count, and none more than one shorter than another.
    let indices = Array(0..<buttonCount)
    let rows = headerBarRows(indices, columns: columns)
    check(rows.flatMap { $0 } == indices,
          "every button appears exactly once, in order, at panel \(Int(width))")
    check(rows.allSatisfy { $0.count <= columns },
          "no row is longer than \(columns) at panel \(Int(width))")
    if let longest = rows.map({ $0.count }).max(), let shortest = rows.map({ $0.count }).min() {
        check(longest - shortest <= 1,
              "rows are even at panel \(Int(width)) (found \(rows.map { $0.count }))")
    }

    if var range = seen[columns] {
        range.1 = width
        seen[columns] = range
    } else {
        seen[columns] = (width, width)
    }
}

for (columns, range) in seen.sorted(by: { $0.key < $1.key }) {
    let shape = headerBarRows(Array(0..<buttonCount), columns: columns).map { $0.count }
    print(String(format: "      %2d per row  →  rows of %@  for panel %.0f…%.0f pt",
                 columns,
                 shape.map(String.init).joined(separator: " + "),
                 range.0, range.1))
}

check(seen.count >= 2,
      "the layout actually reflows across 300…560 (found \(seen.count) different row widths)")

// Balanced rather than greedy, stated as its own claim: filling greedily
// leaves a stub (8 buttons, 5 per row → 5 + 3) where this evens them out.
let eight = headerBarRows(Array(0..<8), columns: 5).map { $0.count }
check(eight == [4, 4], "eight buttons five-per-row come out 4 + 4, not 5 + 3 (found \(eight))")
let thirteen = headerBarRows(Array(0..<13), columns: 7).map { $0.count }
check(thirteen == [7, 6], "thirteen buttons seven-per-row come out 7 + 6 (found \(thirteen))")
check(headerBarRows([0], columns: 4) == [[0]], "a single button is a single row")
check(headerBarRows([Int](), columns: 4).isEmpty, "no buttons is no rows")

print(failures == 0 ? "RESULT: OK" : "RESULT: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
