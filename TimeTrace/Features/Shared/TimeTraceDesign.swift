import SwiftUI
import UIKit

enum TimeTraceDesign {
    /// Historical name retained for existing call sites; visually this is the app's muted bronze tint.
    static let blue = adaptive(light: .init(red: 0.58, green: 0.43, blue: 0.27, alpha: 1),
                               dark: .init(red: 0.76, green: 0.59, blue: 0.39, alpha: 1))
    static let violet = adaptive(light: .init(red: 0.08, green: 0.17, blue: 0.14, alpha: 1),
                                 dark: .init(red: 0.19, green: 0.33, blue: 0.27, alpha: 1))
    static let ink = adaptive(light: .init(red: 0.07, green: 0.10, blue: 0.085, alpha: 1),
                              dark: .init(red: 0.94, green: 0.92, blue: 0.86, alpha: 1))
    static let muted = adaptive(light: .init(red: 0.39, green: 0.40, blue: 0.36, alpha: 1),
                                dark: .init(red: 0.67, green: 0.68, blue: 0.62, alpha: 1))
    static let canvas = adaptive(light: .init(red: 0.965, green: 0.955, blue: 0.93, alpha: 1),
                                 dark: .init(red: 0.045, green: 0.06, blue: 0.052, alpha: 1))
    static let card = adaptive(light: .white,
                               dark: .init(red: 0.095, green: 0.12, blue: 0.105, alpha: 1))
    static let border = adaptive(light: .init(red: 0.87, green: 0.84, blue: 0.78, alpha: 1),
                                 dark: .init(red: 0.20, green: 0.25, blue: 0.215, alpha: 1))
    static let shadow = adaptive(light: .init(red: 0.13, green: 0.16, blue: 0.12, alpha: 1),
                                 dark: .black)
    static let heroGradient = LinearGradient(
        colors: [blue, violet], startPoint: .topLeading, endPoint: .bottomTrailing
    )

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

struct TimeTraceMark: View {
    var size: CGFloat = 48

    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .frame(width: size, height: size)
        .shadow(color: TimeTraceDesign.violet.opacity(0.22), radius: 12, y: 6)
    }
}

struct TTCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(16)
            .background(TimeTraceDesign.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(TimeTraceDesign.border, lineWidth: 1)
            }
            .shadow(color: TimeTraceDesign.shadow.opacity(0.15), radius: 12, y: 5)
    }
}

struct TTIcon: View {
    let systemName: String
    var tint: Color = TimeTraceDesign.blue
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct TTSectionTitle: View {
    let title: String
    var action: String?
    var onAction: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.headline.weight(.bold)).foregroundStyle(TimeTraceDesign.ink)
            Spacer()
            if let action, let onAction {
                Button(action, action: onAction)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(TimeTraceDesign.blue)
            }
        }
    }
}

/// Reusable, non-blocking feedback used when an optional platform capability
/// is unavailable. It keeps feature content visible instead of replacing it
/// with an error screen.
struct TTCapabilityNotice: View {
    let message: String
    var systemImage: String = "exclamationmark.triangle.fill"

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    func timeTraceScreen() -> some View {
        self
            .foregroundStyle(TimeTraceDesign.ink)
            .background(TimeTraceDesign.canvas.ignoresSafeArea())
    }

    /// Uses iOS's native large-title behavior: the title is large at the
    /// scroll edge and smoothly contracts into the navigation bar on scroll.
    func timeTraceTabTitle(_ title: String) -> some View {
        self
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.large)
    }
}
