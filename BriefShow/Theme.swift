import SwiftUI
import Combine

enum AppTheme: String {
    case buttery
    case white
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
    private static var isWhite: Bool {
        ThemeManager.shared.current == .white
    }

    static var background: Color {
        isWhite
            ? Color(red: 1.000, green: 1.000, blue: 1.000)
            : Color(red: 0.957, green: 0.937, blue: 0.910)
    }

    static var panel: Color {
        isWhite
            ? Color(red: 0.964, green: 0.964, blue: 0.968)
            : Color(red: 0.930, green: 0.900, blue: 0.850)
    }

    static var panelAlt: Color {
        isWhite
            ? Color(red: 0.945, green: 0.945, blue: 0.950)
            : Color(red: 0.900, green: 0.870, blue: 0.810)
    }

    static var border: Color {
        isWhite
            ? Color(red: 0.850, green: 0.850, blue: 0.862)
            : Color(red: 0.820, green: 0.780, blue: 0.710)
    }

    static var ink: Color {
        isWhite
            ? Color(red: 0.145, green: 0.150, blue: 0.170)
            : Color(red: 0.315, green: 0.340, blue: 0.390)
    }

    static var inkSecondary: Color {
        isWhite
            ? Color(red: 0.430, green: 0.435, blue: 0.460)
            : Color(red: 0.500, green: 0.525, blue: 0.575)
    }

    static var muted: Color {
        isWhite
            ? Color(red: 0.470, green: 0.470, blue: 0.485)
            : Color(red: 0.390, green: 0.390, blue: 0.390)
    }

    static var hoverInk: Color {
        Color(red: 0.315, green: 0.340, blue: 0.390)
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
        theme == .white
            ? Color.white
            : Color(red: 0.957, green: 0.937, blue: 0.910)
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
        .accessibilityLabel(theme == .white ? "White theme" : "Buttery theme")
    }
}
