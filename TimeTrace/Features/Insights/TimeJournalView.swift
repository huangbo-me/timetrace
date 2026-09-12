import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

struct JournalFindingDetail: View {
    let finding: JournalFinding
    let calendar: Calendar
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section { Text(finding.detail).foregroundStyle(.secondary) }
                Section("作为依据的记录") {
                    ForEach(finding.records.sorted { $0.start > $1.start }) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.placeName).font(.headline)
                            Text(date(record.start) + " — " + (record.end.map(date) ?? "尚未结束"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(record.duration.map(TimeJournalService.duration) ?? "未计入时长")
                                .font(.subheadline)
                        }.padding(.vertical, 4)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .timeTraceScreen()
            .navigationTitle(finding.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
    private func date(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = TimeTraceLocalization.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: value)
    }
}

struct JournalSharePreview: View {
    @Environment(\.timeTraceDesign) private var design

    let journal: TimeJournal
    var insightCopy: PeriodInsightCopy? = nil
    @State private var showPlaceName = false
    @State private var shareFile: JournalShareFile?
    @State private var error: String?
    @State private var rendering = false
    @State private var generatedFiles: [URL] = []
    @State private var didGenerate = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Display the actual fixed-size composition, scaled without reflowing text.
                    GeometryReader { geometry in
                        poster
                            .scaleEffect(geometry.size.width / JournalPoster.size.width, anchor: .topLeading)
                    }
                    .aspectRatio(JournalPoster.size.width / JournalPoster.size.height, contentMode: .fit)
                    .accessibilityLabel("分享海报预览")
                    Toggle("显示地点名称", isOn: $showPlaceName)
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Button(action: render) {
                        Label(rendering ? "正在生成…" : (error == nil ? "分享图片" : "重试生成图片"),
                              systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(design.onAccent).tint(design.violet)
                    .disabled(rendering)
                }.padding(20)
            }
            .navigationTitle("分享手记").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(item: $shareFile) { file in JournalActivitySheet(url: file.url) }
            .task {
                guard !didGenerate else { return }
                didGenerate = true
                render()
            }
            .onDisappear {
                for url in generatedFiles { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    private var poster: some View {
        JournalPoster(journal: journal, insightCopy: insightCopy, showPlaceName: showPlaceName, theme: design.theme)
    }

    @MainActor private func render() {
        rendering = true
        error = nil
        defer { rendering = false }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("时迹手记-\(UUID().uuidString).png")
            try JournalPosterRenderer.write(journal: journal, insightCopy: insightCopy, showPlaceName: showPlaceName, theme: design.theme, to: url)
            generatedFiles.append(url)
            shareFile = JournalShareFile(url: url)
        } catch {
            self.error = "暂时无法生成或保存图片，请重试。"
        }
    }
}

private struct JournalShareFile: Identifiable {
    let url: URL
    var id: URL { url }
}
private struct JournalActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Fixed typography makes the exported PNG identical to the scaled preview.
struct JournalPoster: View {
    static let size = CGSize(width: 360, height: 640)
    let journal: TimeJournal
    var insightCopy: PeriodInsightCopy? = nil
    var showPlaceName = false
    var theme: AppTheme = .paper
    private var design: TimeTraceDesign { TimeTraceDesign(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Capsule().fill(design.blue).frame(width: 16, height: 3)
                    Text("一份来自日常的时间手记").tracking(2)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(design.muted)
                Text("时间花在哪，\n生活就写在哪。")
                    .font(.system(size: 27, weight: .semibold, design: .serif))
                    .lineSpacing(5)
                    .foregroundStyle(design.ink)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 24)

            PeriodInsightCard(journal: journal, copy: insightCopy, showsEvidenceLink: false,
                              scopeLabel: showPlaceName ? journal.scope : journal.privateScope,
                              forSharing: true) {}
                .shadow(color: design.blue.opacity(0.08), radius: 16, x: 0, y: 8)

            Spacer(minLength: 24)

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        TimeTraceMark(size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("时迹").font(.system(size: 19, weight: .semibold))
                            Text("TimeTrace").font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(design.ink)
                    }
                    Text("自动记录地点停留\n看见时间如何分配")
                        .font(.system(size: 11))
                        .lineSpacing(3)
                        .foregroundStyle(design.muted)
                    Text("把你的日常，也记录下来")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(design.blue)
                }
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    if let code = JournalDownloadCode.image {
                        Image(uiImage: code)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 84, height: 84)
                            .accessibilityLabel("时迹 App Store 下载二维码")
                    }
                    Text("扫码下载 · iPhone")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(design.muted)
                }
            }
            .padding(.top, 16)
            .overlay(alignment: .top) { Rectangle().fill(design.border).frame(height: 1) }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 48)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(design.canvas)
        .environment(\.timeTraceDesign, design)
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .medium)
    }
}

