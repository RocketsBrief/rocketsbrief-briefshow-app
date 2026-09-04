import Foundation

// Checks the GCD behaviour the update-quit in AccountUI.swift leans on. The
// button's action cannot be scripted from here — it is inside a SwiftUI
// closure behind an overlay that only appears when the server offers a newer
// version than the bundle — so this exercises the two claims the code makes
// about the timer itself, and run-update-quit-test.py checks that the app is
// in fact wired that way.
//
//  1. A DispatchWorkItem scheduled with asyncAfter(+4) runs at four seconds,
//     not at the moment the browser hand-off calls back. This is the whole
//     point of the change: the old code quit from inside the completion
//     handler, so a slow or silent callback left the app sitting open.
//  2. Cancelling that work item before the deadline stops it for good. That is
//     the one escape hatch — a browser that never took the URL must not leave
//     the client with neither a download nor an app.

var failures = 0

func check(_ condition: Bool, _ what: String) {
    if !condition {
        failures += 1
        print("FAIL  \(what)")
    } else {
        print("ok    \(what)")
    }
}

let quitDelay: TimeInterval = 4

// 1. Fires on the clock, and is NOT hurried by the callback landing early.
do {
    let fired = DispatchSemaphore(value: 0)
    var firedAt: TimeInterval = -1
    let start = Date()

    let quit = DispatchWorkItem {
        firedAt = Date().timeIntervalSince(start)
        fired.signal()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + quitDelay, execute: quit)

    // Stands in for the browser hand-off succeeding almost immediately, which
    // is what actually happens: NSWorkspace.open calls back in milliseconds.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { /* no cancel */ }

    // The app quits on the main queue, so the test has to keep it running.
    DispatchQueue.global().async {
        _ = fired.wait(timeout: .now() + 10)
        DispatchQueue.main.async { CFRunLoopStop(CFRunLoopGetMain()) }
    }
    CFRunLoopRun()

    check(firedAt >= 3.9 && firedAt <= 4.6,
          "quit fires on the clock, not on the callback (measured \(String(format: "%.2f", firedAt)) s)")
}

// 2. Cancelled before the deadline, it never runs at all.
do {
    var ranAnyway = false
    let quit = DispatchWorkItem { ranAnyway = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + quitDelay, execute: quit)

    // Stands in for the hand-off FAILING: error != nil, so the quit is called off.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { quit.cancel() }

    DispatchQueue.main.asyncAfter(deadline: .now() + quitDelay + 1.5) {
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()

    check(!ranAnyway,
          "a failed hand-off cancels the quit, and it stays cancelled past the deadline")
    check(quit.isCancelled, "the work item reports itself cancelled")
}

print(failures == 0 ? "RESULT: OK" : "RESULT: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
