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

    // Compared by IDENTITY, not by object pointer.
    //
    // `===` was the old rule and it let one camera into the list twice: the
    // client's screenshots from 1.09. show the Z 6 listed twice in both of
    // them, and ImageCaptureCore had handed over two distinct ICCameraDevice
    // objects for the one body. Two objects, two `===` misses, two rows — and
    // two rows whose SwiftUI `id` is the same uuidString, which is undefined
    // behaviour in a ForEach on top of merely looking wrong.
    //
    // Falling back to the pointer only when there is no uuid and no name,
    // because then there is nothing else to go on and two rows are better than
    // silently swallowing a second real camera.
    static func == (lhs: ConnectedCamera, rhs: ConnectedCamera) -> Bool {
        lhs.id == rhs.id
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

/// Where an import is reading FROM.
///
/// Two kinds, because two different things are actually plugged in and only one
/// of them is a camera:
///
/// - A body in MTP/PTP mode never mounts as a disk, and is reachable only
///   through ImageCaptureCore. That is `.camera`.
/// - An SD card in a reader mounts as an ordinary volume, and a client who
///   picks File ▸ Import… with nothing plugged in wants to point at a folder.
///   Both of those are `.folder` — one code path, because once a card is
///   mounted it IS just a folder with a DCIM in it.
enum ImportSource: Identifiable, Equatable {
    case camera(ConnectedCamera)
    case folder(URL)

    var id: String {
        switch self {
        case .camera(let camera): return "camera:\(camera.id)"
        case .folder(let url): return "folder:\(url.path)"
        }
    }

    var displayName: String {
        switch self {
        case .camera(let camera): return camera.name
        case .folder(let url): return url.lastPathComponent
        }
    }

    var camera: ConnectedCamera? {
        if case .camera(let camera) = self { return camera }
        return nil
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

    /// The one thing an Item needs that differs between the two sources: what
    /// to ask for a thumbnail, and what to copy.
    enum Origin {
        case cameraFile(ICCameraFile)
        case diskFile(URL)
    }

    struct Item: Identifiable {
        let origin: Origin
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

    let source: ImportSource

    /// Nil for a folder import — there is no session to open, nothing to lock,
    /// and no delegate to clear.
    var camera: ConnectedCamera? { source.camera }

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

    init(source: ImportSource) {
        self.source = source
        super.init()

        switch source {
        case .camera(let camera):
            camera.device.delegate = self
            camera.device.requestOpenSession()

        case .folder(let url):
            // No session, no delegate, no waiting. A folder is readable now, so
            // the scan runs immediately and the window opens straight into
            // .ready rather than showing a spinner for something that already
            // finished.
            scanFolder(url)
        }
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
        if let camera, (camera.device.delegate as AnyObject?) === self {
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
        guard didOpenSession, let camera else { return }
        didOpenSession = false
        camera.device.requestCloseSession()
    }

    // MARK: Listing

    /// Extensions worth importing when ImageCaptureCore does not recognise the
    /// file itself.
    ///
    /// Only consulted for files `mediaFiles` left out — see `rebuildItems`. The
    /// list is deliberately explicit rather than "anything that is not a
    /// folder": walking the card raw would also drag in the sidecars and
    /// housekeeping files every body writes (Nikon's .NKSC, the MISC folder),
    /// and a grid full of those is worse than a grid that is short.
    private static let importableExtensions: Set<String> = [
        // RAW, by maker
        "nef", "nrw", "cr2", "cr3", "crw", "arw", "srf", "sr2", "raf", "orf",
        "rw2", "pef", "dng", "raw", "3fr", "fff", "iiq", "x3f", "erf", "mrw",
        "mos", "gpr",
        // ordinary stills
        "jpg", "jpeg", "jpe", "png", "tif", "tiff", "heic", "heif", "avif",
        "webp", "bmp", "gif",
        // movies
        "mov", "mp4", "m4v", "avi", "mts", "m2ts", "mxf",
        // audio — some bodies attach a voice memo to a frame
        "wav", "aiff", "aif", "mp3", "m4a"
    ]

    /// Every file under `items`, walking into folders.
    ///
    /// `contents` is the card's real folder tree (DCIM/100NIKON/...) and
    /// filters nothing, which is the whole reason it is read here.
    private func allFiles(under items: [ICCameraItem]) -> [ICCameraFile] {
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

    private func rebuildItems() {
        // `mediaFiles` is ImageCaptureCore's own flattened list of the image,
        // movie and audio files on the card. It is the right list — when it is
        // complete.
        //
        // ⚠️ It is a FILTERED list: only what the system recognises as media by
        // UTI. That is the leading explanation for the 1.09. report, where the
        // import window reached phase .ready — the camera had reported a
        // COMPLETE content catalog — and still said "0 files on the card".
        //
        // So the card's own folder tree is walked as well and the two are
        // UNIONED. Strictly additive: a file `mediaFiles` already knows about
        // is unaffected, and one it left out is picked up if its extension is
        // recognisable. Nothing that used to import stops importing.
        //
        // Measure before changing this further: Tools/camtest.swift prints
        // mediaFiles.count against the walk on a real camera and names the
        // files (and UTIs) that fall between them.
        // Guarded rather than forced: this only ever runs from the camera
        // delegate callbacks, but the compiler cannot know that, and a crash
        // here would be on a card the client is halfway through reading.
        guard let camera else { return }
        let known = (camera.device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        let knownIDs = Set(known.map { itemID(for: $0) })
        let extras = allFiles(under: camera.device.contents ?? []).filter { file in
            guard !knownIDs.contains(itemID(for: file)) else { return false }
            let ext = (file.name ?? file.originalFilename ?? "").split(separator: ".").last?.lowercased() ?? ""
            return Self.importableExtensions.contains(ext)
        }
        // Sorted by capture time below, so the card reads in the order it was
        // shot, oldest first, matching the filmstrip everywhere else in the app.
        let files = known + extras

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
                    origin: .cameraFile(file),
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

    /// Reads a folder — a mounted SD card, or anywhere the client pointed at.
    ///
    /// Walks into subfolders, because that is where the photos are: a card puts
    /// them under DCIM/100NIKON, never at the top. Same extension list the
    /// camera path uses for files ImageCaptureCore did not recognise, so the
    /// two sources agree on what counts as a photo.
    private func scanFolder(_ folder: URL) {
        phase = .listing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
            var found: [Item] = []

            if let walker = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in walker {
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    guard values?.isDirectory != true else { continue }
                    guard Self.importableExtensions.contains(url.pathExtension.lowercased()) else { continue }

                    let size = Int64(values?.fileSize ?? 0)
                    found.append(Item(
                        origin: .diskFile(url),
                        // Same name+size key the camera path uses, so a card
                        // imported once as a camera and once as a volume is the
                        // same photo to the rest of the app.
                        id: "\(url.lastPathComponent)-\(size)",
                        name: url.lastPathComponent,
                        byteSize: size,
                        // creationDate is the capture time for a file written by
                        // a camera; modification date is the fallback for one
                        // that has been copied around since.
                        created: values?.creationDate ?? values?.contentModificationDate,
                        thumbnail: nil,
                        isChecked: true))
                }
            }

            let sorted = found.sorted { lhs, rhs in
                switch (lhs.created, rhs.created) {
                case let (left?, right?) where left != right: return left < right
                default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }

            DispatchQueue.main.async {
                guard let self, !self.isCancelled else { return }
                self.items = sorted
                self.phase = .ready
                self.enqueueMissingThumbnails()
            }
        }
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
        switch item.origin {
        case .cameraFile(let file):
            // ImageCaptureCore renders this one from the file itself.
            file.requestThumbnailData(
                options: [.imageSourceThumbnailMaxPixelSize: NSNumber(value: 512)]
            ) { [weak self] data, _ in
                let image = data.flatMap { NSImage(data: $0) }
                DispatchQueue.main.async {
                    self?.finishThumbnail(image, for: item)
                }
            }

        case .diskFile(let url):
            // ImageIO, off the main thread — the same call ShowGrid's own
            // thumbnails go through, so a RAW on a card decodes here exactly
            // the way it will once it is copied across.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let image = makeShowGridThumbnail(from: url, maxPixelSize: 512)
                DispatchQueue.main.async {
                    self?.finishThumbnail(image, for: item)
                }
            }
        }
    }

    private func finishThumbnail(_ image: NSImage?, for item: Item) {
        guard !isCancelled else { return }
        thumbnailsInFlight -= 1
        if let image, let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].thumbnail = image
        }
        pumpThumbnailQueue()
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

        switch item.origin {
        case .cameraFile(let file):
            _ = file.requestDownload(options: options) { [weak self] _, error in
                DispatchQueue.main.async {
                    self?.finishOne(item, error: error, remaining: rest,
                                    into: folder, deleteAfterwards: deleteAfterwards)
                }
            }

        case .diskFile(let url):
            // A plain copy, off the main thread — a 45MB RAW per file, and the
            // window has to keep drawing its progress while they go across.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var copyError: Error?
                var destination = folder.appendingPathComponent(item.name)
                // Never silently replace a file already on the Mac, matching
                // what .overwrite:false gives the camera path. The camera path
                // gets uniquing for free from ImageCaptureCore; here it has to
                // be done by hand, and in the same shape (name-1.NEF).
                if FileManager.default.fileExists(atPath: destination.path) {
                    let base = destination.deletingPathExtension().lastPathComponent
                    let ext = destination.pathExtension
                    var suffix = 1
                    repeat {
                        let candidate = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
                        destination = folder.appendingPathComponent(candidate)
                        suffix += 1
                    } while FileManager.default.fileExists(atPath: destination.path)
                }

                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    if deleteAfterwards {
                        // Only after the copy has actually landed — the same
                        // order .deleteAfterSuccessfulDownload gives the camera
                        // path, and the only order that is safe.
                        try? FileManager.default.removeItem(at: url)
                    }
                } catch {
                    copyError = error
                }

                DispatchQueue.main.async {
                    self?.finishOne(item, error: copyError, remaining: rest,
                                    into: folder, deleteAfterwards: deleteAfterwards)
                }
            }
        }
    }

    private func finishOne(
        _ item: Item,
        error: Error?,
        remaining: [Item],
        into folder: URL,
        deleteAfterwards: Bool
    ) {
        guard !isCancelled else { return }
        if let error {
            phase = .failed("\(item.name): \(error.localizedDescription)")
            return
        }
        completedCount += 1
        downloadNext(remaining: remaining, into: folder, deleteAfterwards: deleteAfterwards)
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
            phase = .failed("Could not open \(source.displayName): \(error.localizedDescription)")
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
        guard let camera, device === camera.device else { return }
        isCancelled = true
        if case .finished = phase { return }
        phase = .failed("\(source.displayName) was disconnected. \(completedCount) file\(completedCount == 1 ? "" : "s") had already been copied.")
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
        phase = .failed("\(source.displayName) is locking its card. Set the camera's USB mode to MTP/PTP and switch it on again.")
    }
}
