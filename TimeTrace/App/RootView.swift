import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: RootStore
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("--history-validation") ? "history" : "today"

    var body: some View {
        let state = store.state
        Group {
            if !state.isLoaded {
                ProgressView(state.isRestoringICloudData ? "正在从 iCloud 恢复数据…" : "正在读取本地数据…")
            } else if !state.isOnboarded {
                OnboardingView()
            } else {
                TabView(selection: $selectedTab) {
                    NavigationStack { TodayView() }
                        .tag("today")
                        .tabItem {
                            Image(systemName: "house.fill")
                            Text("今天")
                        }
                    NavigationStack { InsightsView() }
                        .tag("insights")
                        .tabItem {
                            Image(systemName: "chart.bar.fill")
                            Text("统计")
                        }
                    NavigationStack { PlacesView() }
                        .tag("places")
                        .tabItem {
                            Image(systemName: "mappin.and.ellipse")
                            Text("地点")
                        }
                    NavigationStack { HistoryView() }
                        .tag("history")
                        .tabItem {
                            Image(systemName: "calendar")
                            Text("历史")
                        }
                    NavigationStack { SettingsView() }
                        .tag("settings")
                        .tabItem {
                            Image(systemName: "person.crop.circle")
                            Text("设置")
                        }
                }
                .tint(TimeTraceDesign.blue)
                .background(TimeTraceDesign.canvas)
                .toolbarBackground(TimeTraceDesign.canvas, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
                .ignoresSafeArea(edges: [.top, .bottom])
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("出现问题", isPresented: Binding(
            get: { store.state.errorMessage != nil },
            set: { if !$0 { store.dismissError() } }
        )) {
            Button("好", role: .cancel) { store.dismissError() }
        } message: {
            Text(store.state.errorMessage ?? "未知错误")
        }
    }
}
