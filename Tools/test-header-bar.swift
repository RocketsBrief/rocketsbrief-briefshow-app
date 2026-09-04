import Foundation
import CoreGraphics

// ---- the real function, pasted in by the extractor at run time -------------

// Exercises the REAL headerBarColumns pulled out of Develop.swift by
// run-header-bar-test.py. Nothing here re-implements it — if the rule in the
// app changes, these numbers change with it.
//
// What is being defended, in the client's own words:
//
//  1. *„da nikad ne ostavlja prostor prazan izmedju ikonica ili sa strane"* —
//     the column count is always a DIVISOR of the button count, so the last
//     row is as full as the first and nothing is left over at either end.
//  2. *„uvek isto gore isto dole"* — every row holds the same number of cells,
//     which follows from 1 and is checked as its own claim anyway.
//  3. *„zavisno kako se desna strana siri ili suzava.. moze i tri reda i
//     cetri"* — the count actually CHANGES across the panel's real drag range
//     (300…560), rather than being one fixed grid that ignores the width.
//  4. Widening the panel never gives FEWER cells per row.

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
let buttonCount = 12

var seen: [Int: (CGFloat, CGFloat)] = [:]   // columns -> (first width, last width)
var previousColumns = 0

for step in 0...260 {
    let width = minPanel + CGFloat(step)
    let columns = headerBarColumns(for: width, count: buttonCount)

    check(columns > 0, "columns is positive at \(Int(width))")
    check(buttonCount % columns == 0,
          "\(columns) divides \(buttonCount) evenly at width \(Int(width)) — no short row")
    check(columns >= previousColumns,
          "widening never gives fewer per row (at \(Int(width)): \(previousColumns) → \(columns))")
    previousColumns = columns

    if var range = seen[columns] {
        range.1 = width
        seen[columns] = range
    } else {
        seen[columns] = (width, width)
    }
}

// The whole point of the divisor rule: rows are equal, so "same on top, same
// at the bottom" is arithmetic rather than a hope.
for (columns, range) in seen.sorted(by: { $0.key < $1.key }) {
    let rows = buttonCount / columns
    let cells = rows * columns
    check(cells == buttonCount,
          "\(rows) rows × \(columns) = \(cells), which is exactly \(buttonCount)")
    print(String(format: "      %2d per row × %d rows  for panel %.0f…%.0f pt",
                 columns, rows, range.0, range.1))
}

check(seen.count >= 2,
      "the layout actually reflows across 300…560 (found \(seen.count) different row widths)")

// A cell has to stay big enough to be a target. 28pt is the panel's own
// padding, and the seams between cells are a pixel each.
for (columns, range) in seen {
    let narrowest = (range.0 - 28 - CGFloat(columns - 1)) / CGFloat(columns)
    check(narrowest >= 34,
          String(format: "at %d per row the smallest cell is %.1f pt, not a sliver", columns, narrowest))
}

print(failures == 0 ? "RESULT: OK" : "RESULT: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