/// One destination for every theme; the QR code contains no user or journal data.
enum JournalDownloadCode {
    static let url = "https://apps.apple.com/us/app/%E6%97%B6%E8%BF%B9-%E8%87%AA%E5%8A%A8%E8%AE%B0%E5%BD%95%E6%97%B6%E9%97%B4%E8%BD%A8%E8%BF%B9/id6808740130"
    static let image: UIImage? = {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        // Four white modules on every edge keep the code readable on every theme.
        let extent = code.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: .white).cropped(to: extent)
        let padded = code.composited(over: white).cropped(to: extent)
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let bitmap = CIContext().createCGImage(padded, from: padded.extent) else { return nil }
        return UIImage(cgImage: bitmap)
    }()
}

enum JournalPosterRenderer {
    enum RenderError: Error { case unavailable }
    @MainActor static func write(journal: TimeJournal, insightCopy: PeriodInsightCopy? = nil, showPlaceName: Bool, theme: AppTheme = .paper, to url: URL) throws {
        try png(journal: journal, insightCopy: insightCopy,
                showPlaceName: showPlaceName, theme: theme).write(to: url, options: .atomic)
    }
    @MainActor static func png(journal: TimeJournal, insightCopy: PeriodInsightCopy? = nil, showPlaceName: Bool, theme: AppTheme = .paper) throws -> Data {
        let renderer = ImageRenderer(content: JournalPoster(journal: journal,
            insightCopy: insightCopy, showPlaceName: showPlaceName, theme: theme))
        renderer.scale = 3
        renderer.isOpaque = true
        // Use a fresh bitmap context for each export, including repeated privacy/theme changes.
        var data: Data?
        renderer.render { size, draw in
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                // ImageRenderer draws in Core Graphics coordinates; UIKit's context is flipped.
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                draw(context.cgContext)
            }
        }
        guard let data else { throw RenderError.unavailable }
        return data
    }
}


struct DailyCareCard: View {
    @Environment(\.timeTraceDesign) private var design

    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("今日小 tip", systemImage: "sun.max")
                .font(.caption.weight(.medium))
                .foregroundStyle(design.muted)
            Text(text)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(design.ink)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

struct PeriodInsightCard: View {
    @Environment(\.timeTraceDesign) private var design
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let journal: TimeJournal
    var copy: PeriodInsightCopy?
    var showsEvidenceLink = true
    var scopeLabel: String? = nil
    var forSharing = false
    var showEvidence: () -> Void

    var body: some View {
        if showsEvidenceLink && journal.mainFinding != nil {
            Button(action: showEvidence) { content }
                .buttonStyle(.plain)
                .accessibilityHint("查看这条洞见对应的时间记录")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: forSharing ? 14 : 20) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(scopeLabel ?? "时间里的发现")
                        Text(journal.dateLabel)
                    }
                } else {
                    HStack(alignment: .top) {
                        Text(journal.dateLabel)
                        Spacer()
                        Text(scopeLabel ?? "时间里的发现")
                            .lineLimit(forSharing ? 2 : nil)
                    }
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(design.muted)
            .fixedSize(horizontal: false, vertical: true)

            Capsule().fill(design.blue).frame(width: 28, height: 3)
            VStack(alignment: .leading, spacing: 12) {
                Text(copy?.title ?? journal.insightTitle)
                    .font(forSharing ? .system(size: 20, weight: .semibold, design: .serif) : .system(.title2, design: .serif, weight: .semibold))
                    .foregroundStyle(design.ink)
                Text(copy?.body ?? journal.insightBody)
                    .font(forSharing ? .system(size: 14) : .subheadline)
                    .foregroundStyle(design.muted)
                    .lineSpacing(4)
            }
            .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { metrics }
                VStack(alignment: .leading, spacing: 8) { metrics }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(design.blue)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(design.card, in: RoundedRectangle(cornerRadius: 14))

            if journal.unfinishedCount > 0 {
                Text("还有 \(journal.unfinishedCount) 段待结束，时长仅计已完成记录")
                    .font(.caption).foregroundStyle(design.muted)
            }
            if showsEvidenceLink && journal.mainFinding != nil {
                Label("看看这些记录", systemImage: "arrow.up.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(design.blue)
            }
        }
        .padding(forSharing ? 18 : 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [design.canvas, design.card], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(design.blue.opacity(0.18)) }
    }

    @ViewBuilder private var metrics: some View {
        Text("已完成 \(TimeJournalService.duration(journal.totalDuration))")
        Text("\(journal.recordedDays) 天 · \(journal.recordCount) 段记录")
    }
}
