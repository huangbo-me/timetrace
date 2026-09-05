import CoreLocation
import MapKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var coordinate = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
    @State private var position: MapCameraPosition = .camera(
        MapCamera(
            centerCoordinate: ChinaMapCoordinateConverter.mapCoordinate(
                fromSystemCoordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
            ),
            distance: 1_500
        )
    )
    @State private var radius = 200.0
    @State private var placeName = "工作地点"
    @State private var weekdaysMask = 0b0111110
    @State private var useNormalHours = true
    @State private var normalStart = Calendar.current.date(from: DateComponents(hour: 9)) ?? Date()
    @State private var normalEnd = Calendar.current.date(from: DateComponents(hour: 18)) ?? Date()
    @State private var locating = false
    @State private var locationAccuracy: CLLocationAccuracy?
    @State private var usesReducedAccuracy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        TimeTraceMark(size: 54)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("时迹").font(.title2.weight(.bold))
                            Text("让工作时间，自动留下痕迹").font(.subheadline).foregroundStyle(TimeTraceDesign.muted)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                Section {
                    Text("TimeTrace 会用系统地理围栏记录你真正到达和离开地点的时间，不会持续保存移动轨迹。")
                        .foregroundStyle(.secondary)
                } header: { Text("自动记录，真实优先") }

                Section("地点") {
                    TextField("地点名称，例如：公司、办公室或客户现场", text: $placeName)
                    Button {
                        Task { await useCurrentLocation() }
                    } label: {
                        Label(locating ? "正在定位…" : "设为当前位置", systemImage: "location.fill")
                    }
                    .disabled(locating)

                    WorkplaceAddressSearch(
                        coordinate: $coordinate,
                        position: $position
                    )
                    LabeledContent("围栏半径", value: "\(Int(radius)) 米")
                    Slider(value: $radius, in: 10...1000, step: 10)
                    Text("拖动滑块时，地图会即时更新围栏范围。建议至少设为 100 米。")
                        .font(.caption)
                        .foregroundStyle(TimeTraceDesign.muted)
                    Text("地图仅用于落点微调：轻点地图设定地点，或拖动红色图钉。上下滑动可继续浏览配置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    WorkplaceMapPicker(
                        coordinate: $coordinate,
                        position: $position,
                        radius: $radius,
                        height: 260
                    )
                    LocationAccuracyNotice(
                        horizontalAccuracy: locationAccuracy,
                        usesReducedAccuracy: usesReducedAccuracy
                    )
                }

                Section("常规安排（不限制自动记录）") {
                    WeekdayPicker(mask: $weekdaysMask)
                    Toggle("设置正常工作时间", isOn: $useNormalHours)
                    if useNormalHours {
                        DatePicker("开始", selection: $normalStart, displayedComponents: .hourAndMinute)
                        DatePicker("结束", selection: $normalEnd, displayedComponents: .hourAndMinute)
                    }
                }

                Section {
                    Button("完成配置") {
                        model.finishOnboarding(
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude,
                            radius: radius,
                            weekdaysMask: weekdaysMask,
                            normalStartMinute: useNormalHours ? minuteOfDay(normalStart) : nil,
                            normalEndMinute: useNormalHours ? minuteOfDay(normalEnd) : nil,
                            placeName: placeName
                        )
                    }
                    .frame(maxWidth: .infinity)
                } footer: {
                    Text("系统会先请求使用期间定位；完成后会继续请求“始终允许”和通知权限，用于后台围栏记录与提醒。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(TimeTraceDesign.canvas)
            .navigationTitle("欢迎使用")
            .onAppear {
                if model.geofence.authorizationStatus == .notDetermined {
                    model.geofence.requestWhenInUseAuthorization()
                }
            }
        }
    }

    private func useCurrentLocation() async {
        locating = true
        model.geofence.requestWhenInUseAuthorization()
        do {
            let current = try await model.geofence.requestCurrentLocation()
            coordinate = current
            locationAccuracy = model.geofence.lastHorizontalAccuracy
            usesReducedAccuracy = model.geofence.accuracyAuthorization == .reducedAccuracy
            position = .camera(
                MapCamera(
                    centerCoordinate: ChinaMapCoordinateConverter.mapCoordinate(fromSystemCoordinate: current),
                    distance: WorkplaceMapPicker.cameraDistance(
                        for: max(radius, locationAccuracy ?? 0)
                    )
                )
            )
        } catch {
            model.lastError = TimeTraceLocalization.errorMessage(error, fallback: "暂时无法获取当前位置，请稍后重试。")
        }
        locating = false
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

struct WeekdayPicker: View {
    @Binding var mask: Int
    private let values = [(2, "一"), (3, "二"), (4, "三"), (5, "四"), (6, "五"), (7, "六"), (1, "日")]

    var body: some View {
        HStack {
            ForEach(values, id: \.0) { weekday, title in
                let selected = mask.containsWeekday(weekday)
                Button(title) {
                    let bit = weekday - 1
                    if selected { mask &= ~(1 << bit) } else { mask |= 1 << bit }
                }
                .buttonStyle(.bordered)
                .tint(selected ? .accentColor : .gray)
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
    }
}

struct WorkplaceMapPicker: View {
    @Binding var coordinate: CLLocationCoordinate2D
    @Binding var position: MapCameraPosition
    @Binding var radius: Double

    let height: CGFloat

    private let mapCoordinateSpace = "workplace-map"
    @State private var dragStartMapCoordinate: CLLocationCoordinate2D?
    @State private var draggedMapCoordinate: CLLocationCoordinate2D?

    var body: some View {
        let storedMapCoordinate = ChinaMapCoordinateConverter.mapCoordinate(fromSystemCoordinate: coordinate)
        let mapCoordinate = draggedMapCoordinate ?? storedMapCoordinate

        MapReader { proxy in
            Map(position: $position, interactionModes: []) {
                MapCircle(center: mapCoordinate, radius: radius)
                    .foregroundStyle(Color.accentColor.opacity(0.16))
                    .stroke(Color.accentColor.opacity(0.9), lineWidth: 2)

                UserAnnotation()

                Annotation("地点", coordinate: mapCoordinate, anchor: .bottom) {
                    Image(systemName: "mappin")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.red)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                        .frame(width: 44, height: 52, alignment: .bottom)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(
                                minimumDistance: 3,
                                coordinateSpace: .named(mapCoordinateSpace)
                            )
                            .onChanged { value in
                                if dragStartMapCoordinate == nil {
                                    dragStartMapCoordinate = storedMapCoordinate
                                }
                                updateDrag(translation: value.translation, using: proxy)
                            }
                            .onEnded { value in
                                finishDrag(translation: value.translation, using: proxy)
                            }
                        )
                }
            }
            .coordinateSpace(name: mapCoordinateSpace)
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named(mapCoordinateSpace))
                    .onEnded { value in
                        selectMapCoordinate(at: value.location, using: proxy)
                    }
            )
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: radius) { _, newRadius in
            withAnimation(.easeInOut(duration: 0.2)) {
                position = .camera(
                    MapCamera(
                        centerCoordinate: ChinaMapCoordinateConverter.mapCoordinate(
                            fromSystemCoordinate: coordinate
                        ),
                        distance: Self.cameraDistance(for: newRadius)
                    )
                )
            }
        }
    }

    static func cameraDistance(for radius: Double) -> Double {
        max(1_000, radius * 4.5)
    }

    private func selectMapCoordinate(at point: CGPoint, using proxy: MapProxy) {
        guard let selected = proxy.convert(point, from: .named(mapCoordinateSpace)),
              CLLocationCoordinate2DIsValid(selected) else { return }
        coordinate = ChinaMapCoordinateConverter.systemCoordinate(fromMapCoordinate: selected)
    }

    private func updateDrag(translation: CGSize, using proxy: MapProxy) {
        guard let selected = draggedCoordinate(translation: translation, using: proxy) else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            draggedMapCoordinate = selected
        }
    }

    private func finishDrag(translation: CGSize, using proxy: MapProxy) {
        let selected = draggedCoordinate(translation: translation, using: proxy) ?? draggedMapCoordinate
        if let selected {
            coordinate = ChinaMapCoordinateConverter.systemCoordinate(fromMapCoordinate: selected)
        }
        dragStartMapCoordinate = nil
        draggedMapCoordinate = nil
    }

    private func draggedCoordinate(translation: CGSize, using proxy: MapProxy) -> CLLocationCoordinate2D? {
        guard let startCoordinate = dragStartMapCoordinate,
              let startPoint = proxy.convert(startCoordinate, to: .named(mapCoordinateSpace)) else { return nil }
        let destination = CGPoint(
            x: startPoint.x + translation.width,
            y: startPoint.y + translation.height
        )
        guard let selected = proxy.convert(destination, from: .named(mapCoordinateSpace)),
              CLLocationCoordinate2DIsValid(selected) else { return nil }
        return selected
    }
}

