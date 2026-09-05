// Runs the REAL DeleteKeyAction from Develop.swift against every combination
// that matters. Driven by Tools/run-delete-key-test.py, which pastes the type
// in below at run time so this can never drift from the shipping decision.
//
// The bug it was written for: Backspace pressed while typing a preset name
// deleted the PHOTOGRAPH. Reported by the client on 05.09 with a screenshot of
// the presets popover, the name field holding "C4S".
import Foundation
import AppKit

// ---- the real type, pasted in by the extractor at run time ----------------

var failures = 0

func check(_ label: String, _ got: DeleteKeyAction, _ want: DeleteKeyAction) {
    let ok = got == want
    if !ok { failures += 1 }
    print("  \(ok ? "ok  " : "FAIL") \(label.padding(toLength: 58, withPad: " ", startingAt: 0)) \(got)")
}

let backspace: UInt16 = 51
let forwardDelete: UInt16 = 117
let none: NSEvent.ModifierFlags = []

print("TYPING — the key belongs to the text, always")
for (name, code) in [("backspace", backspace), ("forward delete", forwardDelete)] {
    for (fname, flags) in [("no modifier", none), ("command", NSEvent.ModifierFlags.command)] {
        for (sname, sel, ph) in [("nothing selected", false, true),
                                 ("a mask armed", true, true),
                                 ("no photo open", false, false)] {
            check("\(name), \(fname), \(sname)",
                  DeleteKeyAction.forKeyPress(keyCode: code, flags: flags, isTyping: true,
                                              hasSelectedItem: sel, hasPhotoTargets: ph),
                  .ignore)
        }
    }
}

print("\nNOT TYPING — the mask wins over the photograph")
check("backspace, mask armed",
      DeleteKeyAction.forKeyPress(keyCode: backspace, flags: none, isTyping: false,
                                  hasSelectedItem: true, hasPhotoTargets: true),
      .removeSelectedItem)
check("forward delete, mask armed",
      DeleteKeyAction.forKeyPress(keyCode: forwardDelete, flags: none, isTyping: false,
                                  hasSelectedItem: true, hasPhotoTargets: true),
      .removeSelectedItem)
check("backspace, nothing selected",
      DeleteKeyAction.forKeyPress(keyCode: backspace, flags: none, isTyping: false,
                                  hasSelectedItem: false, hasPhotoTargets: true),
      .trashPhoto)
check("command+backspace, nothing selected",
      DeleteKeyAction.forKeyPress(keyCode: backspace, flags: .command, isTyping: false,
                                  hasSelectedItem: false, hasPhotoTargets: true),
      .trashPhoto)
check("backspace, nothing to delete at all",
      DeleteKeyAction.forKeyPress(keyCode: backspace, flags: none, isTyping: false,
                                  hasSelectedItem: false, hasPhotoTargets: false),
      .ignore)
check("shift+backspace is not a delete",
      DeleteKeyAction.forKeyPress(keyCode: backspace, flags: .shift, isTyping: false,
                                  hasSelectedItem: false, hasPhotoTargets: true),
      .ignore)
check("a letter key is never a delete",
      DeleteKeyAction.forKeyPress(keyCode: 12, flags: none, isTyping: false,
                                  hasSelectedItem: true, hasPhotoTargets: true),
      .ignore)

print(failures == 0 ? "\nRESULT: OK — \(failures) failures"
                    : "\nRESULT: FAILED — \(failures) case(s)")
exit(failures == 0 ? 0 : 1)
