//
//  BriefShowApp.swift
//  BriefShow
//
//  Created by Esti Wahyuni on 7/6/26.
//

import SwiftUI
import CoreText
import UniformTypeIdentifiers
import AppKit

@main
struct BriefShowApp: App {
    init() {
        Self.registerBundledFonts()
    }

    // "Figtree" and "Unbounded" are only available on Macs where they
    // happen to be installed system-wide (e.g. this dev machine's Font
    // Book) unless the app registers its own bundled copy — without this,
    // every other Mac silently falls back to the system font.
    private static func registerBundledFonts() {
        for resourceName in ["Figtree-VariableFont_wght", "Unbounded-VariableFont_wght"] {
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: "ttf") else {
                continue
            }

            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            WelcomeChooserView()
        }
        .defaultSize(width: 1400, height: 820)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

// The app's very first screen: two square choices, "BriefShow" and
// "ShowGrid". Adding photos to either one — by picking or by dragging
// them in — immediately opens that destination with those photos already
// loaded, and this Welcome window closes. Shown fresh every launch (no
// "don't show again" state is kept).
struct WelcomeChooserView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var briefShowPhotoURLs: [URL]?
    @State private var isBriefShowDropTargeted = false
    @State private var isShowGridDropTargeted = false
    @State private var isRocketsBriefHovered = false
    @State private var isSupportHovered = false
    @State private var isFundMissionHovered = false
    @State private var isDisclaimerHovered = false
    @State private var isDisclaimerNoticePresented = false

    var body: some View {
        if let briefShowPhotoURLs {
            ContentView(initialPhotoURLs: briefShowPhotoURLs)
        } else {
            chooserBody
        }
    }

    private var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    // Reads the real app version (MARKETING_VERSION) rather than a
    // hardcoded string, so this never drifts out of sync with the actual
    // build.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "5.0"
    }

    // card width (420) * 2 + the HStack spacing (40) between them — used to
    // give the top row the exact same width as the cards row below, so
    // both can be centered identically and their edges line up.
    private let cardsRowWidth: CGFloat = 420 * 2 + 40

    private var chooserBody: some View {
        ZStack(alignment: .top) {
            AppColors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Reserves the vertical space the top row (theme circles +
                // links) occupies, since that row is painted separately
                // below, on top of this VStack, rather than living inside
                // it.
                Spacer(minLength: 84)

                HStack(spacing: 40) {
                    ChooserCard(
                        titlePrimary: "Brief",
                        titleSecondary: "Show",
                        subtitle: "Create high-resolution photo slideshows with music.",
                        isTargeted: $isBriefShowDropTargeted,
                        onPickPhotos: {
                            if let urls = pickImagePhotos() {
                                briefShowPhotoURLs = urls
                            }
                        },
                        onDropURLs: { urls in
                            briefShowPhotoURLs = urls
                        }
                    )

                    ChooserCard(
                        titlePrimary: "Show",
                        titleSecondary: "Grid",
                        subtitle: "Review a whole photo batch on one page and mark your favorites.",
                        isTargeted: $isShowGridDropTargeted,
                        onPickPhotos: {
                            if let urls = pickImagePhotos() {
                                openShowGrid(with: urls)
                            }
                        },
                        onDropURLs: { urls in
                            openShowGrid(with: urls)
                        }
                    )
                }

                Spacer(minLength: 36)

                Text("© \(String(currentYear)) RocketsBrief. All rights reserved.")
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .tracking(0.6)
                    .foregroundColor(AppColors.muted.opacity(0.55))

                Text("v\(appVersion)")
                    .font(.custom("Figtree", size: 11).weight(.medium))
                    .tracking(0.6)
                    .foregroundColor(AppColors.muted.opacity(0.4))
                    .padding(.top, 4)

                Spacer(minLength: 30)
            }
            .padding(.horizontal, 50)

            // Painted after (so on top of) the cards above, even though
            // ZStack(alignment: .top) positions it at the very top —
            // otherwise this row's hover info cards (which extend
            // downward past the row itself) would render behind the
            // BriefShow/ShowGrid cards and be clipped/hidden.
            HStack {
                HStack(spacing: 8) {
                    ThemeToggleButton(theme: .white, selected: $themeManager.current)
                    ThemeToggleButton(theme: .buttery, selected: $themeManager.current)
                    ThemeToggleButton(theme: .dark, selected: $themeManager.current)
                }

                Spacer()

                footerLinksRow
            }
            .frame(width: cardsRowWidth)
            .padding(.top, 20)
        }
        .frame(minWidth: 1200, idealWidth: 1400, minHeight: 740, idealHeight: 820)
        .preferredColorScheme(themeManager.current == .dark ? .dark : .light)
        .sheet(isPresented: $isDisclaimerNoticePresented) {
            DisclaimerNoticeModal()
        }
    }

    // Same RocketsBrief/Support/Fund Mission/Disclaimer links (with their
    // hover info cards) as the main BriefShow header, reused here so
    // they're reachable before the client has even picked BriefShow or
    // ShowGrid.
    private var footerLinksRow: some View {
        HStack(spacing: 12) {
            Button {
                if let url = URL(string: "https://www.rocketsbrief.com") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image("RocketsBriefButtonLogo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)

                    Text("RocketsBrief")
                }
                .frame(height: 15)
            }
            .buttonStyle(HeaderLinkButtonStyle())
            .overlay(alignment: .topTrailing) {
                if isRocketsBriefHovered {
                    RocketsBriefHoverCard()
                        .offset(x: -6, y: 48)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
                        .zIndex(300)
                }
            }
            .onHover { hovering in
                withAnimation(.linear(duration: 0.12)) {
                    isRocketsBriefHovered = hovering
                }
            }

            Button {
                if let url = URL(string: "https://www.rocketsbrief.com/support") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)

                    Text("Support")
                }
                .frame(height: 15)
            }
            .buttonStyle(HeaderLinkButtonStyle())
            .overlay(alignment: .topTrailing) {
                if isSupportHovered {
                    SupportHoverCard()
                        .offset(x: -6, y: 48)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
                        .zIndex(300)
                }
            }
            .onHover { hovering in
                withAnimation(.linear(duration: 0.12)) {
                    isSupportHovered = hovering
                }
            }

            Button {
                if let url = URL(string: "https://www.paypal.com/ncp/payment/GUZARDB67QEDU#checkoutModal") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Fund Mission")
                    .frame(width: 86, height: 15)
                    .fixedSize(horizontal: false, vertical: false)
            }
            .buttonStyle(HeaderLinkButtonStyle())
            .overlay(alignment: .topTrailing) {
                if isFundMissionHovered {
                    FundMissionHoverCard()
                        .offset(x: -6, y: 48)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
                        .zIndex(300)
                }
            }
            .onHover { hovering in
                withAnimation(.linear(duration: 0.12)) {
                    isFundMissionHovered = hovering
                }
            }

            Button {
                isDisclaimerNoticePresented = true
            } label: {
                Text("Disclaimer")
                    .frame(width: 86, height: 15)
                    .fixedSize(horizontal: false, vertical: false)
            }
            .buttonStyle(HeaderLinkButtonStyle())
            .overlay(alignment: .topTrailing) {
                if isDisclaimerHovered {
                    DisclaimerHoverCard()
                        .offset(x: -6, y: 48)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
                        .zIndex(300)
                }
            }
            .onHover { hovering in
                withAnimation(.linear(duration: 0.12)) {
                    isDisclaimerHovered = hovering
                }
            }
        }
        .zIndex(300)
    }

    private func openShowGrid(with urls: [URL]) {
        // Capture the Welcome window BEFORE opening ShowGrid — opening it
        // activates the app and makes the new ShowGrid window key, so
        // reading NSApp.keyWindow afterward would grab (and immediately
        // close) the window we just opened instead of this one.
        let welcomeWindow = NSApp.keyWindow
        ShowGridWindowController.shared.open(initialPhotoURLs: urls)
        welcomeWindow?.close()
    }

    private func pickImagePhotos() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.urls
    }
}

