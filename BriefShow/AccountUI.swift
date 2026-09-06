import SwiftUI

struct ProfileSettingsRow: View {
    // Same reason as ProfileBadge: AppColors alone does not subscribe to
    // anything, so without this the view keeps the theme it was first drawn in.
    @ObservedObject private var themeManager = ThemeManager.shared
    let icon: String
    let title: String
    var tint: Color? = nil
    var showsChevron: Bool = true
    let action: () -> Void

    @State private var isHovered = false

    private var contentColor: Color {
        if let tint {
            return tint
        }
        return isHovered ? AppColors.hoverInk : AppColors.ink
    }

    private var rowBackground: Color {
        if let tint {
            return tint.opacity(isHovered ? 0.14 : 0.08)
        }
        return isHovered ? AppColors.background : AppColors.panel
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: isHovered ? .semibold : .medium))
                Text(title)
                    .font(.custom("Figtree", size: 12.5).weight(isHovered ? .semibold : .medium))
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(AppColors.muted)
                }
            }
            .foregroundColor(contentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.012 : 1)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovered ? contentColor : (tint?.opacity(0.35) ?? AppColors.border), lineWidth: isHovered ? 1.6 : 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.linear(duration: 0.10), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct ProfileBadge: View {
    let session: RocketsBriefSession
    // ⚠️ Without this subscription the view keeps whatever theme was current
    // when it was FIRST drawn. AppColors are static computed properties that
    // read ThemeManager.shared — reading one does not subscribe to anything,
    // so SwiftUI has no reason to redraw a view whose own inputs have not
    // changed, and this one's only input is the session. That is exactly what
    // was reported: the profile pill stayed cream on the dark theme while the
    // whole screen around it went dark. Every other themed view in the app
    // already carries this line; this file was the one that did not.
    @ObservedObject private var themeManager = ThemeManager.shared

    private var avatarURL: URL? {
        URL(string: "\(RocketsBriefConfig.profileIconBaseURL)/\(session.avatarKey).png")
    }

    var body: some View {
        HStack(spacing: 8) {
            AsyncImage(url: avatarURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(3)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.muted)
                }
            }
            .frame(width: 28, height: 28)
            .background(AppColors.panel)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(AppColors.border, lineWidth: 1.2)
            )

            Text(session.name)
                .font(.custom("Figtree", size: 12).weight(.medium))
                .foregroundColor(AppColors.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppColors.panel)
        .clipShape(RoundedRectangle(cornerRadius: 999))
        .overlay(
            RoundedRectangle(cornerRadius: 999)
                .stroke(AppColors.border, lineWidth: 1.2)
        )
    }
}

struct ProfileSettingsModal: View {
    @ObservedObject var accountManager = AccountManager.shared
    // Same reason as ProfileBadge: AppColors alone does not subscribe to
    // anything, so without this the view keeps the theme it was first drawn in.
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject var seatManager = SeatManager.shared
    let onClose: () -> Void

    @State private var isIconPickerExpanded = false
    @State private var isSendingPasswordReset = false
    @State private var passwordResetMessage: String?
    @State private var isDeleteConfirmationExpanded = false
    @State private var deleteConfirmationText = ""
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?

