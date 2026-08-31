//
//  Shortcuts.swift
//  BriefShow
//
//  Every keyboard shortcut in the app, in one place, and editable.
//
//  Before this, each shortcut was a literal buried in one of the two local
//  NSEvent monitors — `key == "x"` in ShowGrid, `key == "z"` in LumenoLab — so
//  there was no list of them, no way for a client to change one, and no way to
//  find out what was already taken before adding another. This file is the
//  list. The monitors ask it rather than deciding for themselves.
//
//  The DEFAULTS here are exactly the keys the app already used. Nothing about
//  what a fresh install does has changed; what changed is that it can now be
//  changed.
//

import SwiftUI
import AppKit

// MARK: - A key press

/// One key plus its modifiers, as a thing that can be stored and compared.
///
/// The key is held as the character the key produces WITHOUT modifiers
/// (`charactersIgnoringModifiers`), which is what both monitors already matched
/// on and what keeps a shortcut working under a non-US keyboard layout. Keys
/// that produce no character — the arrows, Escape, Delete — are held by their
/// virtual key code instead, because those are physical positions rather than
/// letters.
struct KeyCombo: Codable, Equatable, Hashable {
    var character: String?
    var keyCode: UInt16?
    var command = false
    var shift = false
    var option = false
    var control = false

    static func key(_ character: String,
                    command: Bool = false, shift: Bool = false,
                    option: Bool = false, control: Bool = false) -> KeyCombo {
        KeyCombo(character: character.lowercased(), keyCode: nil,
                 command: command, shift: shift, option: option, control: control)
    }

    static func code(_ keyCode: UInt16,
                     command: Bool = false, shift: Bool = false,
                     option: Bool = false, control: Bool = false) -> KeyCombo {
        KeyCombo(character: nil, keyCode: keyCode,
                 command: command, shift: shift, option: option, control: control)
    }

    /// Only the four modifiers a shortcut can actually distinguish.
    ///
    /// Not `.deviceIndependentFlagsMask`, which also carries capsLock, numeric
    /// pad, help and function bits. Those ride along legitimately — Caps Lock
    /// physically on, or a keyboard that reports a numeric-pad bit — and since
    /// every comparison here is exact equality, one stray bit would silently
    /// stop a shortcut working with no feedback at all. That exact bug has
    /// already been fixed once in this app; it is not being reintroduced.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(Self.relevantModifiers)
        guard flags.contains(.command) == command,
              flags.contains(.shift) == shift,
              flags.contains(.option) == option,
              flags.contains(.control) == control else {
            return false
        }
        if let keyCode {
            return event.keyCode == keyCode
        }
        guard let character else {
            return false
        }
        return event.charactersIgnoringModifiers?.lowercased() == character
    }

    /// "⌘⇧Z" — the way a menu would write it.
    var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        text += Self.keyName(character: character, keyCode: keyCode)
        return text
    }

    private static func keyName(character: String?, keyCode: UInt16?) -> String {
        if let keyCode {
            switch keyCode {
            case 123: return "←"
            case 124: return "→"
            case 125: return "↓"
            case 126: return "↑"
            case 49: return "Space"
            case 53: return "Esc"
            case 51: return "Delete"
            case 117: return "Fwd Delete"
            case 36: return "Return"
            case 48: return "Tab"
            default: return "Key \(keyCode)"
            }
        }
        guard let character, !character.isEmpty else { return "—" }
        switch character {
        case " ": return "Space"
        case "=": return "="
        case "-": return "−"
        default: return character.uppercased()
        }
    }

    /// Reads a combo out of a key press, for the recorder in the editor.
    ///
    /// Returns nil for a press that is only modifiers, so holding ⌘ while
    /// deciding what to record does not record ⌘ by itself.
    static func from(_ event: NSEvent) -> KeyCombo? {
        let flags = event.modifierFlags.intersection(relevantModifiers)
        let character = event.charactersIgnoringModifiers?.lowercased()
        let namedCodes: Set<UInt16> = [123, 124, 125, 126, 49, 53, 51, 117, 36, 48]

        if namedCodes.contains(event.keyCode) {
            return KeyCombo(character: nil, keyCode: event.keyCode,
                            command: flags.contains(.command), shift: flags.contains(.shift),
                            option: flags.contains(.option), control: flags.contains(.control))
        }
        guard let character, character.count == 1,
              character.rangeOfCharacter(from: .alphanumerics.union(.punctuationCharacters)
                                            .union(.symbols)) != nil else {
            return nil
        }
        return KeyCombo(character: character, keyCode: nil,
                        command: flags.contains(.command), shift: flags.contains(.shift),
                        option: flags.contains(.option), control: flags.contains(.control))
    }
}

// MARK: - What can be bound

