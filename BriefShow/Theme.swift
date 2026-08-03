import SwiftUI
import Combine

enum AppTheme: String {
    case buttery
    case white
    case dark
}

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var current: AppTheme {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: "appTheme")
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "appTheme"),
           let saved = AppTheme(rawValue: raw) {
            current = saved
        } else {
            current = .buttery
        }
    }
}

enum AppColors {
    private static var current: AppTheme {
        ThemeManager.shared.current
    }

    // The soft-black background/panel tones here match ShowGrid's own
    // palette, so the "dark" theme reads as the same soft black
    // everywhere in the app rather than a separately-tuned dark mode.
    static var background: Color {
        switch current {
        case .white:
            return Color(red: 1.000, green: 1.000, blue: 1.000)
        case .buttery:
            return Color(red: 0.957, green: 0.937, blue: 0.910)
        case .dark:
            return Color(red: 0.15, green: 0.15, blue: 0.16)
        }
    }

    static var panel: Color {
        switch current {
        case .white:
            return Color(red: 0.964, green: 0.964, blue: 0.968)
        case .buttery:
            return Color(red: 0.930, green: 0.900, blue: 0.850)
        case .dark:
            return Color(red: 0.21, green: 0.21, blue: 0.22)
        }
    }

    static var panelAlt: Color {
        switch current {
        case .white:
            return Color(red: 0.945, green: 0.945, blue: 0.950)
        case .buttery:
            return Color(red: 0.900, green: 0.870, blue: 0.810)
        case .dark:
            return Color(red: 0.26, green: 0.26, blue: 0.27)
        }
    }

    static var border: Color {
        switch current {
        case .white:
            return Color(red: 0.850, green: 0.850, blue: 0.862)
        case .buttery:
            return Color(red: 0.820, green: 0.780, blue: 0.710)
        case .dark:
            return Color(red: 0.36, green: 0.36, blue: 0.38)
        }
    }

    static var ink: Color {
        switch current {
        case .white:
            return Color(red: 0.145, green: 0.150, blue: 0.170)
        case .buttery:
            return Color(red: 0.315, green: 0.340, blue: 0.390)
        case .dark:
            return Color(red: 0.72, green: 0.72, blue: 0.74)
        }
    }

    static var inkSecondary: Color {
        switch current {
        case .white:
            return Color(red: 0.430, green: 0.435, blue: 0.460)
        case .buttery:
            return Color(red: 0.500, green: 0.525, blue: 0.575)
        case .dark:
            return Color(red: 0.72, green: 0.72, blue: 0.75)
        }
    }

    static var muted: Color {
        switch current {
        case .white:
            return Color(red: 0.470, green: 0.470, blue: 0.485)
        case .buttery:
            return Color(red: 0.390, green: 0.390, blue: 0.390)
        case .dark:
            return Color(red: 0.58, green: 0.58, blue: 0.61)
        }
    }

    // Just for the "Brief"/"Show" two-tone wordmarks — the bright half needs
    // to stay clearly brighter than the muted half it's paired with (and
    // than ink's now-dimmer general-text tone) to keep that two-tone
    // contrast readable, without dimming every other use of ink along with
    // the rest of the app's body text.
    static var wordmarkBright: Color {
        current == .dark
            ? Color(red: 1.000, green: 1.000, blue: 1.000)
            : ink
    }

    static var hoverInk: Color {
        current == .dark
            ? Color(red: 1.000, green: 1.000, blue: 1.000)
            : Color(red: 0.315, green: 0.340, blue: 0.390)
    }
}

struct ThemeToggleButton: View {
    let theme: AppTheme
    @Binding var selected: AppTheme
    @State private var isHovered = false

    private var isActive: Bool {
        selected == theme
    }

    private var swatchColor: Color {
        switch theme {
        case .white:
            return Color.white
        case .buttery:
            return Color(red: 0.957, green: 0.937, blue: 0.910)
        case .dark:
            return Color(red: 0.15, green: 0.15, blue: 0.16)
        }
    }

    private var accessibilityThemeLabel: String {
        switch theme {
        case .white:
            return "White theme"
        case .buttery:
            return "Buttery theme"
        case .dark:
            return "Dark theme"
        }
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                selected = theme
            }
        } label: {
            Circle()
                .fill(swatchColor)
                .frame(width: 26, height: 26)
                .overlay(
                    Circle()
                        .stroke(AppColors.ink.opacity(0.35), lineWidth: 1.5)
                )
                .overlay(
                    Circle()
                        .stroke(
                            isActive ? AppColors.hoverInk.opacity(0.85) : Color.clear,
                            lineWidth: 1.8
                        )
                        .padding(-3)
                )
                .scaleEffect(isHovered ? 1.12 : (isActive ? 1.05 : 1.0))
                .shadow(color: Color.black.opacity(isHovered ? 0.28 : 0.18), radius: isHovered ? 4 : 2, y: 1.5)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.linear(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(accessibilityThemeLabel)
    }
}
