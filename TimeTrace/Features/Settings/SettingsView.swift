import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Icon changes require an explicit opt-in. Launching the app or switching
/// light/dark appearance must not produce a system icon alert.
@MainActor
final class ThemeIconController: ObservableObject {
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    private let supportsIcons: () -> Bool
    private let currentIcon: () -> String?
    private let setIcon: (String?) async throws -> Void

    init(supportsIcons: @escaping () -> Bool = { UIApplication.shared.supportsAlternateIcons },
         currentIcon: @escaping () -> String? = { UIApplication.shared.alternateIconName },
         setIcon: @escaping (String?) async throws -> Void = { try await UIApplication.shared.setAlternateIconName($0) }) {
        self.supportsIcons = supportsIcons
        self.currentIcon = currentIcon
        self.setIcon = setIcon
    }

    @discardableResult
    func updateIcon(for theme: AppTheme, followsTheme: Bool) -> Task<Void, Never>? {
        guard !isUpdating else { return nil }
        errorMessage = nil
        guard followsTheme else { return nil }
        let name = theme.alternateIconName
        guard currentIcon() != name else { return nil }
        guard supportsIcons() else {
            errorMessage = "App 主题已更换，但当前设备不支持更换桌面图标。"
            return nil
        }
        isUpdating = true
        return Task {
            defer { isUpdating = false }
            do {
                try await setIcon(name)
            } catch {
                errorMessage = "App 主题已更换，桌面图标更换失败，请重试。"
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.timeTraceDesign) private var design
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @EnvironmentObject private var store: SettingsFeatureStore
    @Environment(\.openURL) private var openURL
    @AppStorage("profileNickname") private var profileNickname = ""
    @FocusState private var isNicknameFocused: Bool
    @State private var showingPlaces = false
    @AppStorage("appTheme") private var themeName = AppTheme.paper.rawValue
    @AppStorage("appAppearance") private var appearanceName = AppAppearance.system.rawValue
    @AppStorage("desktopIconFollowsTheme") private var desktopIconFollowsTheme = false
    @StateObject private var themeIcon = ThemeIconController()

    private var model: AppModel { store.application }
#if DEBUG
    @AppStorage("developerDemoToolsEnabled") private var developerDemoToolsEnabled = false
    @State private var showingDemoResult = false
    @State private var demoResultMessage = ""
    @State private var showingClearDemoConfirmation = false
#endif

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    TimeTraceMark(size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("时光落点").font(.title2.weight(.bold))
                        Text("TimeTrace · 记录每一段专注时光").font(.caption).foregroundStyle(design.muted)
                    }
                }

                TTSectionTitle(title: "个人资料")
                TTCard {
                    HStack(spacing: 12) {
                        TTIcon(systemName: "person.fill", tint: design.blue, size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("昵称").font(.subheadline.weight(.medium))
                            Text("最多 10 个汉字或 20 个英文字符").font(.caption).foregroundStyle(design.muted)
                        }
                        Spacer()
                        TextField("未设置", text: $profileNickname)
                            .focused($isNicknameFocused)
                            .submitLabel(.done)
                            .onSubmit { isNicknameFocused = false }
                            .multilineTextAlignment(.trailing)
                            .frame(width: 128)
                            .onChange(of: profileNickname) { _, newValue in
                                let trimmed = nicknameWithinDisplayLimit(newValue)
                                if trimmed != newValue { profileNickname = trimmed }
                            }
                    }
                }

                TTSectionTitle(title: "外观")
                TTCard {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("App 主题").font(.subheadline.weight(.medium))
                            // Direct buttons avoid the system menu's lingering source highlight
                            // while an appearance change redraws the presenting view.
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 100 : 52))], spacing: 12) {
                                ForEach(AppTheme.allCases) { theme in
                                    let palette = TimeTraceDesign(theme: theme)
                                    let selected = themeName == theme.rawValue
                                    Button {
                                        themeName = theme.rawValue
                                        themeIcon.updateIcon(for: theme, followsTheme: desktopIconFollowsTheme)
                                    } label: {
                                        VStack(spacing: 8) {
                                            Circle().fill(palette.blue)
                                                .frame(width: 32, height: 32)
                                                .overlay {
                                                    if selected {
                                                        Image(systemName: "checkmark")
                                                            .font(.caption.weight(.bold))
                                                            .foregroundStyle(palette.onAccent)
                                                    }
                                                }
                                                .padding(4)
                                                .overlay {
                                                    Circle().strokeBorder(selected ? design.blue : .clear, lineWidth: 2)
                                                }
                                            Text(theme.title)
                                                .font(.caption.weight(selected ? .semibold : .regular))
                                                .foregroundStyle(design.ink)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 64)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(themeIcon.isUpdating)
                                    .accessibilityLabel("App 主题：" + theme.title)
                                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                                }
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            Text("显示模式").font(.subheadline.weight(.medium))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 180 : 84))], spacing: 8) {
                                ForEach(AppAppearance.allCases) { appearance in
                                    let selected = appearanceName == appearance.rawValue
                                    Button {
                                        appearanceName = appearance.rawValue
                                    } label: {
                                        Text(appearance.title)
                                            .font(.subheadline.weight(selected ? .semibold : .regular))
                                            .foregroundStyle(selected ? design.onAccent : design.ink)
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .background(selected ? design.blue : design.canvas,
                                                        in: RoundedRectangle(cornerRadius: 10))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("显示模式：" + appearance.title)
                                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                                }
                            }
                        }
                        Divider()
                        Toggle("桌面图标跟随主题", isOn: $desktopIconFollowsTheme)
                            .font(.subheadline.weight(.medium))
                            .tint(design.blue)
                            .disabled(themeIcon.isUpdating)
                            .onChange(of: desktopIconFollowsTheme) { _, enabled in
                                themeIcon.updateIcon(for: AppTheme(rawValue: themeName) ?? .paper, followsTheme: enabled)
                            }
                        Text(desktopIconFollowsTheme
                             ? "已开启：桌面图标随主题更换，系统会显示更换提示。"
                             : "已关闭：切换主题只改变 App 外观，保留当前桌面图标。")
                            .font(.caption).foregroundStyle(design.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if themeIcon.isUpdating {
                            ProgressView("正在更换桌面图标…")
                                .font(.caption)
                        }
                        if desktopIconFollowsTheme, let message = themeIcon.errorMessage {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message).font(.caption).foregroundStyle(design.muted)
                                Button("重试更换图标") {
                                    themeIcon.updateIcon(for: AppTheme(rawValue: themeName) ?? .paper, followsTheme: desktopIconFollowsTheme)
                                }
                                .buttonStyle(.glass)
                                .disabled(themeIcon.isUpdating)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                TTSectionTitle(title: "数据管理")
                TTCard {
                    NavigationLink {
                        DataBackupView()
                    } label: {
                        HStack(spacing: 12) {
                            TTIcon(systemName: "externaldrive.fill", tint: design.blue, size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("数据备份").font(.subheadline.weight(.medium)).foregroundStyle(design.ink)
                                Text("iCloud 同步、数据导入与导出").font(.caption).foregroundStyle(design.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(design.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                TTSectionTitle(title: "活动提醒")
                TTCard {
                    NavigationLink {
                        ReminderManagementView()
                    } label: {
                        HStack(spacing: 12) {
                            TTIcon(systemName: "bell.badge", tint: design.violet, size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("管理提醒").font(.subheadline.weight(.medium))
                                Text("\(model.reminders.count) 个提醒 · 添加、编辑与删除")
                                    .font(.caption).foregroundStyle(design.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                TTSectionTitle(title: "自动记录")
                TTLocationPermissionNotice(status: model.locationAuthorizationStatus)
                TTCard {
                    VStack(spacing: 14) {
                        settingsRow("定位权限", detail: authorizationText, icon: "location.fill", tint: design.blue) {
                            openSystemSettings()
                        }
                        Divider()
                        settingsRow("地点", detail: "已设置 \(model.workTriggers.count) 个地点", icon: "mappin.and.ellipse", tint: design.violet) {
                            showingPlaces = true
                        }
                        Divider()
                        HStack(spacing: 12) {
                            TTIcon(systemName: "location.fill", tint: design.blue, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("自动记录").font(.subheadline.weight(.medium))
                                Text(model.automaticRecordingDetail)
                                    .font(.caption).foregroundStyle(design.muted)
                            }
                            Spacer()
                        }
                        if case .unavailable(let message) = model.geofenceCapabilityStatus {
                            TTCapabilityNotice(message: message)
                        }
                    }
                }

#if DEBUG
                TTSectionTitle(title: "开发者工具")
                TTCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("启用测试数据工具", isOn: $developerDemoToolsEnabled)
                            .tint(design.blue)
                        Text("仅 Debug 构建可见；会生成覆盖全部地点类型及对应时段的示例记录，不会进入线上产品。")
                            .font(.caption).foregroundStyle(design.muted)
                        if developerDemoToolsEnabled {
                            Divider()
                            Button {
                                if let insertedDays = model.generateThirtyDayDemoData() {
                                    demoResultMessage = insertedDays == 0
                                        ? "最近 30 天已有测试数据。"
                                        : "已生成 \(insertedDays) 天测试记录。"
                                    showingDemoResult = true
                                }
                            } label: {
                                Label("生成 30 天全场景测试数据", systemImage: "wand.and.stars")
                            }
                            .buttonStyle(.glassProminent)
                            .foregroundStyle(design.onAccent)
                            .tint(design.blue)

                            if model.activeDemoSessionCount > 0 {
                                Button(role: .destructive) {
                                    showingClearDemoConfirmation = true
                                } label: {
                                    Label("清除 \(model.activeDemoSessionCount) 条测试记录", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
#endif
                TTSectionTitle(title: "关于")
                TTCard {
                    NavigationLink {
                        AboutView()
                    } label: {
                        HStack(spacing: 12) {
                            TTIcon(systemName: "info.circle.fill", tint: design.blue, size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("关于时光落点").font(.subheadline.weight(.medium)).foregroundStyle(design.ink)
                                Text("版本 \(AppVersionInfo.version)").font(.caption).foregroundStyle(design.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(design.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                TTSectionTitle(title: "隐私与数据")
                TTCard {
                    HStack(alignment: .top, spacing: 12) {
                        TTIcon(systemName: "lock.fill", tint: design.violet)
                        Text("活动与位置事件会保存在本机；iCloud 同步可用时，地点、围栏半径、工作日设置与记录都会同步到您的私有 iCloud 数据库。TimeTrace 只记录围栏进出，不保存连续轨迹。")
                            .font(.subheadline).foregroundStyle(design.muted)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .contentShape(Rectangle())
            .onTapGesture { isNicknameFocused = false }
        }
        .scrollDismissesKeyboard(.interactively)
        .timeTraceScreen()
        .timeTraceTabTitle("设置")
        .sheet(isPresented: $showingPlaces) { PlacesView() }
#if DEBUG
        .alert("演示数据", isPresented: $showingDemoResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(demoResultMessage)
        }
        .confirmationDialog("清除测试数据？", isPresented: $showingClearDemoConfirmation, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                let removed = model.clearThirtyDayDemoData()
                demoResultMessage = removed == 0 ? "没有可清除的测试记录。" : "已清除 \(removed) 条测试记录。"
                showingDemoResult = true
            }
        } message: {
            Text("只会清除通过“生成 30 天全场景测试数据”创建的记录和示例地点，不影响真实工作记录或地点。")
        }
#endif
    }

    /// Chinese and other full-width glyphs consume two visual units; Latin text
    /// consumes one. This gives 10 Han characters and about 20 Latin characters
    /// the same visual allowance in the greeting.
    private func nicknameWithinDisplayLimit(_ value: String) -> String {
        let limit = 20
        var used = 0
        var result = ""
        for character in value {
            let scalar = character.unicodeScalars.first?.value ?? 0
            let isWide = (0x1100...0x115F).contains(scalar)
                || (0x2E80...0xA4CF).contains(scalar)
                || (0xAC00...0xD7A3).contains(scalar)
                || (0xF900...0xFAFF).contains(scalar)
                || (0xFE10...0xFE6F).contains(scalar)
                || (0xFF01...0xFF60).contains(scalar)
                || (0xFFE0...0xFFE6).contains(scalar)
                || scalar >= 0x1F000
            let width = isWide ? 2 : 1
            guard used + width <= limit else { break }
            result.append(character)
            used += width
        }
        return result
    }

    private func settingsRow(_ title: String, detail: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                TTIcon(systemName: icon, tint: tint, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(design.ink)
                    Text(detail).font(.caption).foregroundStyle(design.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(design.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var authorizationText: String {
        switch model.locationAuthorizationStatus {
        case .authorizedAlways: "始终允许"
        case .authorizedWhenInUse: "使用应用期间"
        case .denied: "已拒绝"
        case .restricted: "受限制"
        case .notDetermined: "未请求"
        @unknown default: "未知"
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private enum AppVersionInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
    static let description = "时光落点 TimeTrace · 版本 \(version)（构建 \(build)）"
}

private struct AboutView: View {
    @Environment(\.timeTraceDesign) private var design
    @State private var showingCopyConfirmation = false
    @State private var showingEmailCopyConfirmation = false
    private let feedbackEmail = "huangbo.me@gmail.com"

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 12) {
                    TimeTraceMark(size: 80)
                    Text("时光落点 TimeTrace").font(.title2.weight(.bold))
                    Text("看见时间，留住生活的足迹。")
                        .font(.subheadline).foregroundStyle(design.muted)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)

                TTSectionTitle(title: "应用介绍")
                TTCard {
                    Text("时光落点帮助你记录在已设置地点停留的时间，通过历史记录、统计和时间手记，回顾每天的时间去向。")
                        .font(.subheadline).foregroundStyle(design.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                TTSectionTitle(title: "版本信息")
                TTCard {
                    VStack(alignment: .leading, spacing: 14) {
                        informationRow("版本号", value: AppVersionInfo.version)
                        Divider()
                        informationRow("构建号", value: AppVersionInfo.build)
                        Divider()
                        Button {
                            UIPasteboard.general.string = AppVersionInfo.description
                            showingCopyConfirmation = true
                        } label: {
                            Label("复制版本信息", systemImage: "doc.on.doc")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(design.blue)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                TTSectionTitle(title: "联系与反馈")
                TTCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("反馈邮箱").font(.subheadline.weight(.medium))
                        Button {
                            UIPasteboard.general.string = feedbackEmail
                            showingEmailCopyConfirmation = true
                        } label: {
                            HStack(spacing: 12) {
                                Text(feedbackEmail)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: "doc.on.doc")
                            }
                            .font(.subheadline)
                            .foregroundStyle(design.blue)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("复制反馈邮箱：\(feedbackEmail)")
                        Text("点击邮箱即可复制。反馈问题时，请附上版本信息和操作步骤，帮助我们定位问题。")
                            .font(.caption).foregroundStyle(design.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .timeTraceScreen()
        .navigationTitle("关于时光落点")
        .navigationBarTitleDisplayMode(.inline)
        .alert("已复制版本信息", isPresented: $showingCopyConfirmation) {
            Button("好", role: .cancel) {}
        } message: {
            Text(AppVersionInfo.description)
        }
        .alert("已复制邮箱", isPresented: $showingEmailCopyConfirmation) {
            Button("好", role: .cancel) {}
        } message: {
            Text(feedbackEmail)
        }
    }

    private func informationRow(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title)
                Spacer(minLength: 16)
                Text(value).foregroundStyle(design.muted).fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                Text(value).foregroundStyle(design.muted)
            }
        }
        .font(.subheadline)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

struct WorkScheduleImpactPrompt: Equatable {
    let affectedCount: Int
    let title = "排班变更应用范围"
    var allHistoryButtonTitle: String { "全部历史（\(affectedCount) 条）" }
    var message: String {
        "当前地点共有 \(affectedCount) 条未删除记录。\n" +
        "仅今后：已有 \(affectedCount) 条记录保持原排班，下次到达时生效。\n" +
        "全部历史：按新排班重新计算 \(affectedCount) 条记录，包含进行中的记录。"
    }
}

struct WorkplaceEditorView: View {
    @Environment(\.timeTraceDesign) private var design

    @EnvironmentObject private var store: SettingsFeatureStore
    @Environment(\.dismiss) private var dismiss
    @State private var coordinate: CLLocationCoordinate2D
    @State private var position: MapCameraPosition
    @State private var radius: Double
    @FocusState private var focusedField: WorkplaceInputField?
    @State private var placeName = ""
    @State private var placeType: PlaceType = .work
    @State private var placeEnabled = true
    @State private var schedule: WorkScheduleEditorState
    @State private var locationAccuracy: CLLocationAccuracy?
    @State private var usesReducedAccuracy = false
    @State private var showingDeleteConfirmation = false
    @State private var showingScheduleScopeConfirmation = false
    @State private var scheduleImpactPrompt: WorkScheduleImpactPrompt?
    let trigger: ActivityTrigger?

    private var model: AppModel { store.application }

    init(trigger: ActivityTrigger? = nil) {
        self.trigger = trigger
        let initial = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        _coordinate = State(initialValue: initial)
        _position = State(initialValue: .camera(MapCamera(
            centerCoordinate: ChinaMapCoordinateConverter.mapCoordinate(fromSystemCoordinate: initial),
            distance: 1_500
        )))
        _radius = State(initialValue: 200)
        _schedule = State(initialValue: WorkScheduleEditorState(trigger: trigger))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("地点名称，例如：公司、办公室或客户现场", text: $placeName)
                    .focused($focusedField, equals: .placeName)
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                if let trigger, !trigger.isDemoData {
                    Toggle("启用地点自动记录", isOn: $placeEnabled)
                    Text("停用后不再接收此地点的进出事件；已有记录保留，进行中的记录可在历史中补齐。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("地点类型") {
                    Picker("类型", selection: $placeType) {
                        ForEach(PlaceType.allCases) { type in
                            Label(type.displayName, systemImage: type.systemImage).tag(type)
                        }
                    }
                }
                if placeType == .work {
                    WorkScheduleEditorSection(schedule: $schedule)
                }
                Section("定位地点") {
                    Button {
                        Task { await useCurrentLocationAsPlace() }
                    } label: {
                        Label("设为当前位置", systemImage: "location.fill")
                    }
                }

                WorkplaceAddressSearch(
                    coordinate: $coordinate,
                    position: $position,
                    focusedField: $focusedField
                )

                Section("在地图上微调") {
                    LabeledContent("围栏半径", value: "\(Int(radius)) 米")
                    Slider(value: $radius, in: 10...1000, step: 10)
                    Text("拖动滑块时，地图会即时更新围栏范围。建议至少设为 100 米。")
                        .font(.caption)
                        .foregroundStyle(design.muted)
                    Text("轻点地图设定地点，或拖动红色图钉微调。地图不会拦截上下滑动；搜索或定位可重新居中地图。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    WorkplaceMapPicker(
                        coordinate: $coordinate,
                        position: $position,
                        radius: $radius,
                        height: 320
                    )
                    .simultaneousGesture(TapGesture().onEnded { focusedField = nil })
                }
                LocationAccuracyNotice(
                    horizontalAccuracy: locationAccuracy,
                    usesReducedAccuracy: usesReducedAccuracy
                )
            }
            .contentShape(Rectangle())
            .gesture(WorkplaceKeyboardDismissGesture { focusedField = nil })
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .timeTraceScreen()
            .navigationTitle(trigger == nil ? "添加地点" : "编辑地点")
            .onAppear {
                if let trigger, let lat = trigger.latitude, let lon = trigger.longitude {
                    let current = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    coordinate = current
                    radius = trigger.radius ?? 200
                    position = .camera(
                        MapCamera(
                            centerCoordinate: ChinaMapCoordinateConverter.mapCoordinate(
                                fromSystemCoordinate: current
                            ),
                            distance: WorkplaceMapPicker.cameraDistance(for: radius)
                        )
                    )
                    placeName = trigger.displayPlaceName
                    placeType = trigger.placeType
                    placeEnabled = trigger.isEnabled
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        requestSave()
                    }
                    .disabled(placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isScheduleValid)
                }
                if trigger != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("删除地点", systemImage: "trash")
                        }
                    }
                }
            }
            .confirmationDialog("删除地点？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    guard let trigger else { return }
                    if model.deleteWorkplace(trigger) { dismiss() }
                }
            } message: {
                Text("将停止监测并删除“\(trigger?.displayPlaceName ?? "")”。")
            }
            .alert(scheduleImpactPrompt?.title ?? "排班变更应用范围",
                   isPresented: $showingScheduleScopeConfirmation,
                   presenting: scheduleImpactPrompt) { prompt in
                Button("仅今后") { save(scope: .futureOnly) }
                Button(prompt.allHistoryButtonTitle) { save(scope: .allHistory) }
                Button("取消", role: .cancel) {}
            } message: { prompt in
                Text(prompt.message)
            }
        }
    }

    private var isScheduleValid: Bool {
        placeType != .work || editedSchedule != nil
    }

    private var editedSchedule: WorkScheduleSnapshot? {
        guard placeType == .work else { return nil }
        return schedule.snapshot
    }

    private func requestSave() {
        guard isScheduleValid else { return }
        if let trigger, placeType == .work, editedSchedule != trigger.workScheduleSnapshot {
            scheduleImpactPrompt = WorkScheduleImpactPrompt(
                affectedCount: model.workScheduleAffectedSessionCount(triggerId: trigger.id)
            )
            showingScheduleScopeConfirmation = true
        } else {
            save(scope: .futureOnly)
        }
    }

    private func save(scope: WorkScheduleEditScope) {
        let schedule = editedSchedule
        let saved: Bool
        if let trigger {
            saved = model.updateWorkplace(
                triggerId: trigger.id,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radius: radius,
                placeName: placeName,
                placeType: placeType,
                isEnabled: placeEnabled,
                schedule: schedule,
                scheduleEditScope: scope
            )
        } else {
            saved = model.addWorkplace(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radius: radius,
                placeName: placeName,
                placeType: placeType,
                schedule: schedule
            )
        }
        if saved { dismiss() }
    }

    private func useCurrentLocationAsPlace() async {
        do {
            let current = try await model.geofence.requestCurrentLocation()
            coordinate = current
            locationAccuracy = model.geofence.lastHorizontalAccuracy
            usesReducedAccuracy = model.geofence.accuracyAuthorization == .reducedAccuracy
            position = .camera(
                MapCamera(
                    centerCoordinate: ChinaMapCoordinateConverter.mapCoordinate(
                        fromSystemCoordinate: current
                    ),
                    distance: WorkplaceMapPicker.cameraDistance(
                        for: max(radius, locationAccuracy ?? 0)
                    )
                )
            )
        } catch {
            model.lastError = TimeTraceLocalization.errorMessage(
                error,
                fallback: "暂时无法获取当前位置，请稍后重试。"
            )
        }
    }
}


private struct ReminderManagementView: View {
    @Environment(\.timeTraceDesign) private var design

    @EnvironmentObject private var store: SettingsFeatureStore
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var adding = false
    @State private var editing: ReminderDefinition?
    private var model: AppModel { store.application }

    var body: some View {
        List {
            if model.notificationCapabilityStatus != .available {
                Section {
                    Text("通知未获授权或暂不可用，提醒仍会保存。请检查系统通知设置。")
                        .font(.subheadline).foregroundStyle(.orange)
                    Button("前往系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    Button("重新检查并安排通知") {
                        Task {
                            await model.refreshNotificationAuthorization()
                            await model.reconcileReminders()
                        }
                    }
                }
            }
            Section {
                Button("添加提醒", systemImage: "plus") { adding = true }
                ForEach(model.reminders, id: \.id) { reminder in
                    Button { editing = reminder } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(reminder.name).foregroundStyle(design.ink)
                                Text(String(format: "%02d:%02d", reminder.hour, reminder.minute) + " · " + weekdayText(reminder.weekdaysMask))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(reminder.isEnabled ? "已启用" : "已停用")
                                .font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                }
            } footer: {
                Text("点击提醒可编辑或删除。通知中可开始、延后或跳过；开始后可在今天页完成活动。")
            }
        }
        .scrollContentBackground(.hidden)
        .timeTraceScreen()
        .navigationTitle("活动提醒")
        .sheet(isPresented: $adding) { ReminderEditorView(reminder: nil) }
        .sheet(item: $editing) { ReminderEditorView(reminder: $0) }
        .task { await model.refreshNotificationAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshNotificationAuthorization() } }
        }
    }

    private func weekdayText(_ mask: Int) -> String {
        if mask & 127 == 127 { return "每天" }
        return [(2, "周一"), (3, "周二"), (4, "周三"), (5, "周四"), (6, "周五"), (7, "周六"), (1, "周日")]
            .filter { mask.containsWeekday($0.0) }.map { $0.1 }.joined(separator: "、")
    }
}

private struct ReminderEditorView: View {
    @EnvironmentObject private var store: SettingsFeatureStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var time: Date
    @State private var weekdays: Int
    @State private var enabled: Bool
    @State private var type: ActivityType = .custom
    @State private var busy = false
    @State private var confirmingDelete = false
    @State private var error: String?
    let reminder: ReminderDefinition?
    private var model: AppModel { store.application }

    init(reminder: ReminderDefinition?) {
        self.reminder = reminder
        _name = State(initialValue: reminder?.name ?? "")
        _time = State(initialValue: Calendar.current.date(from: DateComponents(hour: reminder?.hour ?? 21, minute: reminder?.minute ?? 0)) ?? Date())
        _weekdays = State(initialValue: reminder?.weekdaysMask ?? 127)
        _enabled = State(initialValue: reminder?.isEnabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("提醒内容") {
                    TextField("提醒名称", text: $name)
                    if reminder == nil {
                        Picker("活动类型", selection: $type) {
                            ForEach(ActivityType.allCases) { value in Text(value.displayName).tag(value) }
                        }
                    }
                    DatePicker("提醒时间", selection: $time, displayedComponents: .hourAndMinute)
                    if reminder != nil { Toggle("启用提醒", isOn: $enabled) }
                }
                Section("重复日期") { WeekdayPicker(mask: $weekdays) }
                if let error { Text(error).foregroundStyle(.red) }
                if busy { ProgressView("正在保存…") }
                if reminder != nil {
                    Section {
                        Button("删除提醒", role: .destructive) { confirmingDelete = true }
                    } footer: {
                        Text("删除或停用只影响后续通知，已有活动记录保留。")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .timeTraceScreen()
            .disabled(busy)
            .navigationTitle(reminder == nil ? "添加提醒" : "编辑提醒")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || weekdays & 127 == 0)
                }
            }
            .confirmationDialog("删除这个提醒？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除提醒", role: .destructive) {
                    guard let reminder else { return }
                    busy = true
                    Task {
                        defer { busy = false }
                        if await model.deleteReminder(reminder) { dismiss() }
                        else { error = model.lastError }
                    }
                }
            } message: { Text("对应的待发送和已送达通知会清理，已有活动记录保留。") }
            .interactiveDismissDisabled(busy)
        }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            let saved: Bool
            if let reminder {
                saved = await model.updateReminder(id: reminder.id, name: name, time: time,
                                                   weekdaysMask: weekdays, isEnabled: enabled)
            } else {
                saved = await model.createReminder(name: name, type: type, time: time, weekdaysMask: weekdays)
            }
            if saved { dismiss() } else { error = model.lastError }
        }
    }
}