/// Everything in the app a key can be bound to.
///
/// Grouped by the window it belongs to, because the same key means different
/// things in ShowGrid and in LumenoLab and always has — the two monitors are
/// scoped by window title precisely so it can. A duplicate WITHIN a group is a
/// conflict; the same key in both groups is not.
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {

    // LumenoLab
    case nextPhoto, previousPhoto
    case undo, redo
    case copySelection, cutSelection, pasteLayer
    case selectAllPhotos
    case zoomIn, zoomOut, zoomToFit
    case decreaseToolSize, increaseToolSize

    // ShowGrid
    case gridSelectAll, gridCopy, gridCut, gridPaste
    case gridToggleLabel, gridClearLabels, gridPreview

    var id: String { rawValue }

    /// The two windows a shortcut can belong to.
    ///
    /// "BriefShow" is the main window — the folder tree and the photo grid.
    /// It is not a separate product: BriefShow is the suite, Showcase is the
    /// slideshow, LumenoLab is the editor.
    enum Group: String, CaseIterable, Identifiable {
        case lumenoLab = "LumenoLab"
        case showGrid = "BriefShow"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .gridSelectAll, .gridCopy, .gridCut, .gridPaste,
             .gridToggleLabel, .gridClearLabels, .gridPreview:
            return .showGrid
        default:
            return .lumenoLab
        }
    }

    var title: String {
        switch self {
        case .nextPhoto: return "Next Photo"
        case .previousPhoto: return "Previous Photo"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .copySelection: return "Copy Selection"
        case .cutSelection: return "Cut Selection"
        case .pasteLayer: return "Paste Layer"
        case .selectAllPhotos: return "Select All Photos"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .zoomToFit: return "Zoom to Fit"
        case .decreaseToolSize: return "Smaller Brush / Tool"
        case .increaseToolSize: return "Larger Brush / Tool"
        case .gridSelectAll: return "Select All Photos"
        case .gridCopy: return "Copy"
        case .gridCut: return "Cut"
        case .gridPaste: return "Paste"
        case .gridToggleLabel: return "Toggle Label"
        case .gridClearLabels: return "Clear All Labels & Stars"
        case .gridPreview: return "Preview Selected"
        }
    }

    /// What the app has always used. Changing one of these changes what a
    /// fresh install does, so they are the app's behaviour, not a suggestion.
    var defaultCombo: KeyCombo {
        switch self {
        case .nextPhoto: return .key("e")
        case .previousPhoto: return .key("q")
        case .undo: return .key("z", command: true)
        case .redo: return .key("z", command: true, shift: true)
        case .copySelection: return .key("c", command: true)
        case .cutSelection: return .key("x", command: true)
        case .pasteLayer: return .key("v", command: true)
        case .selectAllPhotos: return .key("a", command: true)
        case .zoomIn: return .key("=", command: true)
        case .zoomOut: return .key("-", command: true)
        case .zoomToFit: return .key("0", command: true)
        case .decreaseToolSize: return .key("[")
        case .increaseToolSize: return .key("]")
        case .gridSelectAll: return .key("a", command: true)
        case .gridCopy: return .key("c", command: true)
        case .gridCut: return .key("x", command: true)
        case .gridPaste: return .key("v", command: true)
        case .gridToggleLabel: return .key("x")
        case .gridClearLabels: return .key("v")
        case .gridPreview: return .code(49)
        }
    }

    /// Shortcuts the app keeps for itself, listed so the client can see them
    /// but not rebind them.
    ///
    /// Each one is a key whose meaning is fixed by the platform or by the tool
    /// it belongs to: Escape cancels, the arrows nudge the armed slider and
    /// step the grid, Space is the hand tool while a photo is zoomed, Option
    /// shows the clone-stamp source, and 1–5 set a star rating. Offering to
    /// rebind those would be offering something the rest of the app cannot
    /// honour.
    static let fixed: [(String, String, ShortcutAction.Group)] = [
        ("← / →", "Nudge the armed slider (Shift for a coarser step)", .lumenoLab),
        ("Esc", "Disarm the slider / close", .lumenoLab),
        ("Delete", "Delete the selected mask or layer", .lumenoLab),
        ("Space (hold)", "Hand tool, to pan a zoomed photo", .lumenoLab),
        ("⌥ (hold)", "Show the clone-stamp source ring", .lumenoLab),
        ("← ↑ → ↓", "Move through the grid", .showGrid),
        ("1 – 5", "Set a star rating", .showGrid),
        ("Esc", "Close the preview", .showGrid),
    ]
}

// MARK: - Where bindings live

/// The client's own bindings, and the named sets of them.
///
/// Anything not overridden falls through to the action's default, so the store
/// only ever holds what has actually been changed. That keeps a saved preset
/// small and, more usefully, means a default that is improved in a later
/// version reaches everyone who never touched that shortcut.
enum ShortcutStore {

