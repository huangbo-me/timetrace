import SwiftUI

@main
struct TimeTraceApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                TimeTraceDesign.canvas.ignoresSafeArea()
                RootView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
            .environmentObject(model)
            .environment(\.locale, TimeTraceLocalization.locale)
            .task {
                if !model.isLoaded { model.load() }
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--history-validation") {
                    _ = model.generateThirtyDayDemoData()
                }
#endif
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                model.refreshSyncedData()
                model.refreshICloudSyncStatus()
            }
        }
    }
}
