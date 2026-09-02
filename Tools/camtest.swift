// camtest.swift — what ImageCaptureCore actually reports about a connected camera.
//
// Written for one measurement. The client's Z 6 shows up in BriefShow, the
// import window opens, and the source panel then says "0 files on the card".
// That exact wording is the finding: CameraImportView.statusLine only produces
// it for phase .ready/.importing/.finished/.failed — phase .listing would have
// said "Reading the card… 0 so far". So the session OPENED, the camera reported
// a complete content catalog, and `mediaFiles` came back EMPTY.
//
// Two hypotheses, and this tool is here to choose between them by measurement
// rather than by argument:
//
//   1. ICCameraDevice.mediaFiles is a FILTERED list — only what
//      ImageCaptureCore recognises as media by UTI. A NEF from a body the
//      system does not know would fall out of it. `contents` (the folder tree)
//      filters nothing. If the recursive walk below finds files that
//      `mediaFiles` does not, this is the answer and the fix is to walk
//      `contents` in CameraImport.swift.
//
//   2. Two device objects for one camera. The camera is listed TWICE in the
//      client's screenshots ("LOC:346030080" twice, "Z 6" twice), and
//      CameraBrowser dedupes on `device ===`, so two distinct objects for one
//      body both survive. If the session is opened on the wrong one, the
//      catalog is empty. If the listing below shows two entries with the SAME
//      uuidString, this is the answer and the fix is to dedupe on uuid.
//
// ⚠️ This tool is NOT sandboxed and the app is. If files show up here but not
// in BriefShow, the answer is the sandbox and BOTH hypotheses are wrong — which
// is still a finding, and a more useful one.
//
// Run with the camera plugged in and switched on:
//
//     swift Tools/camtest.swift
//
// It waits 40 seconds by default; pass a different number of seconds to change
// that. Enumerating a full card takes a while, so give it the time.

import Foundation
import ImageCaptureCore

let deadline = CommandLine.arguments.count > 1
    ? (Double(CommandLine.arguments[1]) ?? 40)
    : 40

let started = Date()

func log(_ message: String) {
    let elapsed = String(format: "%6.2fs", Date().timeIntervalSince(started))
    print("[\(elapsed)] \(message)")
    fflush(stdout)
}

/// A camera's transport, spelled out — the raw string is what tells a PTP
/// camera apart from a card reader mounted as mass storage.
func describe(_ device: ICCameraDevice) -> String {
    var parts: [String] = []
    parts.append("name=\(device.name ?? "<nil>")")
    parts.append("uuid=\(device.uuidString ?? "<nil>")")
    parts.append("transport=\(device.transportType ?? "<nil>")")
    parts.append("hasOpenSession=\(device.hasOpenSession)")
    // The pointer, so two entries for one body can be told apart from one
    // entry reported twice — which is exactly hypothesis 2.
    parts.append("ptr=\(Unmanaged.passUnretained(device).toOpaque())")
    return parts.joined(separator: "  ")
}

/// Every ICCameraFile under `items`, walking folders — the thing `mediaFiles`
/// may be filtering.
func allFiles(under items: [ICCameraItem]) -> [ICCameraFile] {
    var found: [ICCameraFile] = []
    for item in items {
        if let file = item as? ICCameraFile {
            found.append(file)
        } else if let folder = item as? ICCameraFolder {
            found.append(contentsOf: allFiles(under: folder.contents ?? []))
        }
    }
    return found
}