    private static let bindingsKey = "com.rocketsbrief.briefshow.shortcutBindings"
    private static let presetsKey = "com.rocketsbrief.briefshow.shortcutPresets"

    struct Preset: Codable, Identifiable, Equatable {
        var id: UUID
        var name: String
        var bindings: [String: KeyCombo]
    }

    /// Bumped whenever a binding changes, so views can redraw.
    static let didChange = Notification.Name("com.rocketsbrief.briefshow.shortcutsChanged")

    private static let lock = NSLock()
    private static var cache: [String: KeyCombo]?

    private static var overrides: [String: KeyCombo] {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let cache { return cache }
            let data = UserDefaults.standard.data(forKey: bindingsKey)
            let decoded = data.flatMap { try? JSONDecoder().decode([String: KeyCombo].self, from: $0) } ?? [:]
            cache = decoded
            return decoded
        }
        set {
            lock.lock()
            cache = newValue
            lock.unlock()
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: bindingsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func combo(for action: ShortcutAction) -> KeyCombo {
        overrides[action.rawValue] ?? action.defaultCombo
    }

    static func isCustomised(_ action: ShortcutAction) -> Bool {
        overrides[action.rawValue] != nil
    }

    static func set(_ combo: KeyCombo, for action: ShortcutAction) {
        var all = overrides
        all[action.rawValue] = combo
        overrides = all
    }

    static func reset(_ action: ShortcutAction) {
        var all = overrides
        all.removeValue(forKey: action.rawValue)
        overrides = all
    }

    static func resetAll() {
        overrides = [:]
    }

    /// Which OTHER action in the same group already answers to this key.
    ///
    /// Only within a group: the two monitors are scoped by window, so ⌘C
    /// meaning one thing in ShowGrid and another in LumenoLab is how the app
    /// has always worked, not a clash.
    static func conflict(for candidate: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first {
            $0 != action && $0.group == action.group && combo(for: $0) == candidate
        }
    }

    /// Does this event fire this action?
    static func matches(_ event: NSEvent, _ action: ShortcutAction) -> Bool {
        combo(for: action).matches(event)
    }

    // MARK: Presets

    static func presets() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: presetsKey) else { return [] }
        return (try? JSONDecoder().decode([Preset].self, from: data)) ?? []
    }

    private static func save(_ presets: [Preset]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: presetsKey)
    }

    /// Saves the CURRENT full set — defaults included, not just the overrides.
    ///
    /// A preset is a complete answer to "what were my keys", so it has to
    /// survive a later version changing a default. Overrides alone would let a
    /// preset silently drift.
    static func savePreset(named name: String) {
        var bindings: [String: KeyCombo] = [:]
        for action in ShortcutAction.allCases {
            bindings[action.rawValue] = combo(for: action)
        }
        var all = presets()
        all.append(Preset(id: UUID(), name: name, bindings: bindings))
        save(all)
    }

    static func apply(_ preset: Preset) {
        overrides = preset.bindings
    }

    static func delete(_ preset: Preset) {
        save(presets().filter { $0.id != preset.id })
    }

    static func rename(_ preset: Preset, to name: String) {
        var all = presets()
        guard let index = all.firstIndex(where: { $0.id == preset.id }) else { return }
        all[index].name = name
        save(all)
    }
}

// MARK: - The editor

