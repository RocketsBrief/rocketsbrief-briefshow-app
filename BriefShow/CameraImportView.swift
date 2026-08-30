//
//  CameraImportView.swift
//  BriefShow
//
//  The import dialog itself: source on the left, the card's contents as a
//  grid of thumbnails in the middle, destination and options on the right.
//  Same three-panel shape as Lightroom's Import window, in ShowGrid's own
//  palette rather than Adobe's.
//

import SwiftUI
import AppKit

struct CameraImportView: View {
    let camera: ConnectedCamera

    /// Where the photos land. Seeded with whatever folder ShowGrid currently
    /// has open, because that is almost always where they are wanted — the
    /// client picked it a moment ago — and a destination already filled in is
    /// one less step between plugging the camera in and seeing the photos.
    let initialDestination: URL?

    /// Called with the folder the photos actually landed in, so ShowGrid can
    /// open it. This is the point of the whole feature: the import finishes
    /// and the photos are simply THERE, in the grid, rather than somewhere on
    /// disk the client now has to go and find.
    let onImported: (URL) -> Void
    let onClose: () -> Void

    @StateObject private var session: CameraImportSession
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var destination: URL?
    @State private var intoDatedSubfolder = true
    @State private var deleteFromCameraAfterwards = false
    @State private var thumbnailSize: CGFloat = 132

    init(
        camera: ConnectedCamera,
        initialDestination: URL?,
        onImported: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.camera = camera
        self.initialDestination = initialDestination
        self.onImported = onImported
        self.onClose = onClose
        _session = StateObject(wrappedValue: CameraImportSession(camera: camera))
        _destination = State(initialValue: initialDestination ?? FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask).first)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                sourcePanel
                    .frame(width: 190)
                Divider()

                centrePanel
                    .frame(maxWidth: .infinity)

