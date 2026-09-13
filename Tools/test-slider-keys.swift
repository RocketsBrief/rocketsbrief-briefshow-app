// Which key moves the armed slider, and which key moves the photograph.
//
// The client's instruction of 13.09 was two things at once: "na minus i plus
// pomeramo selektovan side bar a na strelice da se pomeraju slike" — so the
// arrows had to be taken off the slider and given to the filmstrip — and "kada
// ja misem pomerim slidebar recimo kontrast to ne znaci da sam ja oznacio
// kontrast... neka ostane gde je bio vec", so a mouse drag must not change what
// the keys control.
//
// The first half is a pure function and runs here. The second half cannot be —
// it is a SwiftUI closure — so Tools/run-slider-keys-test.py reads the source
// for it instead, and says so rather than pretending it ran.
import Foundation

var failures = 0
func check(_ what: String, _ passed: Bool, _ detail: String = "") {
    print("  \(passed ? "ok  " : "FAIL") \(what)\(detail.isEmpty ? "" : "   — \(detail)")")
    if !passed { failures += 1 }
}

// ---- the real type, pasted in by the extractor at run time ----------------

print("the number row — one physical key, two characters, and people press both")
check("\"+\" raises",  SliderNudgeKey.forKeyPress(keyCode: 24, characters: "+") == .increase)
check("\"=\" raises too, which is that key unshifted",
      SliderNudgeKey.forKeyPress(keyCode: 24, characters: "=") == .increase)
check("\"-\" lowers",  SliderNudgeKey.forKeyPress(keyCode: 27, characters: "-") == .decrease)
check("\"_\" lowers too", SliderNudgeKey.forKeyPress(keyCode: 27, characters: "_") == .decrease)

print("\nthe keypad, matched by code so an odd layout still works")
check("keypad + raises", SliderNudgeKey.forKeyPress(keyCode: 69, characters: nil) == .increase)
check("keypad − lowers", SliderNudgeKey.forKeyPress(keyCode: 78, characters: nil) == .decrease)
check("and the code wins over a character that disagrees",
      SliderNudgeKey.forKeyPress(keyCode: 69, characters: "-") == .increase)

print("\n⚠️ THE ARROWS ARE NOT THE SLIDER ANY MORE — they are the filmstrip")
check("← is not a nudge", SliderNudgeKey.forKeyPress(keyCode: 123, characters: nil) == nil)
check("→ is not a nudge", SliderNudgeKey.forKeyPress(keyCode: 124, characters: nil) == nil)
check("↑ is not a nudge", SliderNudgeKey.forKeyPress(keyCode: 126, characters: nil) == nil)
check("↓ is not a nudge", SliderNudgeKey.forKeyPress(keyCode: 125, characters: nil) == nil)

print("\nand nothing else is a nudge either")
for (code, character) in [(0, "a"), (12, "q"), (14, "e"), (49, " "), (36, "\r"), (53, "\u{1b}")] {
    check("\(character.debugDescription) is left alone",
          SliderNudgeKey.forKeyPress(keyCode: UInt16(code), characters: character) == nil)
}

print()
if failures == 0 {
    print("− and + move the armed slider; the arrows are free for the photographs.")
} else {
    print("\(failures) failed")
}
exit(failures == 0 ? 0 : 1)