/// The Shortcuts sheet: every binding, changeable, plus named sets of them.
struct ShortcutsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Which row is listening for a key press. Only ever one — a recorder that
    /// is armed while another is armed would take the press meant for the other.
    @State private var recording: ShortcutAction?
    @State private var conflictMessage: String?
    @State private var presets: [ShortcutStore.Preset] = ShortcutStore.presets()
    @State private var isNamingPreset = false
    @State private var newPresetName = ""
    /// Bumped to force a redraw after a binding changes, since the store is a
    /// plain enum rather than an ObservableObject.
    @State private var revision = 0
    @State private var recorderMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(ShortcutAction.Group.allCases) { group in
                        section(for: group)
                    }
                    fixedSection
                    presetsSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 620, height: 640)
        .background(AppColors.background)
        .onDisappear { stopRecording() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keyboard Shortcuts")
                    .font(.custom("Figtree", size: 22).weight(.semibold))
                    .foregroundColor(AppColors.ink)
                Text("Click a shortcut, then press the keys you want.")
                    .font(.custom("Figtree", size: 12))
                    .foregroundColor(AppColors.muted)
            }

            Spacer()

            Button("Reset All") {
                ShortcutStore.resetAll()
                bumped()
            }
            .buttonStyle(ShowHeaderButtonStyle())

            Button {
                stopRecording()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(HeaderLinkButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private func section(for group: ShortcutAction.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.rawValue)
                .font(.custom("Figtree", size: 13).weight(.semibold))
                .foregroundColor(AppColors.ink)

            ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                row(action)
            }

            if let conflictMessage, recording == nil {
                Text(conflictMessage)
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(.red.opacity(0.85))
            }
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let isRecording = recording == action
        return HStack(spacing: 10) {
            Text(action.title)
                .font(.custom("Figtree", size: 12))
                .foregroundColor(AppColors.ink)

            Spacer()

            if ShortcutStore.isCustomised(action) {
                Button {
                    ShortcutStore.reset(action)
                    bumped()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10))
                        .foregroundColor(AppColors.muted)
                }
                .buttonStyle(.plain)
                .help("Back to the default")
            }

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording(action)
                }
            } label: {
                Text(isRecording ? "Press keys…" : ShortcutStore.combo(for: action).display)
                    .font(.custom("Figtree", size: 12).weight(.medium))
                    .foregroundColor(isRecording ? AppColors.background : AppColors.ink)
                    .frame(minWidth: 92)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isRecording ? AppColors.ink : AppColors.panelAlt)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(AppColors.border.opacity(0.7), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .id(revision)
    }

    private var fixedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fixed")
                .font(.custom("Figtree", size: 13).weight(.semibold))
                .foregroundColor(AppColors.ink)

            Text("These belong to the tool they are part of and cannot be changed.")
                .font(.custom("Figtree", size: 11))
                .foregroundColor(AppColors.muted)

            ForEach(ShortcutAction.fixed, id: \.0) { entry in
                HStack(spacing: 10) {
                    Text(entry.1)
                        .font(.custom("Figtree", size: 12))
                        .foregroundColor(AppColors.muted)
                    Spacer()
                    Text(entry.0)
                        .font(.custom("Figtree", size: 12).weight(.medium))
                        .foregroundColor(AppColors.muted)
                    Text(entry.2.rawValue)
                        .font(.custom("Figtree", size: 10))
                        .foregroundColor(AppColors.muted.opacity(0.7))
                        .frame(width: 74, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved Sets")
                .font(.custom("Figtree", size: 13).weight(.semibold))
                .foregroundColor(AppColors.ink)

            if presets.isEmpty && !isNamingPreset {
                Text("Save the shortcuts you have now as a set, so you can put them back later or move them between machines.")
                    .font(.custom("Figtree", size: 11))
                    .foregroundColor(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(presets) { preset in
                HStack(spacing: 8) {
                    Text(preset.name)
                        .font(.custom("Figtree", size: 12).weight(.medium))
                        .foregroundColor(AppColors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Use") {
                        ShortcutStore.apply(preset)
                        bumped()
                    }
                    .buttonStyle(ShowHeaderButtonStyle())

                    Button {
                        ShortcutStore.delete(preset)
                        presets = ShortcutStore.presets()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(AppColors.panelAlt.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if isNamingPreset {
                HStack(spacing: 6) {
                    TextField("Set name", text: $newPresetName)
                        .textFieldStyle(.roundedBorder)
                        .font(.custom("Figtree", size: 12))
                        .onSubmit { commitPreset() }

                    Button("Save") { commitPreset() }
                        .buttonStyle(ShowHeaderButtonStyle())
                        .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Cancel") {
                        isNamingPreset = false
                        newPresetName = ""
                    }
                    .buttonStyle(ShowHeaderButtonStyle())
                }
            } else {
                Button {
                    newPresetName = ""
                    isNamingPreset = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                        Text("Save Current as Set")
                    }
                }
                .buttonStyle(ShowHeaderButtonStyle())
            }
        }
    }

    private func commitPreset() {
        let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ShortcutStore.savePreset(named: trimmed)
        presets = ShortcutStore.presets()
        isNamingPreset = false
        newPresetName = ""
    }

    private func bumped() {
        revision &+= 1
        presets = ShortcutStore.presets()
    }

    // MARK: Recording

    /// A LOCAL monitor, and it swallows every key press while it is armed.
    ///
    /// That is the point: the whole app is listening for keys, so a recorder
    /// that let the press through would rebind Undo and also perform it.
    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        conflictMessage = nil
        recording = action
        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape gets out without binding anything, which is the only way
            // to leave a recorder that eats every other key.
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard let combo = KeyCombo.from(event) else {
                return nil
            }
            if let clash = ShortcutStore.conflict(for: combo, excluding: action) {
                conflictMessage = "\(combo.display) is already \(clash.title) in \(action.group.rawValue)."
                stopRecording()
                return nil
            }
            ShortcutStore.set(combo, for: action)
            stopRecording()
            bumped()
            return nil
        }
    }

    private func stopRecording() {
        if let recorderMonitor {
            NSEvent.removeMonitor(recorderMonitor)
        }
        recorderMonitor = nil
        recording = nil
    }
}