private struct ChooserCard: View {
    let titlePrimary: String
    let titleSecondary: String
    let subtitle: String
    @Binding var isTargeted: Bool
    let onPickPhotos: () -> Void
    let onDropURLs: ([URL]) -> Void

    @State private var isTitleHovered = false
    @State private var isAddPhotosHovered = false

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 0) {
                Text(titlePrimary)
                    .foregroundColor(AppColors.wordmarkBright)

                Text(titleSecondary)
                    .foregroundColor(AppColors.inkSecondary)
            }
            .font(.custom("Unbounded", size: 36).weight(.black))
            .tracking(-2.6)
            .scaleEffect(isTitleHovered ? 1.08 : 1)
            .animation(.easeOut(duration: 0.16), value: isTitleHovered)
            .onHover { hovering in
                isTitleHovered = hovering
            }

            Text(subtitle)
                .font(.custom("Figtree", size: 15).weight(.medium))
                .foregroundColor(AppColors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)

            Spacer(minLength: 16)

            VStack(spacing: 14) {
                Image(systemName: "plus.rectangle.on.folder")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundColor(isTargeted ? AppColors.hoverInk : AppColors.ink.opacity(0.55))

                Text("Add Photos")
                    .font(.custom("Figtree", size: 16).weight(.semibold))
                    .foregroundColor(AppColors.ink)

                Text("or drag & drop")
                    .font(.custom("Figtree", size: 13).weight(.regular))
                    .foregroundColor(AppColors.muted)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(AppColors.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        isTargeted ? AppColors.hoverInk : AppColors.border,
                        style: StrokeStyle(lineWidth: isTargeted ? 3 : 2, dash: [9, 6])
                    )
            )
            .scaleEffect(isAddPhotosHovered ? 1.03 : 1)
            .animation(.easeOut(duration: 0.16), value: isAddPhotosHovered)
            .animation(.easeOut(duration: 0.12), value: isTargeted)
            .onHover { hovering in
                isAddPhotosHovered = hovering
            }

            Spacer(minLength: 16)
        }
        .padding(36)
        .frame(width: 420, height: 560)
        .background(
            RoundedRectangle(cornerRadius: 32)
                .fill(AppColors.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 32)
                .stroke(AppColors.border, lineWidth: 1.5)
        )
        // The whole card — title included, not just the inner dashed
        // zone — accepts a click or a drag-and-drop.
        .contentShape(RoundedRectangle(cornerRadius: 32))
        .onTapGesture(perform: onPickPhotos)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            loadDroppedFileURLs(from: providers) { urls in
                let photoURLs = urls.filter { url in
                    UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                }

                guard !photoURLs.isEmpty else {
                    return
                }

                onDropURLs(photoURLs)
            }
        }
    }
}