                Divider()
                destinationPanel
                    .frame(width: 240)
            }
            .frame(maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 1180, minHeight: 560, idealHeight: 740)
        .background(AppColors.background)
        // The session holds the camera open for as long as this view is on
        // screen. Closing it here rather than only on the Done button is what
        // stops a camera being left locked to BriefShow when the window is
        // dismissed some other way.
        .onDisappear { session.close() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera")
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(AppColors.inkSecondary)

            Text("IMPORT FROM \(camera.name.uppercased())")
                .font(.custom("Figtree", size: 12).weight(.bold))
                .tracking(1.1)
                .foregroundColor(AppColors.ink)

            Spacer()

            Button("Done") { onClose() }
                .buttonStyle(BrutalButtonStyle())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Source

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelTitle("SOURCE")

            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 11))
                Text(camera.name)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .lineLimit(1)
            }
            .foregroundColor(AppColors.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppColors.panelAlt))
            .padding(.horizontal, 12)

            Text(statusLine)
                .font(.custom("Figtree", size: 11))
                .foregroundColor(AppColors.muted)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppColors.background)
    }

    private var statusLine: String {
        switch session.phase {
        case .connecting: return "Waking the camera up…"
        case .listing: return "Reading the card… \(session.items.count) so far"
        case .ready, .importing, .finished, .failed:
            let count = session.items.count
            return "\(count) file\(count == 1 ? "" : "s") on the card"
        }
    }

    // MARK: Centre — the grid

    private var centrePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(allChecked ? "Uncheck All" : "Check All") {
                    session.setAllChecked(!allChecked)
                }
                .buttonStyle(BrutalButtonStyle())
                .disabled(session.items.isEmpty)

                Spacer()

                Image(systemName: "photo")
                    .font(.system(size: 9))
                    .foregroundColor(AppColors.muted)
                Slider(value: $thumbnailSize, in: 92...260)
                    .frame(width: 110)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if session.items.isEmpty {
                emptyState
            } else {
                grid
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if case .failed(let message) = session.phase {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundColor(AppColors.muted)
                Text(message)
                    .font(.custom("Figtree", size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundColor(AppColors.inkSecondary)
                    .frame(maxWidth: 380)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Reading the card…")
                    .font(.custom("Figtree", size: 12))
                    .foregroundColor(AppColors.muted)
                // Said out loud because it is the single most common reason a
                // camera shows up but its card does not: the body is asleep,
                // or it is in a USB mode that keeps the card to itself.
                Text("If nothing appears, switch the camera on and set its USB mode to MTP/PTP.")
                    .font(.custom("Figtree", size: 11))
                    .multilineTextAlignment(.center)
                    .foregroundColor(AppColors.muted.opacity(0.8))
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 12)],
                spacing: 14
            ) {
                ForEach(session.items) { item in
                    CameraImportTile(
                        item: item,
                        side: thumbnailSize,
                        onToggle: { session.setChecked(!item.isChecked, for: item.id) })
                }
            }
            .padding(16)
        }
    }

    private var allChecked: Bool {
        !session.items.isEmpty && session.items.allSatisfy(\.isChecked)
    }

    // MARK: Destination

    private var destinationPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelTitle("DESTINATION")

            VStack(alignment: .leading, spacing: 8) {
                Text(destination.map { shortPath(for: $0) } ?? "No folder chosen")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(destination == nil ? AppColors.muted : AppColors.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Choose…") { chooseDestination() }
                    .buttonStyle(BrutalButtonStyle())
            }
            .padding(.horizontal, 14)

            Divider().padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $intoDatedSubfolder) {
                    Text("Into a dated subfolder")
                        .font(.custom("Figtree", size: 11))
                }
                Text(datedSubfolderExplanation)
                    .font(.custom("Figtree", size: 10))
                    .foregroundColor(AppColors.muted)

                Toggle(isOn: $deleteFromCameraAfterwards) {
                    Text("Delete from camera after import")
                        .font(.custom("Figtree", size: 11))
                }
                .padding(.top, 6)
                // Off by default and spelled out, because it is the one choice
                // in this window that cannot be undone: the files are gone
                // from the card, and a card is not a Trash.
                Text("Only after each file has copied successfully. There is no undo.")
                    .font(.custom("Figtree", size: 10))
                    .foregroundColor(AppColors.muted)
            }
            .toggleStyle(.checkbox)
            .foregroundColor(AppColors.ink)
            .padding(.horizontal, 14)

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppColors.background)
    }

    private var datedSubfolderExplanation: String {
        // Dated by when the photos were TAKEN, so this says the day it will
        // actually use rather than "today" — on a card imported the morning
        // after a shoot those are different days, and the folder name is the
        // thing the client goes looking for later.
        guard let first = session.items.first?.created else {
            return "Grouped by the day the photos were taken."
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "Grouped by the day the photos were taken — \(formatter.string(from: first))."
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            switch session.phase {
            case .importing:
                ProgressView()
                    .controlSize(.small)
                Text("Copying \(session.currentFileName) — \(session.completedCount) of \(session.checkedItems.count)")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.inkSecondary)

            case .finished(let count, let folder):
                Image(systemName: "checkmark.circle")
                    .foregroundColor(AppColors.inkSecondary)
                Text("\(count) file\(count == 1 ? "" : "s") copied to \(folder.lastPathComponent)")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.inkSecondary)

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(AppColors.inkSecondary)
                Text(message)
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.inkSecondary)
                    .lineLimit(2)

            case .connecting, .listing, .ready:
                Text(selectionSummary)
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.inkSecondary)
            }

            Spacer()

            if case .finished(_, let folder) = session.phase {
                Button("Show These Photos") {
                    onImported(folder)
                    onClose()
                }
                .buttonStyle(PrimaryBrutalButtonStyle())
            } else {
                Button("Import") { startImport() }
                    .buttonStyle(PrimaryBrutalButtonStyle())
                    .disabled(!canImport)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var selectionSummary: String {
        let count = session.checkedItems.count
        guard count > 0 else { return "Nothing selected" }
        let size = ByteCountFormatter.string(
            fromByteCount: session.totalCheckedBytes, countStyle: .file)
        return "\(count) file\(count == 1 ? "" : "s") selected · \(size)"
    }

    private var canImport: Bool {
        destination != nil && !session.checkedItems.isEmpty && session.phase != .importing
    }

    // MARK: Actions

    private func startImport() {
        guard let destination else { return }
        session.startImport(
            to: destination,
            intoDatedSubfolder: intoDatedSubfolder,
            deleteFromCameraAfterwards: deleteFromCameraAfterwards)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        panel.prompt = "Import Here"
        panel.message = "Choose where to copy the photos from \(camera.name)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
    }

    private func shortPath(for url: URL) -> String {
        // Written the way it reads in Finder's own path bar rather than as a
        // full /Users/... path, which is both longer and less recognisable.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func panelTitle(_ text: String) -> some View {
        Text(text)
            .font(.custom("Figtree", size: 11).weight(.bold))
            .tracking(1.1)
            .foregroundColor(AppColors.muted.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 10)
    }
}

// MARK: - One thumbnail in the grid

private struct CameraImportTile: View {
    let item: CameraImportSession.Item
    let side: CGFloat
    let onToggle: () -> Void

    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.panelAlt)
                    .frame(width: side, height: side * 0.72)

                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side, height: side * 0.72)
                }

                // The checkbox sits ON the thumbnail rather than beside it,
                // the same way Lightroom's does — with a hundred tiles on
                // screen a separate column of boxes is a column of misses.
                Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(item.isChecked ? AppColors.ink : AppColors.muted)
                    .padding(5)
                    .background(
                        Circle()
                            .fill(AppColors.background.opacity(0.75))
                            .padding(2))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(item.isChecked ? AppColors.ink.opacity(0.55) : AppColors.border,
                            lineWidth: item.isChecked ? 1.5 : 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            Text(item.name)
                .font(.custom("Figtree", size: 9))
                .foregroundColor(AppColors.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: side)
        }
    }
}
