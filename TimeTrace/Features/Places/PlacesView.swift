import CoreLocation
import MapKit
import SwiftUI

private enum PlaceEditorTarget: Identifiable {
    case add
    case edit(UUID)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let triggerId): "edit.\(triggerId.uuidString)"
        }
    }
}

struct PlacesView: View {
    @EnvironmentObject private var store: PlacesFeatureStore
    @State private var editorTarget: PlaceEditorTarget?
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedTriggerId: UUID?

    private var model: AppModel { store.application }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("地点").font(.largeTitle.weight(.bold))
                    Spacer()
                    Button {
                        editorTarget = .add
                    } label: {
                        Image(systemName: "plus").font(.headline.weight(.bold))
                            .frame(width: 40, height: 40).background(TimeTraceDesign.card, in: Circle())
                    }
                }
                .padding(.top, 4)

                placesMap
                HStack(spacing: 10) {
                    Button {
                        selectedTriggerId = nil
                        Task { await centerOnCurrentLocation() }
                    } label: {
                        Label("我的位置", systemImage: "location.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(TimeTraceDesign.violet)

                    Button {
                        selectedTriggerId = nil
                        Task { await centerMapForOverview() }
                    } label: {
                        Label("全部地点", systemImage: "map.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(TimeTraceDesign.violet)
                    Spacer()
                }

                if model.workTriggers.isEmpty {
                    TTCard {
                        VStack(spacing: 12) {
                            TTIcon(systemName: "mappin.slash", tint: .orange, size: 50)
                            Text("还没有设置地点").font(.headline)
                            Text("添加地点后，TimeTrace 会在你到达和离开时自动记录工作时间。")
                                .font(.subheadline).foregroundStyle(TimeTraceDesign.muted).multilineTextAlignment(.center)
                            Button("添加地点") {
                                editorTarget = .add
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(TimeTraceDesign.blue)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                    }
                } else {
                    ForEach(model.workTriggers, id: \.id) { trigger in
                        Button {
                            editorTarget = .edit(trigger.id)
                        } label: {
                            TTCard {
                                HStack(spacing: 12) {
                                    TTIcon(systemName: trigger.placeType.systemImage, size: 44)
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(trigger.displayPlaceName).font(.headline)
                                            Spacer()
                                            Text("启用中").font(.caption.weight(.semibold)).foregroundStyle(TimeTraceDesign.blue)
                                                .padding(.horizontal, 8).padding(.vertical, 4)
                                                .background(TimeTraceDesign.blue.opacity(0.1), in: Capsule())
                                    }
                                    Label(trigger.placeType.displayName, systemImage: trigger.placeType.systemImage)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(TimeTraceDesign.violet)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(TimeTraceDesign.violet.opacity(0.1), in: Capsule())
                                    Text("到达和离开时自动记录工作时间")
                                        .font(.caption).foregroundStyle(TimeTraceDesign.muted)
                                    Label("围栏半径 \(Int(trigger.radius ?? 200)) 米", systemImage: "scope")
                                        .font(.caption).foregroundStyle(TimeTraceDesign.muted)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(TimeTraceDesign.muted)
                            }
                        }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .buttonStyle(.plain)
                    }
                }

                Label {
                    Text("只在地点边界记录，不会保存你的连续移动轨迹，所有数据均保留在本机。")
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .font(.caption)
                .foregroundStyle(TimeTraceDesign.muted)
            }
            .padding(.horizontal, 20)
        }
        .timeTraceScreen()
        .sheet(item: $editorTarget) { target in
            switch target {
            case .add:
                WorkplaceEditorView()
            case .edit(let triggerId):
                if let trigger = model.workTriggers.first(where: { $0.id == triggerId }) {
                    WorkplaceEditorView(trigger: trigger)
                } else {
                    ContentUnavailableView("地点不存在", systemImage: "mappin.slash")
                }
            }
        }
        .task { await centerMapForOverview() }
        .onChange(of: model.workTriggers.map(\.id)) { _, _ in
            centerMapIncludingPlaces(currentLocation: nil)
        }
    }

    private var placesMap: some View {
        Map(position: $mapPosition) {
            UserAnnotation()
            ForEach(model.workTriggers, id: \.id) { trigger in
                if let latitude = trigger.latitude, let longitude = trigger.longitude {
                    let coordinate = ChinaMapCoordinateConverter.mapCoordinate(
                        fromSystemCoordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                    )
                    MapCircle(center: coordinate, radius: trigger.radius ?? 200)
                        .foregroundStyle(TimeTraceDesign.blue.opacity(selectedTriggerId == trigger.id ? 0.16 : 0.08))
                        .stroke(TimeTraceDesign.blue.opacity(selectedTriggerId == trigger.id ? 1 : 0.55), lineWidth: selectedTriggerId == trigger.id ? 2 : 1)
                    Annotation(trigger.displayPlaceName, coordinate: coordinate) {
                        Button {
                            selectedTriggerId = trigger.id
                        } label: {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title2)
                                .foregroundStyle(selectedTriggerId == trigger.id ? TimeTraceDesign.violet : TimeTraceDesign.blue)
                                .background(.white, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("选择\(trigger.displayPlaceName)")
                    }
                }
            }
        }
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func centerMapForOverview() async {
        let currentLocation = try? await model.geofence.requestCurrentLocation()
        centerMapIncludingPlaces(currentLocation: currentLocation)
    }

    private func centerOnCurrentLocation() async {
        guard let currentLocation = try? await model.geofence.requestCurrentLocation() else { return }
        centerMap(on: currentLocation, distance: 1_500)
    }

    private func centerMapIncludingPlaces(currentLocation: CLLocationCoordinate2D?) {
        var coordinates = model.workTriggers.compactMap { trigger -> CLLocationCoordinate2D? in
            guard let latitude = trigger.latitude, let longitude = trigger.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        if let currentLocation { coordinates.append(currentLocation) }
        guard !coordinates.isEmpty else { return }

        let latitude = coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
        let longitude = coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let farthestDistance = coordinates
            .map { CLLocation(latitude: center.latitude, longitude: center.longitude).distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }
            .max() ?? 0
        centerMap(on: center, distance: max(1_500, farthestDistance * 2.8))
    }

    private func centerMap(on coordinate: CLLocationCoordinate2D, distance: CLLocationDistance) {
        mapPosition = .camera(
            MapCamera(
                centerCoordinate: ChinaMapCoordinateConverter.mapCoordinate(fromSystemCoordinate: coordinate),
                distance: distance
            )
        )
    }
}
