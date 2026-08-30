//
//  CameraImport.swift
//  BriefShow
//
//  Import straight off a camera connected by USB, the way Lightroom's
//  Import dialog does it: plug the camera in, switch it on, and the whole
//  card shows up as a grid of thumbnails ready to be copied to the Mac.
//
//  Everything here goes through ImageCaptureCore, which is the same
//  framework Image Capture.app and Lightroom use. It speaks PTP/MTP, so it
//  covers cameras that never mount as a disk — a Nikon Z 6 in its default
//  "MTP/PTP" USB mode is exactly that case, and is why simply browsing for a
//  mounted volume would not have worked.
//

import SwiftUI
import Combine
import AppKit
import ImageCaptureCore

// MARK: - Which cameras are plugged in

/// One camera the Mac can currently see.
///
/// A wrapper rather than the `ICCameraDevice` itself because SwiftUI needs a
/// stable `Identifiable`, and `ICCameraDevice` is a reference type whose
/// identity SwiftUI cannot key a `ForEach` on.
struct ConnectedCamera: Identifiable, Equatable {
    let device: ICCameraDevice

    // uuidString is the camera's own identifier and survives a session being
    // opened and closed; the name is the fallback for devices that do not
    // report one (some card readers).
    var id: String {
        device.uuidString ?? device.name ?? String(UInt(bitPattern: ObjectIdentifier(device).hashValue))
    }

    var name: String { device.name ?? "Camera" }

    static func == (lhs: ConnectedCamera, rhs: ConnectedCamera) -> Bool {
        lhs.device === rhs.device
    }
}

/// Watches USB for cameras being connected and disconnected.
///
/// One shared instance for the whole app, started once at launch: an
/// `ICDeviceBrowser` is a long-lived object, and a second one browsing the
/// same device type only duplicates the callbacks.
final class CameraBrowser: NSObject, ObservableObject {
    static let shared = CameraBrowser()

    @Published private(set) var cameras: [ConnectedCamera] = []

    /// Bumped every time a camera is newly connected. The UI watches this
    /// (rather than `cameras`) to decide when to open the import window by
    /// itself, so a camera that was ALREADY plugged in when the app launched
    /// does not pop a window over whatever the client was doing.
    @Published private(set) var lastConnectedCamera: ConnectedCamera?

    private let browser = ICDeviceBrowser()
    private var hasStarted = false

    private override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // Cameras only, and only locally attached ones (USB). The two masks
        // are separate enums that have to be OR'd together into the one
        // property — this is the documented way to say "local cameras", and
        // without the location half the browser also reports shared and
        // Bonjour devices from other Macs on the network.
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }

    func camera(withID id: String) -> ConnectedCamera? {
        cameras.first { $0.id == id }
    }
}

extension CameraBrowser: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        let connected = ConnectedCamera(device: camera)
        guard !cameras.contains(connected) else { return }
        cameras.append(connected)
        lastConnectedCamera = connected
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        cameras.removeAll { $0.device === device }
        if lastConnectedCamera?.device === device {
            lastConnectedCamera = nil
        }
    }
}

// MARK: - One camera's contents, and copying them across

/// Opens a session on one camera, lists what is on the card, and copies the
/// chosen files to a folder on the Mac.
///
/// Deliberately NOT `@MainActor`: ImageCaptureCore's delegate callbacks arrive
/// on the main thread but its *block* callbacks (thumbnail and download
/// completions) are documented as running on "any available queue". Marking the
/// class main-actor would only move that problem to a compile error, so the
/// block callbacks hop to main explicitly instead and the published state is
/// only ever touched there.
final class CameraImportSession: NSObject, ObservableObject {

    struct Item: Identifiable {
        let file: ICCameraFile
        let id: String
        let name: String
        let byteSize: Int64
        let created: Date?
        var thumbnail: NSImage?
        var isChecked: Bool = true
    }

