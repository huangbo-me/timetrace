import CoreLocation
import SwiftUI
import UIKit

enum AppTheme: String, CaseIterable, Identifiable {
    case paper, sage, sky, lavender, rose
    var id: String { rawValue }
    var alternateIconName: String? {
        switch self {
        case .paper: nil
        case .sage: "AppIconSage"
        case .sky: "AppIconSky"
        case .lavender: "AppIconLavender"
        case .rose: "AppIconRose"
        }
    }
    var title: String {
        switch self { case .paper: "暖砂"; case .sage: "森林"; case .sky: "晴空"; case .lavender: "暮紫"; case .rose: "蔷薇" }
    }
    // canvas, card, ink, secondary ink, accent, border, gradient end
    var lightColors: [UInt32] {
        switch self {
        case .paper: [0xFAF5ED, 0xFFFCF7, 0x352B25, 0x665348, 0x875137, 0xDDCBB7, 0x493A2B]
        case .sage: [0xF0F5EE, 0xFAFDF8, 0x25372B, 0x4C6251, 0x356448, 0xC8DAC8, 0x253F30]
        case .sky: [0xEEF5FB, 0xFAFCFF, 0x263749, 0x4F6378, 0x365F87, 0xC9D8E8, 0x263D5B]
        case .lavender: [0xF5F0FA, 0xFDFAFF, 0x372D46, 0x625471, 0x70518B, 0xDACCE8, 0x42314F]
        case .rose: [0xFCF0F2, 0xFFFAFB, 0x442D34, 0x74535D, 0x89475D, 0xE8CBD3, 0x522D3A]
        }
    }
    var darkColors: [UInt32] {
        switch self {
        case .paper: [0x181410, 0x272019, 0xF8EEE2, 0xCEBDA9, 0xEDB887, 0x594737, 0x493A2B]
        case .sage: [0x101913, 0x1C2A21, 0xEBF5EA, 0xB2CCB6, 0x9AD5AC, 0x3B5944, 0x253F30]
        case .sky: [0x111820, 0x1D2935, 0xEAF2FC, 0xB5C9DF, 0x9ECBF5, 0x3B526C, 0x263D5B]
        case .lavender: [0x19131F, 0x2A2034, 0xF4ECFC, 0xCDBBDD, 0xD4AFF3, 0x554264, 0x42314F]
        case .rose: [0x201318, 0x322129, 0xFCECF0, 0xDCBBC6, 0xF2ACC2, 0x63404D, 0x522D3A]
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

struct TimeTraceDesign {
    var theme: AppTheme = .paper
    private func color(_ index: Int) -> Color {
        let light = Self.uiColor(theme.lightColors[index])
        let dark = Self.uiColor(theme.darkColors[index])
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    static func uiColor(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    var onAccent: Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? Self.uiColor(0x181818) : .white })
    }
    var blue: Color { color(4) }
    var violet: Color { color(4) }
    var ink: Color { color(2) }
    var muted: Color { color(3) }
    var canvas: Color { color(0) }
    var card: Color { color(1) }
    var border: Color { color(5) }
    var shadow: Color { .black }
    // The hero uses white text in both appearances, so its colors remain dark.
    var heroGradient: LinearGradient {
        LinearGradient(colors: [Color(uiColor: Self.uiColor(theme.lightColors[4])),
                                Color(uiColor: Self.uiColor(theme.lightColors[6]))],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct TimeTraceDesignKey: EnvironmentKey {
    static let defaultValue = TimeTraceDesign()
}
extension EnvironmentValues {
    var timeTraceDesign: TimeTraceDesign {
        get { self[TimeTraceDesignKey.self] }
        set { self[TimeTraceDesignKey.self] = newValue }
    }
}

struct TimeTraceMark: View {
    @Environment(\.timeTraceDesign) private var design

    var size: CGFloat = 48

    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .frame(width: size, height: size)
        .shadow(color: design.violet.opacity(0.22), radius: 12, y: 6)
    }
}

struct TTCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(16)
            .timeTraceCardSurface()
    }
}

struct TTIcon: View {
    @Environment(\.timeTraceDesign) private var design

    let systemName: String
    var tint: Color? = nil
    var size: CGFloat = 38

    var body: some View {
        let tint = tint ?? design.blue
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct TTSectionTitle: View {
    @Environment(\.timeTraceDesign) private var design

    let title: String
    var action: String?
    var onAction: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.headline.weight(.bold)).foregroundStyle(design.ink)
            Spacer()
            if let action, let onAction {
                Button(action, action: onAction)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(design.blue)
            }
        }
    }
}

/// Reusable, non-blocking feedback used when an optional platform capability
/// is unavailable. It keeps feature content visible instead of replacing it
/// with an error screen.
struct TTLocationPermissionNotice: View {
    @Environment(\.openURL) private var openURL
    let status: CLAuthorizationStatus

    var body: some View {
        if status != .authorizedAlways {
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "location.slash.fill")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("定位权限不足").font(.subheadline.weight(.semibold))
                        Text(status == .restricted
                             ? "定位受到系统限制，请检查屏幕使用时间或设备管理设置。"
                             : "请在系统设置中将定位权限改为“始终”，以使用后台自动记录。")
                            .font(.caption)
                        Text("前往系统设置").font(.subheadline.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .accessibilityHint("打开时迹的系统设置页面")
        }
    }
}

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
    /// Content uses a quiet material; native Liquid Glass is reserved for controls.
    func timeTraceCardSurface(cornerRadius: CGFloat = 20) -> some View {
        modifier(TimeTraceCardSurface(cornerRadius: cornerRadius))
    }

    func timeTraceScreen() -> some View {
        modifier(TimeTraceScreenModifier())
    }

    /// Uses iOS's native large-title behavior: the title is large at the
    /// scroll edge and smoothly contracts into the navigation bar on scroll.
    func timeTraceTabTitle(_ title: String) -> some View {
        self
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.large)
    }
}

private struct TimeTraceScreenModifier: ViewModifier {
    @Environment(\.timeTraceDesign) private var design
    func body(content: Content) -> some View {
        content.foregroundStyle(design.ink)
            .background { TimeTraceBackdrop() }
    }
}

private struct TimeTraceCardSurface: ViewModifier {
    @Environment(\.timeTraceDesign) private var design
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency || contrast == .increased {
                    shape.fill(design.card)
                } else {
                    shape.fill(.regularMaterial)
                    shape.fill(design.card.opacity(colorScheme == .dark ? 0.32 : 0.46))
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [design.card.opacity(0.85), design.border.opacity(contrast == .increased ? 1 : 0.4)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .shadow(color: design.shadow.opacity(colorScheme == .dark ? 0.12 : 0.045), radius: 14, y: 6)
    }
}

/// Static, theme-aware light gives translucent surfaces depth without motion.
private struct TimeTraceBackdrop: View {
    @Environment(\.timeTraceDesign) private var design
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        design.canvas
            .overlay {
                if !reduceTransparency {
                    GeometryReader { geometry in
                        RadialGradient(colors: [design.blue.opacity(0.14), .clear],
                                       center: .topTrailing, startRadius: 0,
                                       endRadius: max(geometry.size.width, 1))
                        RadialGradient(colors: [design.card.opacity(0.7), .clear],
                                       center: .bottomLeading, startRadius: 0,
                                       endRadius: max(geometry.size.height * 0.65, 1))
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
