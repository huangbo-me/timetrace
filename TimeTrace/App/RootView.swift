import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("--history-validation") ? "history" : "today"

    var body: some View {
        Group {
            if !model.isLoaded {
                ProgressView(model.isRestoringICloudData ? "正在从 iCloud 恢复数据…" : "正在读取本地数据…")
            } else if !model.isOnboarded {
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
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("好", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "未知错误")
        }
    }
}