    enum Phase: Equatable {
        case connecting
        case listing
        case ready
        case importing
        case finished(count: Int, destination: URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var items: [Item] = []

    /// Progress while copying: which file is being written, and how many are
    /// done. Kept separate from `items` so a copy in flight does not redraw
    /// the whole grid on every byte.
    @Published private(set) var completedCount: Int = 0
    @Published private(set) var currentFileName: String = ""

    let camera: ConnectedCamera

    private var didOpenSession = false

    /// Thumbnail requests in flight. ImageCaptureCore will happily accept a
    /// request for every file on the card at once, and on a full card that is
    /// thousands of outstanding PTP round trips — which starves the download
    /// that comes afterwards. Six at a time keeps the grid filling visibly
    /// while leaving the camera's USB endpoint free.
    private var thumbnailsInFlight = 0
    private var thumbnailQueue: [String] = []
    private let maxThumbnailsInFlight = 6

    /// Set when the window goes away, so a download that is already running
    /// stops after the file it is on rather than continuing against a session
    /// that is being torn down.
    private var isCancelled = false

    init(camera: ConnectedCamera) {
        self.camera = camera
        super.init()
        camera.device.delegate = self
        camera.device.requestOpenSession()
    }

    deinit {
        // ICDevice's `delegate` is declared `assign`, NOT `weak` — a
        // deallocated session left sitting in that slot is a dangling pointer,
        // and the next callback crashes the app. That callback is typically
        // the camera being unplugged, minutes after this window was closed,
        // which makes it about as hard to connect back to its cause as a crash
        // gets.
        //
        // Cleared here rather than only in close(), because close() runs from
        // onDisappear and is not guaranteed on every path this object can go
        // away on. Guarded on identity because reopening the import window for
        // the same camera builds a NEW session that has already claimed the
        // slot — clearing it blind would silence that one instead of this one.
        if (camera.device.delegate as AnyObject?) === self {
            camera.device.delegate = nil
        }
    }

    var checkedItems: [Item] { items.filter(\.isChecked) }

    var totalCheckedBytes: Int64 {
        checkedItems.reduce(0) { $0 + $1.byteSize }
    }

    // MARK: Selection

    func setChecked(_ isChecked: Bool, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isChecked = isChecked
    }

    func setAllChecked(_ isChecked: Bool) {
        for index in items.indices {
            items[index].isChecked = isChecked
        }
    }

    // MARK: Teardown

    /// Closes the session. Called when the import window is dismissed — a
    /// camera left with an open session stays locked to this app, and on most
    /// bodies that means the client cannot use the camera itself until
    /// BriefShow quits.
    func close() {
        isCancelled = true
        guard didOpenSession else { return }
        didOpenSession = false
        camera.device.requestCloseSession()
    }

    // MARK: Listing

    private func rebuildItems() {
        // `mediaFiles` is every image, movie and audio file on the card,
        // flattened out of the DCIM folder structure — which is what the grid
        // wants. Sorted by capture time so the card reads in the order it was
        // shot, oldest first, matching the filmstrip everywhere else in the app.
        let files = (camera.device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }

        let existing = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = files
            .map { file -> Item in
                let id = itemID(for: file)
                let name = file.name ?? file.originalFilename ?? id
                // A file already in the list keeps its thumbnail and its
                // checkbox: this runs again every time the camera reports more
                // items, and rebuilding from scratch would blank the grid and
                // silently undo the client's unchecking mid-enumeration.
                return Item(
                    file: file,
                    id: id,
                    name: name,
                    byteSize: Int64(file.fileSize),
                    created: file.creationDate,
                    thumbnail: existing[id]?.thumbnail,
                    isChecked: existing[id]?.isChecked ?? true)
            }
            .sorted { lhs, rhs in
                switch (lhs.created, rhs.created) {
                case let (left?, right?) where left != right: return left < right
                default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }

        enqueueMissingThumbnails()
    }

    private func itemID(for file: ICCameraFile) -> String {
        // Name alone is not unique across two cards in one camera (both hold a
        // DSC_0001), and the PTP object handle is not exposed. Name plus byte
        // size is what the rest of this app already uses to identify a photo
        // it has seen before — see PhotoLabelStore — so the same rule is used
        // here rather than a second, different one.
        "\(file.name ?? file.originalFilename ?? "?")-\(file.fileSize)"
    }

    // MARK: Thumbnails

    private func enqueueMissingThumbnails() {
        let missing = items.filter { $0.thumbnail == nil }.map(\.id)
        for id in missing where !thumbnailQueue.contains(id) {
            thumbnailQueue.append(id)
        }
        pumpThumbnailQueue()
    }

    private func pumpThumbnailQueue() {
        while thumbnailsInFlight < maxThumbnailsInFlight, !thumbnailQueue.isEmpty {
            let id = thumbnailQueue.removeFirst()
            guard let item = items.first(where: { $0.id == id }), item.thumbnail == nil else { continue }
            thumbnailsInFlight += 1
            requestThumbnail(for: item)
        }
    }

    private func requestThumbnail(for item: Item) {
        // 512 rather than the embedded EXIF thumbnail's own size: the grid
        // draws these at up to 320pt on a Retina display, and the camera's
        // built-in thumbnail is typically 160px, which looks like a smear.
        // ImageCaptureCore renders this one from the file itself.
        item.file.requestThumbnailData(
            options: [.imageSourceThumbnailMaxPixelSize: NSNumber(value: 512)]
        ) { [weak self] data, _ in
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                guard let self, !self.isCancelled else { return }
                self.thumbnailsInFlight -= 1
                if let image, let index = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[index].thumbnail = image
                }
                self.pumpThumbnailQueue()
            }
        }
    }

