import SwiftUI
import UniformTypeIdentifiers

private struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw BackupError.invalidFile }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct DataBackupView: View {
    @EnvironmentObject private var store: SettingsFeatureStore
    @State private var showingICloudHelp = false
    @State private var passwordOperation: BackupPasswordOperation?
    @State private var exporting = false
    @State private var importing = false
    @State private var busy = false
    @State private var document: BackupDocument?
    @State private var pendingSnapshot: BackupSnapshot?
    @State private var showingImportConfirmation = false
    @State private var resultMessage: String?
    private var model: AppModel { store.application }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
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

                TTCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("同步范围")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(iCloudScopeStatus)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(iCloudScopeTint)
                        }
                        Text(iCloudScopeExplanation)
                            .font(.caption)
                            .foregroundStyle(TimeTraceDesign.muted)

                        Divider()
                        iCloudScopeRow(
                            title: "活动与地点",
                            detail: "\(model.activities.count) 个活动 · \(model.triggers.filter { $0.type == .geofence }.count) 个地点\n名称、围栏位置、半径和自动记录设置",
                            systemImage: "mappin.and.ellipse"
                        )
                        Divider()
                        iCloudScopeRow(
                            title: "时间记录",
                            detail: "\(model.sessions.count) 段会话 · \(model.events.count) 条事件\n到达、离开、手动补齐和汇总依据",
                            systemImage: "clock.arrow.circlepath"
                        )
                        Divider()
                        iCloudScopeRow(
                            title: "提醒",
                            detail: "提醒名称、时间、重复日期、启停状态与执行记录",
                            systemImage: "bell.badge"
                        )
                    }
                }


                TTSectionTitle(title: "文件备份")
                TTCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("导出活动、地点、时间记录和提醒，保存到“文件”或 iCloud 云盘。导入按标识合并并保留本机版本；新增事件可能更新汇总记录。")
                            .font(.subheadline).foregroundStyle(TimeTraceDesign.muted)
                        Text("文件使用密码加密。请妥善保存密码，忘记后无法恢复备份。本机昵称和系统权限不包含在文件中。")
                            .font(.caption).foregroundStyle(TimeTraceDesign.muted)
                        Divider()
                        Button {
                            document = nil
                            pendingSnapshot = nil
                            passwordOperation = .export
                        } label: {
                            Label("导出加密备份", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .disabled(busy)
                        Divider()
                        Button {
                            document = nil
                            pendingSnapshot = nil
                            importing = true
                        } label: {
                            Label("导入备份", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .disabled(busy)
                        if busy { ProgressView("正在处理备份…") }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 28)
        }
        .timeTraceScreen()
        .navigationTitle("数据备份")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refreshICloudSyncStatus() }
        .alert("开启 iCloud 同步", isPresented: $showingICloudHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请前往“设置”> 您的姓名 > iCloud > 已存储到 iCloud，找到“时迹”并开启同步。开启后请完全退出并重新打开时迹，应用才会重新检查现有数据库的 iCloud 配置。")
        }

        .fileExporter(isPresented: $exporting, document: document, contentType: .data,
                      defaultFilename: "时迹备份-\(Date().formatted(.iso8601.year().month().day())).timetrace") { result in
            document = nil
            switch result {
            case .success:
                resultMessage = "加密备份已导出。"
            case .failure(let error): resultMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): passwordOperation = .importFile(url)
            case .failure(let error): resultMessage = error.localizedDescription
            }
        }
        .sheet(item: $passwordOperation, onDismiss: {
            // Present the next system dialog only after the password sheet closes.
            if document != nil { exporting = true }
            if pendingSnapshot != nil { showingImportConfirmation = true }
        }) { operation in
            BackupPasswordView(isExport: operation.isExport) { secret in
                switch operation {
                case .export: try await exportBackup(password: secret)
                case .importFile(let url): try await readBackup(url, password: secret)
                }
            }
        }
        .alert("合并备份数据？", isPresented: $showingImportConfirmation) {
            Button("导入并合并") { mergeBackup() }
            Button("取消", role: .cancel) { pendingSnapshot = nil }
        } message: {
            if let snapshot = pendingSnapshot {
                Text("备份包含 \(snapshot.activities.count) 个活动、\(snapshot.triggers.count) 个触发设置、\(snapshot.sessions.count) 段会话、\(snapshot.events.count) 条事件，以及提醒和辅助记录。已有记录保留本机版本，其余新增。")
            }
        }
        .alert("数据备份", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("好", role: .cancel) { resultMessage = nil }
        } message: { Text(resultMessage ?? "") }
    }

    @MainActor
    private func exportBackup(password: String) async throws {
        busy = true
        defer { busy = false }
        let snapshot = try model.backupSnapshot()
        let data = try await Task.detached(priority: .userInitiated) {
            try BackupArchive.encrypt(snapshot, password: password)
        }.value
        document = BackupDocument(data: data)
    }

    @MainActor
    private func readBackup(_ url: URL, password: String) async throws {
        busy = true
        defer { busy = false }
        pendingSnapshot = try await Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 100 * 1_024 * 1_024 else { throw BackupError.invalidFile }
            return try BackupArchive.decrypt(Data(contentsOf: url), password: password)
        }.value
    }

    private func mergeBackup() {
        guard let snapshot = pendingSnapshot else { return }
        defer { pendingSnapshot = nil }
        do {
            let result = try model.importBackup(snapshot)
            let count = result.insertedCount
            resultMessage = "导入完成：新增 \(count) 条数据，跳过 \(snapshot.count - count) 条已有数据。本机原有数据已保留。"
            if let warning = result.refreshWarning { resultMessage = (resultMessage ?? "") + "\n" + warning }
        } catch { resultMessage = error.localizedDescription }
    }

    private var iCloudScopeStatus: String {
        switch model.iCloudSyncStatus {
        case .enabled: "已纳入 iCloud"
        case .checking: "正在确认"
        case .unavailable: "等待 iCloud"
        case .notEnabled, .signedOut, .restricted: "仅本机"
        }
    }

    private var iCloudScopeTint: Color {
        switch model.iCloudSyncStatus {
        case .enabled: .green
        case .checking, .unavailable: TimeTraceDesign.blue
        case .notEnabled, .signedOut, .restricted: TimeTraceDesign.muted
        }
    }

    private var iCloudScopeExplanation: String {
        switch model.iCloudSyncStatus {
        case .enabled:
            return "已纳入 iCloud 表示此类数据会同步；实际上传和下载时间取决于网络及系统状态。"
        case .checking:
            return "正在确认这台设备能否使用 iCloud；确认完成前不会把数据误标为已同步。"
        case .unavailable:
            return "iCloud 暂时不可用；数据先保留在本机。恢复可用后请重新检查状态；若未启用同步，请重新启动应用。"
        case .notEnabled:
            return "当前使用本机存储。请确认已登录 iCloud，并重新启动应用以重新检查同步配置。"
        case .signedOut, .restricted:
            return "当前无法使用 iCloud。请恢复账户权限后重新启动应用，以重新检查同步配置。"
        }
    }

    private func iCloudScopeRow(title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            TTIcon(systemName: systemImage, tint: TimeTraceDesign.blue, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(TimeTraceDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(iCloudScopeStatus)
                .font(.caption.weight(.medium))
                .foregroundStyle(iCloudScopeTint)
                .multilineTextAlignment(.trailing)
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

}

private enum BackupPasswordOperation: Identifiable {
    case export
    case importFile(URL)

    var id: String {
        switch self {
        case .export: "export"
        case .importFile(let url): "import-" + url.absoluteString
        }
    }

    var isExport: Bool {
        if case .export = self { return true }
        return false
    }
}

private struct BackupPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @FocusState private var passwordFocused: Bool
    let isExport: Bool
    let onSubmit: @MainActor (String) async throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(isExport ? "设置备份密码（至少 8 个字符）" : "输入备份密码", text: $password)
                        .focused($passwordFocused)
                        .disabled(isProcessing)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                } footer: {
                    Text(isExport ? "请保存好密码，导入此备份时需要输入。" : "请输入导出此文件时设置的密码。")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                if isProcessing { ProgressView(isExport ? "正在加密…" : "正在解密…") }
            }
            .navigationTitle(isExport ? "设置导出密码" : "输入导入密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { password = ""; dismiss() }
                        .disabled(isProcessing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isExport ? "导出" : "解密") { submit() }
                        .disabled(!canSubmit)
                }
            }
            .onAppear { passwordFocused = true }
        }
        .interactiveDismissDisabled(isProcessing)
    }

    private var canSubmit: Bool {
        !isProcessing && (isExport ? password.count >= 8 : !password.isEmpty)
    }

    private func submit() {
        guard canSubmit else { return }
        isProcessing = true
        errorMessage = nil
        Task { @MainActor in
            defer { isProcessing = false }
            do {
                try await onSubmit(password)
                password = ""
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                password = ""
                passwordFocused = true
            }
        }
    }
}
