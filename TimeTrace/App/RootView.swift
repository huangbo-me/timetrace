import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: RootStore
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("--history-validation") ? "history" : "today"

    var body: some View {
        let state = store.state
        Group {
            if state.needsInitialCloudRestoreDecision {
                InitialCloudRestoreDecisionView(
                    onRestore: { store.retryInitialCloudRestore() },
                    onStartNew: { store.startNewRecordAfterSkippingCloudRestore() }
                )
            } else if !state.isLoaded {
                ProgressView(state.isRestoringICloudData ? "正在从 iCloud 恢复数据…" : "正在准备数据…")
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

private struct InitialCloudRestoreDecisionView: View {
    let onRestore: () -> Void
    let onStartNew: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            TimeTraceMark(size: 58)
            VStack(spacing: 8) {
                Text("恢复已有数据？")
                    .font(.title2.weight(.bold))
                Text("已接入 iCloud。你可以恢复已有的时迹数据，也可以开启新记录。")
                    .font(.subheadline)
                    .foregroundStyle(TimeTraceDesign.muted)
                    .multilineTextAlignment(.center)
            }

            TTCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("恢复会带回地点、围栏设置、记录和提醒", systemImage: "icloud.and.arrow.down")
                        .font(.subheadline.weight(.medium))
                    Text("网络较慢时，恢复可能需要更长时间。")
                        .font(.caption)
                        .foregroundStyle(TimeTraceDesign.muted)
                }
            }

            VStack(spacing: 12) {
                Button(action: onRestore) {
                    Label("从 iCloud 恢复", systemImage: "arrow.clockwise.icloud")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(TimeTraceDesign.blue)

                Button(action: onStartNew) {
                    Text("开启新记录")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(TimeTraceDesign.ink)
            }

            Text("开始新记录不会删除 iCloud 数据；若旧数据稍后抵达，会自动合并回来。")
                .font(.caption)
                .foregroundStyle(TimeTraceDesign.muted)
            Spacer()
        }
        .padding(.horizontal, 28)
        .timeTraceScreen()
    }
}
