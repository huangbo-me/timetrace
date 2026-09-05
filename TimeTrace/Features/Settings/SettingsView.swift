import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: SettingsFeatureStore
    @Environment(\.openURL) private var openURL
    @AppStorage("profileNickname") private var profileNickname = ""
    @State private var showingPlaces = false
    @State private var showingReminder = false
    @State private var showingICloudHelp = false

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
                        Text("时迹").font(.title2.weight(.bold))
                        Text("TimeTrace · 记录每一段专注时光").font(.caption).foregroundStyle(TimeTraceDesign.muted)
                    }
                }

                TTSectionTitle(title: "个人资料")
                TTCard {
                    HStack(spacing: 12) {
                        TTIcon(systemName: "person.fill", tint: TimeTraceDesign.blue, size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("昵称").font(.subheadline.weight(.medium))
                            Text("最多 10 个汉字或 20 个英文字符").font(.caption).foregroundStyle(TimeTraceDesign.muted)
                        }
                        Spacer()
                        TextField("未设置", text: $profileNickname)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 128)
                            .onChange(of: profileNickname) { _, newValue in
                                let trimmed = nicknameWithinDisplayLimit(newValue)
                                if trimmed != newValue { profileNickname = trimmed }
                            }
                    }
                }

                TTSectionTitle(title: "iCloud 同步")
                TTCard {
                    Button {
                        if model.iCloudSyncStatus == .notEnabled {
                            showingICloudHelp = true
                        } else {
                            model.refreshICloudSyncStatus()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            TTIcon(systemName: iCloudIcon, tint: iCloudTint, size: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.iCloudSyncStatus.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(TimeTraceDesign.ink)
                                Text(model.iCloudSyncStatus.detail)
                                    .font(.caption)
                                    .foregroundStyle(TimeTraceDesign.muted)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 8)
                            if model.iCloudSyncStatus == .checking {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(TimeTraceDesign.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("轻点重新检查 iCloud 同步状态")
                }

                TTSectionTitle(title: "自动记录")
                TTCard {
                    VStack(spacing: 14) {
                        settingsRow("定位权限", detail: authorizationText, icon: "location.fill", tint: TimeTraceDesign.blue) {
                            openSystemSettings()
                        }
                        Divider()
                        settingsRow("地点", detail: "已设置 \(model.workTriggers.count) 个地点", icon: "mappin.and.ellipse", tint: TimeTraceDesign.violet) {
                            showingPlaces = true
                        }
                        Divider()
                        HStack(spacing: 12) {
                            TTIcon(systemName: "checkmark.circle.fill", tint: .green, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("自动记录").font(.subheadline.weight(.medium))
                                Text("到达任一地点后自动开始，离开后自动结束")
                                    .font(.caption).foregroundStyle(TimeTraceDesign.muted)
                            }
                            Spacer()
                            Toggle("", isOn: .constant(true)).labelsHidden().disabled(true)
                        }
                        if case .unavailable(let message) = model.geofenceCapabilityStatus {
                            TTCapabilityNotice(message: message)
                        }
                    }
                }

                TTSectionTitle(title: "活动提醒", action: "添加", onAction: { showingReminder = true })
                TTCard {
                    if case .unavailable(let message) = model.notificationCapabilityStatus {
                        TTCapabilityNotice(message: message, systemImage: "bell.slash.fill")
                        Divider()
                    }
                    if model.reminders.isEmpty {
                        HStack { TTIcon(systemName: "bell.badge", tint: .orange); Text("尚未添加提醒").font(.subheadline).foregroundStyle(TimeTraceDesign.muted); Spacer() }
                    } else {
                        VStack(spacing: 12) {
                            ForEach(model.reminders, id: \.id) { reminder in
                                HStack {
                                    TTIcon(systemName: "bell.fill", tint: .orange, size: 34)
                                    VStack(alignment: .leading) {
                                        Text(reminder.name).font(.subheadline.weight(.medium))
                                        Text(String(format: "%02d:%02d", reminder.hour, reminder.minute)).font(.caption).foregroundStyle(TimeTraceDesign.muted)
                                    }
                                    Spacer()
                                    Button(role: .destructive) { model.deleteReminder(reminder) } label: { Image(systemName: "trash") }
                                }
                            }
                        }
                    }
                }
#if DEBUG
                TTSectionTitle(title: "开发者工具")
                TTCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("启用测试数据工具", isOn: $developerDemoToolsEnabled)
                            .tint(TimeTraceDesign.blue)
                        Text("仅 Debug 构建可见；会生成覆盖全部地点类型及对应时段的示例记录，不会进入线上产品。")
                            .font(.caption).foregroundStyle(TimeTraceDesign.muted)
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
                            .buttonStyle(.borderedProminent)
                            .tint(TimeTraceDesign.blue)

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
                TTSectionTitle(title: "隐私与数据")
                TTCard {
                    HStack(alignment: .top, spacing: 12) {
                        TTIcon(systemName: "lock.fill", tint: TimeTraceDesign.violet)
                        Text("活动与位置事件会保存在本机；iCloud 同步可用时，地点、围栏半径、工作日设置与记录都会同步到您的私有 iCloud 数据库。TimeTrace 只记录围栏进出，不保存连续轨迹。")
                            .font(.subheadline).foregroundStyle(TimeTraceDesign.muted)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .timeTraceScreen()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingPlaces) { PlacesView() }
        .sheet(isPresented: $showingReminder) { ReminderEditorView() }
        .alert("开启 iCloud 同步", isPresented: $showingICloudHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请前往“设置”> 您的姓名 > iCloud > 已存储到 iCloud，找到“时迹”并开启同步。开启后请完全退出并重新打开时迹，新的本地数据库才会接入 iCloud。")
        }
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
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(TimeTraceDesign.ink)
                    Text(detail).font(.caption).foregroundStyle(TimeTraceDesign.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(TimeTraceDesign.muted)
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

    private var iCloudIcon: String {
        switch model.iCloudSyncStatus {
        case .enabled: "checkmark.icloud.fill"
        case .checking: "icloud"
        case .notEnabled, .signedOut, .restricted, .unavailable: "exclamationmark.icloud.fill"
        }
    }

    private var iCloudTint: Color {
        switch model.iCloudSyncStatus {
        case .enabled: .green
        case .checking: TimeTraceDesign.blue
        case .notEnabled, .signedOut, .restricted, .unavailable: .orange
        }
    }

    @ViewBuilder
    private var authorizationAction: some View {
        switch model.locationAuthorizationStatus {
        case .authorizedAlways:
            Label("后台自动记录已开启", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .authorizedWhenInUse:
            Button("在系统设置中改为“始终”") { openSystemSettings() }
        case .denied, .restricted:
            Button("打开系统定位设置") { openSystemSettings() }
        case .notDetermined:
            Button("请求始终允许") { model.geofence.requestAlwaysAuthorization() }
        @unknown default:
            Button("打开系统定位设置") { openSystemSettings() }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

struct WorkplaceEditorView: View {
    @EnvironmentObject private var store: SettingsFeatureStore
    @Environment(\.dismiss) private var dismiss
    @State private var coordinate: CLLocationCoordinate2D
    @State private var position: MapCameraPosition
    @State private var radius: Double
    @State private var placeName = ""
    @State private var placeType: PlaceType = .work
    @State private var locationAccuracy: CLLocationAccuracy?
    @State private var usesReducedAccuracy = false
    @State private var showingDeleteConfirmation = false
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
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("地点名称，例如：公司、办公室或客户现场", text: $placeName)
                Section("地点类型") {
                    Picker("类型", selection: $placeType) {
                        ForEach(PlaceType.allCases) { type in
                            Label(type.displayName, systemImage: type.systemImage).tag(type)
                        }
                    }
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
                    position: $position
                )

                Section("在地图上微调") {
                    LabeledContent("围栏半径", value: "\(Int(radius)) 米")
                    Slider(value: $radius, in: 10...1000, step: 10)
                    Text("拖动滑块时，地图会即时更新围栏范围。建议至少设为 100 米。")
                        .font(.caption)
                        .foregroundStyle(TimeTraceDesign.muted)
                    Text("轻点地图设定地点，或拖动红色图钉微调。地图不会拦截上下滑动；搜索或定位可重新居中地图。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    WorkplaceMapPicker(
                        coordinate: $coordinate,
                        position: $position,
                        radius: $radius,
                        height: 320
                    )
                }
                LocationAccuracyNotice(
                    horizontalAccuracy: locationAccuracy,
                    usesReducedAccuracy: usesReducedAccuracy
                )
            }
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
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let trigger {
                            model.updateWorkplace(
                                triggerId: trigger.id,
                                latitude: coordinate.latitude,
                                longitude: coordinate.longitude,
                                radius: radius,
                                placeName: placeName,
                                placeType: placeType
                            )
                        } else {
                            model.addWorkplace(
                                latitude: coordinate.latitude,
                                longitude: coordinate.longitude,
                                radius: radius,
                                placeName: placeName,
                                placeType: placeType
                            )
                        }
                        dismiss()
                    }
                    .disabled(placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                    model.deleteWorkplace(trigger)
                    dismiss()
                }
            } message: {
                Text("将停止监测并删除“\(trigger?.displayPlaceName ?? "")”。")
            }
        }
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

struct ReminderEditorView: View {
    @EnvironmentObject private var store: SettingsFeatureStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = ActivityType.custom
    @State private var time = Calendar.current.date(from: DateComponents(hour: 21)) ?? Date()
    @State private var weekdaysMask = 0b1111111

    private var model: AppModel { store.application }

    var body: some View {
        NavigationStack {
            Form {
                TextField("例如：阅读、运动或会议", text: $name)
                Picker("类型", selection: $type) {
                    ForEach(ActivityType.allCases) { Text($0.displayName).tag($0) }
                }
                DatePicker("提醒时间", selection: $time, displayedComponents: .hourAndMinute)
                WeekdayPicker(mask: $weekdaysMask)
            }
            .navigationTitle("添加提醒")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            await model.createReminder(name: name, type: type, time: time, weekdaysMask: weekdaysMask)
                            dismiss()
                        }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || weekdaysMask == 0)
                }
            }
        }
    }
}