private struct WorkplaceSearchResult: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let mapCoordinate: CLLocationCoordinate2D
}

struct WorkplaceAddressSearch: View {
    @EnvironmentObject private var model: AppModel
    @Binding var coordinate: CLLocationCoordinate2D
    @Binding var position: MapCameraPosition

    @State private var query = ""
    @State private var city = ""
    @State private var cityDraft = ""
    @State private var searchOrigin: CLLocationCoordinate2D?
    @State private var results: [WorkplaceSearchResult] = []
    @State private var message: String?
    @State private var isSearching = false
    @State private var isDeterminingCity = false
    @State private var showingCityPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .foregroundStyle(TimeTraceDesign.blue)
                Text(city.isEmpty ? (isDeterminingCity ? "正在确定当前城市…" : "尚未确定搜索城市") : "搜索城市：\(city)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    Task { await determineCurrentCity() }
                } label: {
                    Label("定位城市", systemImage: "location.fill")
                }
                .font(.subheadline.weight(.semibold))
                .disabled(isDeterminingCity)
                Button("手动城市") {
                    cityDraft = city
                    showingCityPicker = true
                }
                .font(.subheadline.weight(.semibold))
            }

            HStack(spacing: 8) {
                TextField("搜索地点、园区或地址", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }

                Button {
                    Task { await search() }
                } label: {
                    if isSearching {
                        ProgressView()
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSearching || isDeterminingCity || searchOrigin == nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("搜索地址")
            }

            ForEach(results) { result in
                Button {
                    select(result)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.name)
                            .foregroundStyle(.primary)
                        if !result.address.isEmpty, result.address != result.name {
                            Text(result.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let message {
                Label(message, systemImage: results.isEmpty ? "location.magnifyingglass" : "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(results.isEmpty ? .orange : .secondary)
            }
        }
        .task { await determineCurrentCity() }
        .onChange(of: "\(coordinate.latitude),\(coordinate.longitude)") { _, _ in
            Task { await updateSearchCity(for: coordinate) }
        }
        .alert("切换搜索城市", isPresented: $showingCityPicker) {
            TextField("例如：上海", text: $cityDraft)
            Button("取消", role: .cancel) {}
            Button("确定") {
                let trimmedCity = cityDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedCity.isEmpty else { return }
                city = trimmedCity
                results = []
                message = nil
                Task { await updateSearchOrigin(for: trimmedCity) }
            }
        } message: {
            Text("搜索结果会优先限定在所选城市。")
        }
    }

    @MainActor
    private func search() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        isSearching = true
        results = []
        message = nil

        guard let searchCenter = searchOrigin else {
            message = "请先等待当前城市定位完成，或手动切换城市。"
            return
        }
        let mapCenter = ChinaMapCoordinateConverter.mapCoordinate(fromSystemCoordinate: searchCenter)
        let region = MKCoordinateRegion(
            center: mapCenter,
            latitudinalMeters: 50_000,
            longitudinalMeters: 50_000
        )
        let cityPrefix = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = MKGeocodingRequest(addressString: cityPrefix.isEmpty ? trimmedQuery : "\(cityPrefix) \(trimmedQuery)")
        request?.region = region
        request?.preferredLocale = TimeTraceLocalization.locale

        do {
            guard let request else {
                message = "无法创建地址搜索，请稍后重试。"
                isSearching = false
                return
            }
            let mapItems = try await request.mapItems
            results = Array(mapItems.prefix(6)).map { item in
                let name = item.name ?? item.address?.shortAddress ?? "搜索结果"
                let address = item.address?.fullAddress ?? ""
                return WorkplaceSearchResult(
                    name: name,
                    address: address,
                    mapCoordinate: item.location.coordinate
                )
            }
            message = results.isEmpty
                ? "没有找到匹配地址，请使用当前位置或在地图上选择。"
                : "请选择一个\(cityPrefix.isEmpty ? "" : "“\(cityPrefix)”内的")结果"
        } catch {
            message = "搜索失败，请检查网络，或使用当前位置。"
        }

        isSearching = false
    }

    private func select(_ result: WorkplaceSearchResult) {
        coordinate = ChinaMapCoordinateConverter.systemCoordinate(fromMapCoordinate: result.mapCoordinate)
        position = .camera(MapCamera(centerCoordinate: result.mapCoordinate, distance: 1_200))
        query = result.name
        results = []
        message = "已选择：\(result.name)"
    }

    @MainActor
    private func determineCurrentCity() async {
        guard !isDeterminingCity else { return }
        isDeterminingCity = true
        defer { isDeterminingCity = false }

        guard let currentLocation = try? await model.geofence.requestCurrentLocation() else {
            searchOrigin = nil
            message = "无法获取当前位置，请检查定位权限或手动切换城市。"
            return
        }
        await updateSearchCity(for: currentLocation)
    }

    @MainActor
    private func updateSearchCity(for location: CLLocationCoordinate2D) async {
        searchOrigin = location
        let coreLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(coreLocation).first else { return }
        city = placemark.locality ?? placemark.administrativeArea ?? ""
    }

    @MainActor
    private func updateSearchOrigin(for city: String) async {
        let request = MKGeocodingRequest(addressString: city)
        request?.preferredLocale = TimeTraceLocalization.locale
        guard let mapCoordinate = try? await request?.mapItems.first?.location.coordinate else { return }
        searchOrigin = ChinaMapCoordinateConverter.systemCoordinate(fromMapCoordinate: mapCoordinate)
    }
}

/// Core Location region monitoring uses the system's WGS-84 coordinates, while
/// Apple Maps in mainland China renders map content in GCJ-02. Keep WGS-84 in
/// persistence and convert only at the map UI boundary.
enum ChinaMapCoordinateConverter {
    private static let earthRadius = 6_378_245.0
    private static let eccentricitySquared = 0.006693421622965943

    static func mapCoordinate(fromSystemCoordinate coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard requiresOffset(coordinate) else { return coordinate }
        return wgs84ToGCJ02(coordinate)
    }

    static func systemCoordinate(fromMapCoordinate coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard requiresOffset(coordinate) else { return coordinate }

        var estimate = coordinate
        // Iteratively invert the forward transform. Four passes are comfortably
        // below normal phone GPS accuracy without changing the geofence datum.
        for _ in 0..<4 {
            let mappedEstimate = wgs84ToGCJ02(estimate)
            estimate.latitude -= mappedEstimate.latitude - coordinate.latitude
            estimate.longitude -= mappedEstimate.longitude - coordinate.longitude
        }
        return estimate
    }

    private static func wgs84ToGCJ02(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let x = coordinate.longitude - 105
        let y = coordinate.latitude - 35
        var latitudeDelta = transformLatitude(x: x, y: y)
        var longitudeDelta = transformLongitude(x: x, y: y)
        let latitudeRadians = coordinate.latitude / 180 * .pi
        var magic = sin(latitudeRadians)
        magic = 1 - eccentricitySquared * magic * magic
        let squareRootMagic = sqrt(magic)
        latitudeDelta = latitudeDelta * 180 /
            ((earthRadius * (1 - eccentricitySquared)) / (magic * squareRootMagic) * .pi)
        longitudeDelta = longitudeDelta * 180 /
            (earthRadius / squareRootMagic * cos(latitudeRadians) * .pi)
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + latitudeDelta,
            longitude: coordinate.longitude + longitudeDelta
        )
    }

    private static func requiresOffset(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard coordinate.longitude >= 72.004, coordinate.longitude <= 137.8347,
              coordinate.latitude >= 0.8293, coordinate.latitude <= 55.8271 else { return false }

        // These locations use unshifted Apple map data even though they sit
        // inside the broad mainland bounding box.
        let isHongKong = (113.82...114.52).contains(coordinate.longitude) &&
            (22.08...22.58).contains(coordinate.latitude)
        let isMacau = (113.52...113.65).contains(coordinate.longitude) &&
            (22.08...22.23).contains(coordinate.latitude)
        let isTaiwan = (119.3...122.1).contains(coordinate.longitude) &&
            (21.8...25.4).contains(coordinate.latitude)
        return !isHongKong && !isMacau && !isTaiwan
    }

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var value = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        value += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        value += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        value += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return value
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        var value = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        value += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        value += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        value += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return value
    }
}