    private var avatarURL: URL? {
        guard let session = accountManager.session else { return nil }
        return URL(string: "\(RocketsBriefConfig.profileIconBaseURL)/\(session.avatarKey).png")
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            if let session = accountManager.session {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        AsyncImage(url: avatarURL) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit().padding(4)
                            } else {
                                Image(systemName: "person.fill")
                                    .foregroundColor(AppColors.muted)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .background(AppColors.panel)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(AppColors.border, lineWidth: 1.2))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name)
                                .font(.custom("Figtree", size: 15).weight(.bold))
                                .foregroundColor(AppColors.ink)
                            Text(session.email)
                                .font(.custom("Figtree", size: 11.5).weight(.regular))
                                .foregroundColor(AppColors.muted)
                        }

                        Spacer()

                        Button {
                            onClose()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(AppColors.muted)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 14))
                                .foregroundColor(AppColors.ink)

                            Text("Credits: \(accountManager.credits.map(String.init) ?? "—")")
                                .font(.custom("Figtree", size: 13).weight(.semibold))
                                .foregroundColor(AppColors.ink)

                            Spacer()
                        }

                        Text("Use your credits at rocketsbrief.com! Launch the AI Builder and create your next web app or mobile app in seconds.")
                            .font(.custom("Figtree", size: 10.5).weight(.regular))
                            .foregroundColor(AppColors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(AppColors.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(AppColors.border, lineWidth: 1.2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // Both numbers come from the server, so a client who
                    // has been given extra computers sees the real count
                    // here without an app update — and a client on the
                    // ordinary one-Mac plan sees WHY signing in elsewhere
                    // will sign this Mac out, before it happens to them.
                    if let limit = seatManager.deviceLimit {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.muted)

                            Text(limit == 1
                                 ? "Signed in on this computer. This account works on one computer at a time — signing in on another signs this one out."
                                 : "Signed in on this computer — \(seatManager.seatsUsed ?? 1) of \(limit) computers in use.")
                                .font(.custom("Figtree", size: 10.5).weight(.regular))
                                .foregroundColor(AppColors.muted)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)
                        }
                    }

                    ProfileSettingsRow(icon: "globe", title: "RocketsBrief") {
                        if let url = URL(string: RocketsBriefConfig.webBaseURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ProfileSettingsRow(icon: "photo.circle", title: "Change profile icon") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isIconPickerExpanded.toggle()
                            }
                        }

                        if isIconPickerExpanded {
                            iconGrid(currentKey: session.avatarKey)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ProfileSettingsRow(icon: "key", title: isSendingPasswordReset ? "Sending…" : "Change password") {
                            Task {
                                isSendingPasswordReset = true
                                let success = await accountManager.requestPasswordReset()
                                passwordResetMessage = success
                                    ? "We sent a password reset link to \(session.email). Open it in your browser to set a new password."
                                    : "Couldn't send the reset email. Try again."
                                isSendingPasswordReset = false
                            }
                        }
                        .disabled(isSendingPasswordReset)

                        if let passwordResetMessage {
                            Text(passwordResetMessage)
                                .font(.custom("Figtree", size: 11).weight(.regular))
                                .foregroundColor(AppColors.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    ProfileSettingsRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out") {
                        accountManager.signOut()
                        onClose()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ProfileSettingsRow(
                            icon: "trash",
                            title: "Delete Account",
                            tint: Color(red: 0.620, green: 0.180, blue: 0.160),
                            showsChevron: false
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isDeleteConfirmationExpanded.toggle()
                            }
                        }

                        if isDeleteConfirmationExpanded {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("This removes your account access, credits, projects and saved previews. This cannot be undone. Type DELETE to confirm.")
                                    .font(.custom("Figtree", size: 11).weight(.regular))
                                    .foregroundColor(AppColors.muted)
                                    .fixedSize(horizontal: false, vertical: true)

                                TextField("Type DELETE", text: $deleteConfirmationText)
                                    .textFieldStyle(.plain)
                                    .font(.custom("Figtree", size: 12).weight(.regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(AppColors.background)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(AppColors.border, lineWidth: 1.2)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10))

                                if let deleteErrorMessage {
                                    Text(deleteErrorMessage)
                                        .font(.custom("Figtree", size: 11).weight(.medium))
                                        .foregroundColor(Color(red: 0.620, green: 0.180, blue: 0.160))
                                }

                                Button {
                                    Task {
                                        isDeleting = true
                                        deleteErrorMessage = nil
                                        let result = await accountManager.deleteAccount()
                                        isDeleting = false
                                        if result.success {
                                            onClose()
                                        } else {
                                            deleteErrorMessage = result.message
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Spacer()
                                        Text(isDeleting ? "Deleting…" : "Permanently delete my account")
                                            .font(.custom("Figtree", size: 12).weight(.semibold))
                                        Spacer()
                                    }
                                    .padding(.vertical, 9)
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.white)
                                .background(Color(red: 0.620, green: 0.180, blue: 0.160))
                                .clipShape(RoundedRectangle(cornerRadius: 999))
                                .disabled(deleteConfirmationText != "DELETE" || isDeleting)
                                .opacity(deleteConfirmationText != "DELETE" ? 0.5 : 1)
                            }
                            .padding(12)
                            .background(Color(red: 0.620, green: 0.180, blue: 0.160).opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color(red: 0.620, green: 0.180, blue: 0.160).opacity(0.25), lineWidth: 1.2)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(24)
                .frame(width: 400)
                .background(AppColors.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(AppColors.border, lineWidth: 2)
                )
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .shadow(color: Color.black.opacity(0.3), radius: 30, y: 12)
            }
        }
        .task {
            await accountManager.fetchCredits()
        }
    }

    private func iconGrid(currentKey: String) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(RocketsBriefConfig.profileIconKeys, id: \.self) { key in
                Button {
                    Task {
                        await accountManager.changeProfileIcon(key)
                    }
                } label: {
                    AsyncImage(url: URL(string: "\(RocketsBriefConfig.profileIconBaseURL)/\(key).png")) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit().padding(5)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 44, height: 44)
                    .background(AppColors.background)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(key == currentKey ? AppColors.hoverInk : AppColors.border, lineWidth: key == currentKey ? 2 : 1.2)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(AppColors.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppColors.border, lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// Content heights for the two scrolling boxes in `UpdateRequiredOverlay`.
/// SwiftUI's `ScrollView` never reports its content's height, so each box
/// measures its own content and takes `min(content, cap)` — short notes get a
/// short box, long notes get a scroller instead of a card that runs off the
/// bottom of the screen.
private struct UpdateNotesHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct UpdateStepsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct UpdateRequiredOverlay: View {
    // Same reason as ProfileBadge: AppColors alone does not subscribe to
    // anything, so without this the view keeps the theme it was first drawn in.
    @ObservedObject private var themeManager = ThemeManager.shared
    let latestVersion: String
    let downloadURL: String?
    let releaseNotes: String?

    @State private var showInstallGuide = false
    /// Set the moment "Download Update" is pressed, so the button cannot be
    /// pressed twice (two quit timers) and so the client is told, on screen,
    /// that the app is about to close on purpose rather than crash.
    @State private var quittingForUpdate = false

    /// How long the app stays alive after the download is handed to the
    /// browser. The client asked for this by the number: press Update, and
    /// four seconds later C4S Suite is gone so the new one can be dragged over
    /// it in Applications.
    private static let quitDelay: TimeInterval = 4

    /// Measured heights of the two long parts of the card. A `ScrollView`
    /// does not report how tall its content is, so without measuring them the
    /// box would either always stand at full height (a gap under two lines of
    /// notes) or grow with the text — which is exactly the bug this replaced.
    @State private var notesContentHeight: CGFloat = 0
    @State private var stepsContentHeight: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            // ⚠️ The card is sized to the WINDOW, not to its content. Before
            // this it was a plain `VStack` in a fixed 440 pt column that grew
            // with the release notes: with long notes — or with the install
            // steps open — it ran off the bottom of the screen and took
            // „Download Update" with it. Now the two long parts scroll inside
            // their own boxes, with caps taken from the window height, so the
            // button cannot leave the screen no matter how long the notes are.
            GeometryReader { geo in
                let room = max(geo.size.height - 80, 300)
                let notesCap = min(max(room * 0.32, 120), 320)
                let stepsCap = min(max(room * 0.34, 150), 360)
                // Wider than the old 440 — the release notes come with their
                // own line breaks, so a narrow column wrapped every line
                // twice. Still never wider than the window, or the card would
                // run off the sides on a small one.
                let width = min(620, max(geo.size.width - 48, 320))

                card(width: width, notesCap: notesCap, stepsCap: stepsCap)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func card(width: CGFloat, notesCap: CGFloat, stepsCap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(AppColors.hoverInk)

                VStack(alignment: .leading, spacing: 3) {
                    Text("A new version of C4S Suite is required")
                        .font(.custom("Figtree", size: 15).weight(.bold))
                        .foregroundColor(AppColors.ink)

                    Text("Update to version \(latestVersion) to keep using C4S Suite.")
                        .font(.custom("Figtree", size: 12).weight(.regular))
                        .foregroundColor(AppColors.muted)
                }
            }

            if let releaseNotes, !releaseNotes.isEmpty {
                ScrollView(.vertical) {
                    Text(releaseNotes)
                        .font(.custom("Figtree", size: 12).weight(.regular))
                        .foregroundColor(AppColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Room for the scroller, so it never sits on the text.
                        .padding(.trailing, 12)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: UpdateNotesHeightKey.self,
                                    value: proxy.size.height
                                )
                            }
                        )
                }
                .scrollIndicators(.visible)
                .onPreferenceChange(UpdateNotesHeightKey.self) { height in
                    notesContentHeight = height
                }
                .frame(height: min(max(notesContentHeight, 1), notesCap))
                .padding(12)
                .background(AppColors.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppColors.border, lineWidth: 1.2)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            Button {
                // Hand the download to the browser, then QUIT — the client
                // asked for it in as many words, and the reason is the next
                // step of the install: the new C4S Suite cannot be dragged
                // over the old one in Applications while the old one is
                // running. Leaving it open only to tell the client to close
                // it (which is what install step 3 used to say) was making
                // them do the app's job.
                //
                // ⚠️ The quit is on a CLOCK, not on the hand-off's
                // completion. Earlier it waited for `open` to call back,
                // which meant that on a slow or silent callback the app
                // could sit there open — exactly what the client reported.
                // Four seconds is his number, and it is comfortably more
                // than a browser needs to be handed a URL: the hand-off is
                // the browser's job from the first instant, and nothing of
                // ours is still transferring when we go.
                guard let downloadURL, let url = URL(string: downloadURL) else { return }
                guard !quittingForUpdate else { return }
                quittingForUpdate = true

                // Kept so the ONE case that must not quit can cancel it:
                // if the browser never took the URL, quitting would leave
                // the client with neither a download nor an app. That
                // callback lands in milliseconds when it lands at all, so
                // it is always well inside the four seconds.
                let quit = DispatchWorkItem { NSApplication.shared.terminate(nil) }
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.quitDelay, execute: quit
                )

                NSWorkspace.shared.open(
                    url, configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    guard error != nil else { return }
                    DispatchQueue.main.async {
                        quit.cancel()
                        quittingForUpdate = false
                    }
                }
            } label: {
                HStack {
                    Spacer()
                    Text(quittingForUpdate ? "Opening your browser…" : "Download Update")
                        .font(.custom("Figtree", size: 13).weight(.semibold))
                    Spacer()
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(PrimaryBrutalButtonStyle())
            .disabled(quittingForUpdate)

            // Without this the quit looks like a crash: the browser opens
            // behind the app and a few seconds later the app is simply
            // gone. Said out loud, it reads as the install doing its job.
            if quittingForUpdate {
                Text("C4S Suite will close in a few seconds so you can replace it in your Applications folder. Your download continues in the browser.")
                    .font(.custom("Figtree", size: 11.5).weight(.regular))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showInstallGuide.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(showInstallGuide ? "Hide install steps" : "How do I install this update?")
                    Image(systemName: showInstallGuide ? "chevron.up" : "chevron.down")
                }
                .font(.custom("Figtree", size: 11.5).weight(.medium))
                .foregroundColor(AppColors.muted)
            }
            .buttonStyle(.plain)

            if showInstallGuide {
                // Six steps plus the closing note are taller than most
                // screens leave room for once the notes are in — so this
                // scrolls too, under the same cap logic.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        installStep(1, "Click \"Download Update\" above. It opens the C4S Suite release page on GitHub in your browser, and a few seconds later C4S Suite closes itself so you can replace it. The download keeps going in the browser.")
                        installStep(2, "On that page, under \"Assets\", click the file named \"BriefShow-macOS-Universal.zip\" to start the download.")
                        installStep(3, "Open the downloaded file, then drag the new C4S Suite into your Applications folder. Choose \"Replace\" when asked.")
                        installStep(4, "C4S Suite is still in active development, so it isn't distributed through the Mac App Store yet. When you first open it, macOS will say it \"was blocked to protect your Mac.\" Open System Settings → Privacy & Security, scroll down to the Security section, and click \"Open Anyway\" next to C4S Suite.")
                        installStep(5, "Open C4S Suite again. Click \"Open Anyway\" once more in the dialog, then enter your Mac's login password when asked. Choose \"Always Allow\" so you won't be asked again.")
                        installStep(6, "That's it. C4S Suite will open normally from then on.")

                        Text("Why this extra step? C4S Suite is still being finished and we haven't decided yet whether it will launch on the Mac App Store or stay a direct download. Once it's complete, it will be fully verified by Apple. Thanks for being an early user.")
                            .font(.custom("Figtree", size: 10.5).weight(.regular))
                            .italic()
                            .foregroundColor(AppColors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    .padding(.trailing, 12)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: UpdateStepsHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
                }
                .scrollIndicators(.visible)
                .onPreferenceChange(UpdateStepsHeightKey.self) { height in
                    stepsContentHeight = height
                }
                .frame(height: min(max(stepsContentHeight, 1), stepsCap))
                .padding(14)
                .background(AppColors.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppColors.border, lineWidth: 1.2)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(24)
        .frame(width: width)
        .background(AppColors.background)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(AppColors.border, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color.black.opacity(0.3), radius: 30, y: 12)
    }

    private func installStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.custom("Figtree", size: 11).weight(.bold))
                .foregroundColor(AppColors.background)
                .frame(width: 18, height: 18)
                .background(AppColors.hoverInk)
                .clipShape(Circle())

            Text(text)
                .font(.custom("Figtree", size: 11.5).weight(.regular))
                .foregroundColor(AppColors.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LockedAccessOverlay: View {
    // Same reason as ProfileBadge: AppColors alone does not subscribe to
    // anything, so without this the view keeps the theme it was first drawn in.
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject var accountManager = AccountManager.shared
    let lockMessage: String?

    /// nil = this is the LOCK WALL: the app is locked, nobody is signed
    /// in, and there is deliberately no way out of it. Non-nil = the
    /// client opened this themselves from the home screen, so it gets an
    /// X, a click-outside, and it closes itself the moment they are in.
    /// One view for both, because they are the same form and the same
    /// two-line validation — a second copy would drift.
    var onClose: (() -> Void)? = nil

    @State private var mode: Mode = .signIn
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var localError: String?

    enum Mode {
        case signIn
        case signUp
    }

    private var isDismissible: Bool {
        onClose != nil
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose?()
                }

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isDismissible ? "Sign in to RocketsBrief" : "Continue using C4S Suite")
                            .font(.custom("Figtree", size: 18).weight(.bold))
                            .foregroundColor(AppColors.ink)

                        Text(isDismissible
                             ? "Your RocketsBrief account works here and on rocketsbrief.com — same email, same password."
                             : (lockMessage ?? "Sign up for a free RocketsBrief account to keep using C4S Suite."))
                            .font(.custom("Figtree", size: 12.5).weight(.regular))
                            .foregroundColor(AppColors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if isDismissible {
                        Spacer(minLength: 0)

                        Button {
                            onClose?()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(AppColors.muted)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Only shown when the server took this Mac's seat — i.e.
                // the client is looking at a sign-in screen that appeared
                // on its own, mid-work. Without this it reads as the app
                // having simply forgotten them, which is the single most
                // likely thing to be reported as a bug.
                if let seatMessage = accountManager.forcedSignOutMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.hoverInk)

                        Text(seatMessage)
                            .font(.custom("Figtree", size: 12).weight(.medium))
                            .foregroundColor(AppColors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(AppColors.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(AppColors.border, lineWidth: 1.2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                if let pendingEmail = accountManager.pendingConfirmationEmail {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: "envelope.badge.fill")
                                .font(.system(size: 18))
                                .foregroundColor(AppColors.hoverInk)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Confirm your email")
                                    .font(.custom("Figtree", size: 13.5).weight(.semibold))
                                    .foregroundColor(AppColors.ink)

                                Text("We sent a confirmation link to \(pendingEmail). Open it, then come back here and sign in.")
                                    .font(.custom("Figtree", size: 12).weight(.regular))
                                    .foregroundColor(AppColors.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(14)
                        .background(AppColors.panel)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(AppColors.border, lineWidth: 1.2)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                        Button {
                            accountManager.pendingConfirmationEmail = nil
                            mode = .signIn
                            password = ""
                        } label: {
                            HStack {
                                Spacer()
                                Text("Back to Sign In")
                                    .font(.custom("Figtree", size: 13).weight(.semibold))
                                Spacer()
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(PrimaryBrutalButtonStyle())
                    }
                } else {
                    HStack(spacing: 8) {
                        modeButton(title: "Sign In", target: .signIn)
                        modeButton(title: "Sign Up", target: .signUp)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        if mode == .signUp {
                            field("Name", text: $name)
                        }

                        field("Email", text: $email)
                        secureField("Password", text: $password)

                        if mode == .signUp {
                            secureField("Confirm password", text: $confirmPassword)
                        }
                    }

                    if let message = localError ?? accountManager.errorMessage {
                        Text(message)
                            .font(.custom("Figtree", size: 11.5).weight(.medium))
                            .foregroundColor(Color(red: 0.620, green: 0.180, blue: 0.160))
                    }

                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if accountManager.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(mode == .signIn ? "Sign In" : "Create account")
                                    .font(.custom("Figtree", size: 13).weight(.semibold))
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(PrimaryBrutalButtonStyle())
                    .disabled(accountManager.isBusy)
                }
            }
            .padding(24)
            .frame(width: 380)
            .background(AppColors.background)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(AppColors.border, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: Color.black.opacity(0.3), radius: 30, y: 12)
        }
        // The lock wall has no onClose, so it correctly does nothing here
        // and simply stops being shown once isSignedIn flips.
        .onChange(of: accountManager.isSignedIn) { signedIn in
            if signedIn {
                onClose?()
            }
        }
    }

    private func modeButton(title: String, target: Mode) -> some View {
        Button {
            mode = target
            localError = nil
        } label: {
            Text(title)
                .font(.custom("Figtree", size: 12.5).weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundColor(mode == target ? AppColors.hoverInk : AppColors.muted)
        .background(mode == target ? AppColors.panel : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 999)
                .stroke(mode == target ? AppColors.hoverInk : AppColors.border, lineWidth: mode == target ? 1.6 : 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 999))
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.custom("Figtree", size: 13).weight(.regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(AppColors.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppColors.border, lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func secureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.custom("Figtree", size: 13).weight(.regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(AppColors.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppColors.border, lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func submit() {
        localError = nil

        guard !email.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else {
            localError = "Enter your email and password."
            return
        }

        if mode == .signUp {
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                localError = "Enter your name."
                return
            }
            guard password == confirmPassword else {
                localError = "Passwords don't match."
                return
            }

            Task {
                await accountManager.signUp(name: name, email: email, password: password)
            }
        } else {
            Task {
                await accountManager.signIn(email: email, password: password)
            }
        }
    }
}
