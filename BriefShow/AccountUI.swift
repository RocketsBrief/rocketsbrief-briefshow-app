import SwiftUI

struct ProfileBadge: View {
    let session: RocketsBriefSession

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

                    settingsRow(icon: "globe", title: "RocketsBrief") {
                        if let url = URL(string: RocketsBriefConfig.webBaseURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        settingsRow(icon: "photo.circle", title: "Change profile icon") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isIconPickerExpanded.toggle()
                            }
                        }

                        if isIconPickerExpanded {
                            iconGrid(currentKey: session.avatarKey)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        settingsRow(icon: "key", title: isSendingPasswordReset ? "Sending…" : "Change password") {
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

                        Text("Credits and free prompts are shared with your RocketsBrief account. If you have credits or a free prompt available, head to rocketsbrief.com to build websites and web apps with the AI Builder.")
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

                    settingsRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out") {
                        accountManager.signOut()
                        onClose()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isDeleteConfirmationExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "trash")
                                Text("Delete Account")
                                Spacer()
                            }
                            .font(.custom("Figtree", size: 12.5).weight(.semibold))
                            .foregroundColor(Color(red: 0.620, green: 0.180, blue: 0.160))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .background(Color(red: 0.620, green: 0.180, blue: 0.160).opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(red: 0.620, green: 0.180, blue: 0.160).opacity(0.35), lineWidth: 1.2)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))

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

    private func settingsRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.custom("Figtree", size: 12.5).weight(.medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(AppColors.muted)
            }
            .foregroundColor(AppColors.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(AppColors.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppColors.border, lineWidth: 1.2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

struct UpdateAvailableModal: View {
    let latestVersion: String
    let downloadURL: String?
    let releaseNotes: String?
    let onDismiss: () -> Void

    @State private var showInstallGuide = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(AppColors.hoverInk)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("A new version of BriefShow is available")
                                .font(.custom("Figtree", size: 15).weight(.bold))
                                .foregroundColor(AppColors.ink)

                            Text("Version \(latestVersion) is ready to download.")
                                .font(.custom("Figtree", size: 12).weight(.regular))
                                .foregroundColor(AppColors.muted)
                        }
                    }

                    Spacer()

                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(AppColors.muted)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }

                if let releaseNotes, !releaseNotes.isEmpty {
                    Text(releaseNotes)
                        .font(.custom("Figtree", size: 12).weight(.regular))
                        .foregroundColor(AppColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    if let downloadURL, let url = URL(string: downloadURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text("Download Update")
                            .font(.custom("Figtree", size: 13).weight(.semibold))
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(PrimaryBrutalButtonStyle())

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
                    VStack(alignment: .leading, spacing: 10) {
                        installStep(1, "Click \"Download Update\" above. It opens the download page in your browser.")
                        installStep(2, "Open the downloaded file and drag the new BriefShow into your Applications folder, replacing the old version.")
                        installStep(3, "BriefShow is still in active development, so it isn't distributed through the Mac App Store yet. The first time you open the new version, macOS may show a warning that it can't verify the developer. Right-click (or Control-click) the BriefShow icon and choose \"Open\", then click \"Open\" again in the dialog that appears. You only need to do this once per update.")
                        installStep(4, "That's it. BriefShow will open normally from then on.")
                    }
                    .padding(14)
                    .background(AppColors.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(AppColors.border, lineWidth: 1.2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    Text("Why this extra step? BriefShow is still being finished and we haven't decided yet whether it will launch on the Mac App Store or stay a direct download. Once it's complete, it will be fully verified by Apple. Thanks for being an early user.")
                        .font(.custom("Figtree", size: 10.5).weight(.regular))
                        .italic()
                        .foregroundColor(AppColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    onDismiss()
                } label: {
                    HStack {
                        Spacer()
                        Text("Remind me later")
                            .font(.custom("Figtree", size: 12).weight(.medium))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(AppColors.muted)
            }
            .padding(24)
            .frame(width: 440)
            .background(AppColors.background)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(AppColors.border, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: Color.black.opacity(0.3), radius: 30, y: 12)
        }
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
    @ObservedObject var accountManager = AccountManager.shared
    let lockMessage: String?

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

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Continue using BriefShow")
                        .font(.custom("Figtree", size: 18).weight(.bold))
                        .foregroundColor(AppColors.ink)

                    Text(lockMessage ?? "Sign up for a free RocketsBrief account to keep using BriefShow.")
                        .font(.custom("Figtree", size: 12.5).weight(.regular))
                        .foregroundColor(AppColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
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