    // MARK: Importing

    /// Copies every checked file into `destination`, one at a time.
    ///
    /// Sequential on purpose. Parallel downloads off a single camera do not go
    /// faster — one USB endpoint, one card reader behind it — and they make the
    /// progress meaningless and a partial failure much harder to report.
    func startImport(
        to destination: URL,
        intoDatedSubfolder: Bool,
        deleteFromCameraAfterwards: Bool
    ) {
        let files = checkedItems
        guard !files.isEmpty else { return }

        let folder: URL
        if intoDatedSubfolder {
            // Grouped by the date the photos were TAKEN, not today's date: a
            // card imported the morning after a shoot belongs under the day of
            // the shoot, which is the whole reason to organise by date. Falls
            // back to today for files with no capture date.
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let day = formatter.string(from: files.first?.created ?? Date())
            folder = destination.appendingPathComponent(day, isDirectory: true)
        } else {
            folder = destination
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Could not create \(folder.lastPathComponent): \(error.localizedDescription)")
            return
        }

        completedCount = 0
        phase = .importing
        downloadNext(remaining: files, into: folder, deleteAfterwards: deleteFromCameraAfterwards)
    }

    private func downloadNext(remaining: [Item], into folder: URL, deleteAfterwards: Bool) {
        guard !isCancelled else { return }
        guard let item = remaining.first else {
            phase = .finished(count: completedCount, destination: folder)
            return
        }
        let rest = Array(remaining.dropFirst())
        currentFileName = item.name

        var options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: folder as NSURL,
            .saveAsFilename: item.name,
            // Never silently replace a file already on the Mac. ImageCaptureCore
            // uniquifies the name instead (DSC_0001-1.NEF), which is the safe
            // side of a decision the client cannot undo.
            .overwrite: NSNumber(value: false)
        ]
        if deleteAfterwards {
            options[.deleteAfterSuccessfulDownload] = NSNumber(value: true)
        }

        _ = item.file.requestDownload(options: options) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self, !self.isCancelled else { return }
                if let error {
                    self.phase = .failed("\(item.name): \(error.localizedDescription)")
                    return
                }
                self.completedCount += 1
                self.downloadNext(remaining: rest, into: folder, deleteAfterwards: deleteAfterwards)
            }
        }
    }
}

// MARK: - ImageCaptureCore delegate plumbing

// ICCameraDeviceDelegate declares a long list of REQUIRED methods, most of
// which this app has no use for (PTP events, renames, capability changes).
// They are implemented as no-ops rather than left out because Swift will not
// let the class conform without them.
extension CameraImportSession: ICCameraDeviceDelegate {

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            phase = .failed("Could not open \(camera.name): \(error.localizedDescription)")
            return
        }
        didOpenSession = true
        phase = .listing
        rebuildItems()
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        didOpenSession = false
    }

    func didRemove(_ device: ICDevice) {
        // The camera was unplugged or switched off mid-import. Say so plainly:
        // anything already copied is on disk and fine, and the client's next
        // question is always "did I lose the rest".
        guard device === camera.device else { return }
        isCancelled = true
        if case .finished = phase { return }
        phase = .failed("\(camera.name) was disconnected. \(completedCount) file\(completedCount == 1 ? "" : "s") had already been copied.")
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        rebuildItems()
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        rebuildItems()
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        rebuildItems()
        // Only now is the count on screen the real one. Before this the camera
        // is still walking the card and the grid grows as it goes, which is
        // why "N photos" is not shown until this fires.
        if case .listing = phase {
            phase = .ready
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        rebuildItems()
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        // Unused: thumbnails are requested through the block API above, which
        // does not route back through the delegate.
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        // The camera stopped refusing access — usually the client answered the
        // "Trust this computer?" prompt on the body, or took it off a mode
        // where it locks its card. Whatever was on screen is now stale.
        rebuildItems()
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        phase = .failed("\(camera.name) is locking its card. Set the camera's USB mode to MTP/PTP and switch it on again.")
    }
}
