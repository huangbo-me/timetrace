import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: SettingsFeatureStore
    @Environment(\.openURL) private var openURL
    @AppStorage("profileNickname") private var profileNickname = ""
    @FocusState private var isNicknameFocused: Bool
    @State private var showingPlaces = false

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

                TTSectionTitle(title: "数据管理")
                TTCard {
                    NavigationLink {
                        DataBackupView()
                    } label: {
                        HStack(spacing: 12) {
                            TTIcon(systemName: "externaldrive.fill", tint: TimeTraceDesign.blue, size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("数据备份").font(.subheadline.weight(.medium)).foregroundStyle(TimeTraceDesign.ink)
                                Text("iCloud 同步、数据导入与导出").font(.caption).foregroundStyle(TimeTraceDesign.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(TimeTraceDesign.muted)
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
                            TTIcon(systemName: "bell.badge", tint: TimeTraceDesign.violet, size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("管理提醒").font(.subheadline.weight(.medium))
                                Text("\(model.reminders.count) 个提醒 · 添加、编辑与删除")
                                    .font(.caption).foregroundStyle(TimeTraceDesign.muted)
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
                        settingsRow("定位权限", detail: authorizationText, icon: "location.fill", tint: TimeTraceDesign.blue) {
                            openSystemSettings()
                        }
                        Divider()
                        settingsRow("地点", detail: "已设置 \(model.workTriggers.count) 个地点", icon: "mappin.and.ellipse", tint: TimeTraceDesign.violet) {
                            showingPlaces = true
                        }
                        Divider()
                        HStack(spacing: 12) {
                            TTIcon(systemName: "location.fill", tint: TimeTraceDesign.blue, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("自动记录").font(.subheadline.weight(.medium))
                                Text(model.automaticRecordingDetail)
                                    .font(.caption).foregroundStyle(TimeTraceDesign.muted)
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
    @State private var placeEnabled = true
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
                    placeEnabled = trigger.isEnabled
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let saved: Bool
                        if let trigger {
                            saved = model.updateWorkplace(
                                triggerId: trigger.id,
                                latitude: coordinate.latitude,
                                longitude: coordinate.longitude,
                                radius: radius,
                                placeName: placeName,
                                placeType: placeType,
                                isEnabled: placeEnabled
                            )
                        } else {
                            saved = model.addWorkplace(
                                latitude: coordinate.latitude,
                                longitude: coordinate.longitude,
                                radius: radius,
                                placeName: placeName,
                                placeType: placeType
                            )
                        }
                        if saved { dismiss() }
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
                    if model.deleteWorkplace(trigger) { dismiss() }
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


private struct ReminderManagementView: View {
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
                                Text(reminder.name).foregroundStyle(TimeTraceDesign.ink)
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
