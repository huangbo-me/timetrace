import SwiftUI

@main
struct TimeTraceApp: App {
    @StateObject private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                TimeTraceDesign.canvas.ignoresSafeArea()
                RootView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
            .environmentObject(container.root)
            .environmentObject(container.onboarding)
            .environmentObject(container.today)
            .environmentObject(container.insights)
            .environmentObject(container.places)
            .environmentObject(container.history)
            .environmentObject(container.settings)
            .environment(\.locale, TimeTraceLocalization.locale)
            .task {
                container.root.loadIfNeeded()
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--history-validation") {
                    _ = container.application.generateThirtyDayDemoData()
                }
#endif
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                container.root.becameActive()
            }
        }
    }
}
