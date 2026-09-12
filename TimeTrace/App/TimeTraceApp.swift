import SwiftUI

@main
struct TimeTraceApp: App {
    @AppStorage("appTheme") private var themeName = AppTheme.paper.rawValue
    @AppStorage("appAppearance") private var appearanceName = AppAppearance.system.rawValue
    private var design: TimeTraceDesign { TimeTraceDesign(theme: AppTheme(rawValue: themeName) ?? .paper) }

    @StateObject private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                design.canvas.ignoresSafeArea()
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
            .environment(\.timeTraceDesign, design)
            .tint(design.blue)
            .preferredColorScheme((AppAppearance(rawValue: appearanceName) ?? .system).colorScheme)
            .task {
                container.root.loadIfNeeded()
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--history-validation") ||
                    ProcessInfo.processInfo.arguments.contains("--insights-validation") {
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