struct LocationAccuracyNotice: View {
    @Environment(\.openURL) private var openURL

    let horizontalAccuracy: CLLocationAccuracy?
    let usesReducedAccuracy: Bool

    var body: some View {
        if let horizontalAccuracy {
            Label(
                "定位精度约 ±\(formattedAccuracy(horizontalAccuracy))",
                systemImage: horizontalAccuracy <= 50 ? "location.fill" : "location"
            )
            .font(.footnote)
            .foregroundStyle(horizontalAccuracy <= 50 ? .green : .orange)
        }

        if usesReducedAccuracy {
            VStack(alignment: .leading, spacing: 6) {
                Text("系统当前只提供大致位置。请为 TimeTrace 开启“精确位置”，再重新定位。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("打开定位设置") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
            }
        }

#if targetEnvironment(simulator)
        Text("模拟器不会读取你的真实位置；当前位置由模拟器的“功能”→“位置”菜单决定。请使用真机验证实际位置。")
            .font(.footnote)
            .foregroundStyle(.orange)
#endif
    }

    private func formattedAccuracy(_ accuracy: CLLocationAccuracy) -> String {
        if accuracy < 1_000 { return "\(Int(accuracy.rounded())) 米" }
        return String(format: "%.1f 公里", accuracy / 1_000)
    }
}