final class Probe: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    let browser = ICDeviceBrowser()
    var seen: [ICCameraDevice] = []
    var didReport = false

    func start() {
        browser.delegate = self
        // The same mask CameraBrowser.start() uses, so this tool is looking at
        // what the app looks at and not at something adjacent.
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        log("browser started, mask = camera | local")
    }

    // MARK: Browser

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else {
            log("didAdd  NON-CAMERA  \(device.name ?? "<nil>")")
            return
        }
        seen.append(camera)
        log("didAdd  #\(seen.count)  moreComing=\(moreComing)")
        log("        \(describe(camera))")

        camera.delegate = self
        camera.requestOpenSession()
        log("        requestOpenSession sent")
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        log("didRemove  \(device.name ?? "<nil>")")
    }

    // MARK: Camera

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            log("didOpenSession  FAILED  \(device.name ?? "<nil>")  \(error)")
            return
        }
        log("didOpenSession  OK  \(device.name ?? "<nil>")")
        if let camera = device as? ICCameraDevice {
            report(camera, when: "right after the session opened")
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        log("didCloseSession  \(device.name ?? "<nil>")  error=\(String(describing: error))")
    }

    func didRemove(_ device: ICDevice) {
        log("didRemove(device)  \(device.name ?? "<nil>")")
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        // THE moment that matters. This is the callback that moves the app's
        // phase to .ready, which is what produced "0 files on the card".
        log("deviceDidBecomeReady(withCompleteContentCatalog)  ***")
        report(device, when: "at complete content catalog")
        didReport = true
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        log("didAdd items  +\(items.count)")
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        log("didRemove items  -\(items.count)")
    }

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        log("didChangeCapability")
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        log("didRemoveAccessRestriction  — the camera stopped refusing access")
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        log("*** didEnableAccessRestriction — the camera is LOCKING its card ***")
    }

    // MARK: The comparison this whole tool exists for

    func report(_ camera: ICCameraDevice, when: String) {
        let media = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        let top = camera.contents ?? []
        let walked = allFiles(under: top)

        log("REPORT (\(when)) for \(camera.name ?? "<nil>")")
        log("    mediaFiles            = \(media.count)")
        log("    contents (top level)  = \(top.count)")
        log("    files under contents  = \(walked.count)   <-- hypothesis 1 hinges on this")

        if walked.count > media.count {
            log("    *** contents has MORE files than mediaFiles — HYPOTHESIS 1 CONFIRMED ***")
            let mediaNames = Set(media.map { $0.name ?? "" })
            let missing = walked.filter { !mediaNames.contains($0.name ?? "") }
            log("    \(missing.count) file(s) mediaFiles left out. First few, with their UTIs:")
            for file in missing.prefix(8) {
                log("      \(file.name ?? "<nil>")  uti=\(file.uti ?? "<nil>")  size=\(file.fileSize)")
            }
        } else if walked.isEmpty && media.isEmpty {
            log("    *** BOTH ARE EMPTY — the camera is reporting no files at all. ***")
            log("    Neither hypothesis. Look at the USB mode on the body, and at")
            log("    whether Image Capture.app sees the card: if it does not, the")
            log("    problem is the camera or the cable, not this code.")
        } else {
            log("    mediaFiles is not short — hypothesis 1 does NOT explain it.")
        }

        for file in walked.prefix(3) {
            log("    sample: \(file.name ?? "<nil>")  uti=\(file.uti ?? "<nil>")")
        }
    }

    func summarise() {
        log("")
        log("=== SUMMARY ===")
        log("devices reported by the browser: \(seen.count)")
        for (index, camera) in seen.enumerated() {
            log("  #\(index + 1)  \(describe(camera))")
        }

        let uuids = seen.compactMap { $0.uuidString }
        if seen.count > 1 && Set(uuids).count < seen.count {
            log("*** TWO ENTRIES SHARE ONE uuidString — HYPOTHESIS 2 CONFIRMED ***")
            log("    CameraBrowser dedupes on `device ===`, so both survive, and the")
            log("    SwiftUI ForEach gets duplicate ids. Dedupe on uuidString.")
        } else if seen.count > 1 {
            log("Two entries, DIFFERENT uuids — genuinely two devices, not one listed")
            log("twice. Report which one held the files.")
        }

        if !didReport {
            log("deviceDidBecomeReady NEVER FIRED within the time limit.")
            log("That alone contradicts the screenshot, where the app had reached")
            log(".ready — run it again with a longer timeout before concluding.")
        }

        for camera in seen where camera.hasOpenSession {
            camera.requestCloseSession()
        }
    }
}

let probe = Probe()
probe.start()

log("waiting \(Int(deadline))s — switch the camera on and set its USB mode to MTP/PTP")
RunLoop.current.run(until: Date().addingTimeInterval(deadline))
probe.summarise()
// A beat for requestCloseSession to land, so the camera is not left locked to
// this process — the same reason CameraImportSession.close() exists.
RunLoop.current.run(until: Date().addingTimeInterval(1.5))
