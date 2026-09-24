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

/// Capture the page once so later refreshes cannot change an open share.
struct InsightShareSnapshot: Identifiable {
    let id = UUID()
    let journal: TimeJournal
    let copy: PeriodInsightCopy?
    let overtime: InsightOvertimePresentation?
    let trend: JournalTrendSnapshot
}

struct JournalTrendSnapshot {
    let summary: PeriodActivitySummary
    let metric: TrendMetric
    let presentation: PlaceInsightPresentation
    let calendar: Calendar
    let now: Date
}

struct JournalSharePreview: View {
    @Environment(\.timeTraceDesign) private var design

    let journal: TimeJournal
    var insightCopy: PeriodInsightCopy? = nil
    var overtime: InsightOvertimePresentation? = nil
    var trend: JournalTrendSnapshot? = nil
    @State private var shareFile: JournalShareFile?
    @State private var error: String?
    @State private var rendering = false
    @State private var generatedFiles: [URL] = []
    @State private var previewData: Data?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let previewData, let image = UIImage(data: previewData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .accessibilityLabel("分享海报预览")
                    } else if error == nil {
                        ProgressView("正在生成预览…")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
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
            .navigationTitle("分享统计").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(item: $shareFile) { file in JournalActivitySheet(url: file.url) }
            .task {
                guard previewData == nil else { return }
                generatePreview()
            }
            .onDisappear {
                for url in generatedFiles { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    @MainActor private func generatePreview() {
        error = nil
        do {
            previewData = try JournalPosterRenderer.png(journal: journal, insightCopy: insightCopy,
                overtime: overtime, trend: trend, showPlaceName: false, theme: design.theme)
        } catch {
            self.error = "暂时无法生成图片，请重试。"
        }
    }

    @MainActor private func render() {
        rendering = true
        error = nil
        defer { rendering = false }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("时光落点手记-\(UUID().uuidString).png")
            if previewData == nil { generatePreview() }
            guard let previewData else { return }
            try previewData.write(to: url, options: .atomic)
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
    static let width: CGFloat = 360
    let journal: TimeJournal
    var insightCopy: PeriodInsightCopy? = nil
    var overtime: InsightOvertimePresentation? = nil
    var trend: JournalTrendSnapshot? = nil
    var showPlaceName = false
    var theme: AppTheme = .paper
    private var design: TimeTraceDesign { TimeTraceDesign(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("我的时间总结")
                    .font(.system(size: 23, weight: .semibold, design: .serif))
                    .foregroundStyle(design.ink)
                Spacer()
                Text("TimeTrace")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(design.muted)
            }

            Color.clear.frame(height: 18)

            PeriodInsightCard(journal: journal, copy: insightCopy, overtime: overtime,
                              showsEvidenceLink: false,
                              scopeLabel: showPlaceName ? journal.scope : journal.privateScope,
                              forSharing: true) {}
                .compositingGroup()
                .shadow(color: design.blue.opacity(0.08), radius: 16, x: 0, y: 8)

            if let trend {
                VStack(alignment: .leading, spacing: 12) {
                    Text("趋势 · \(trend.metric.title(for: trend.presentation))")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(design.ink)
                    PlaceTrendChart(summary: trend.summary, metric: trend.metric,
                                    presentation: trend.presentation, calendar: trend.calendar, now: trend.now)
                        .frame(height: 210)
                    if trend.summary.days.contains(where: \.isIncomplete) {
                        Label("橙色数据点表示记录不完整", systemImage: "circle.fill")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                .padding(16)
                .background(design.card, in: RoundedRectangle(cornerRadius: 24))
                .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(design.border.opacity(0.65)) }
                .padding(.top, 18)
            }

            Color.clear.frame(height: 18)

            HStack(alignment: .center, spacing: 14) {
                TimeTraceMark(size: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text("时光落点").font(.system(size: 17, weight: .semibold)).foregroundStyle(design.ink)
                    Text("记录日常，看见时间").font(.system(size: 10)).foregroundStyle(design.muted)
                }
                Spacer(minLength: 0)
                if let code = JournalDownloadCode.image {
                    Image(uiImage: code)
                        .interpolation(.none).resizable().frame(width: 60, height: 60)
                        .accessibilityLabel("时光落点 App Store 下载二维码")
                }
            }
            .padding(.top, 14)
            .overlay(alignment: .top) { Rectangle().fill(design.border).frame(height: 1) }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
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
    @MainActor static func write(journal: TimeJournal, insightCopy: PeriodInsightCopy? = nil,
                                 overtime: InsightOvertimePresentation? = nil,
                                 trend: JournalTrendSnapshot? = nil, showPlaceName: Bool,
                                 theme: AppTheme = .paper, to url: URL) throws {
        try png(journal: journal, insightCopy: insightCopy, overtime: overtime, trend: trend,
                showPlaceName: showPlaceName, theme: theme).write(to: url, options: .atomic)
    }
    @MainActor static func png(journal: TimeJournal, insightCopy: PeriodInsightCopy? = nil,
                               overtime: InsightOvertimePresentation? = nil,
                               trend: JournalTrendSnapshot? = nil, showPlaceName: Bool,
                               theme: AppTheme = .paper) throws -> Data {
        let renderer = ImageRenderer(content: JournalPoster(journal: journal,
            insightCopy: insightCopy, overtime: overtime, trend: trend,
            showPlaceName: showPlaceName, theme: theme))
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
    @ScaledMetric(relativeTo: .largeTitle) private var primaryNumberSize: CGFloat = 46
    @ScaledMetric(relativeTo: .title2) private var secondaryNumberSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title2) private var clockNumberSize: CGFloat = 27
    let journal: TimeJournal
    var copy: PeriodInsightCopy?
    var overtime: InsightOvertimePresentation? = nil
    var showsEvidenceLink = true
    var scopeLabel: String? = nil
    var forSharing = false
    var selectType: ((PlaceType) -> Void)? = nil
    var showEvidence: () -> Void

    var body: some View { content }

    private var content: some View {
        let values = Dictionary(uniqueKeysWithValues: journal.summaryMetrics.map { ($0.title, $0.value) })
        let hasWork = values["已工作"] != nil
        let hasHome = values["在家待了"] != nil || values["最晚到家"] != nil
        return VStack(alignment: .leading, spacing: forSharing ? 12 : 22) {
            Group {
                if dynamicTypeSize.isAccessibilitySize && !forSharing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(journal.dateLabel).foregroundStyle(design.muted)
                        Text(scopeLabel ?? journal.scope).foregroundStyle(design.blue)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(journal.dateLabel).foregroundStyle(design.muted)
                        Spacer(minLength: 0)
                        Text(scopeLabel ?? journal.scope)
                            .foregroundStyle(design.blue)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(design.blue.opacity(0.07), in: Capsule())
                    }
                }
            }
            .font(forSharing ? .system(size: 10, weight: .medium) : .caption.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)

            if journal.typeSummaries.count > 2 {
                typeOverview
            } else {
                if hasWork {
                    VStack(alignment: .leading, spacing: forSharing ? 12 : 16) {
                        columns {
                            durationMetric("已工作", value: values["已工作"]!, icon: "briefcase.fill", prominent: true)
                        } second: {
                            durationMetric("日均工作", value: values["平均每天工作"] ?? "—", prominent: false)
                        }
                        if let overtime { overtimeBlock(overtime) }
                        clockBand(first: "最晚下班", firstValue: values["最晚下班"],
                                  second: "平均下班", secondValue: values["平均下班"])
                    }
                }

                if hasHome {
                    if hasWork { rule }
                    VStack(alignment: .leading, spacing: forSharing ? 12 : 16) {
                        durationMetric("在家时长", value: values["在家待了"] ?? "记录中",
                                       icon: "house.fill", prominent: !hasWork)
                        clockBand(first: "最晚到家", firstValue: values["最晚到家"],
                                  second: "最早离家", secondValue: values["最早离家"])
                    }
                }

                let primaryTitles: Set<String> = ["已工作", "平均每天工作", "最晚下班", "平均下班", "在家待了", "最晚到家", "最早离家"]
                let otherMetrics = journal.summaryMetrics.filter { !primaryTitles.contains($0.title) }
                if !otherMetrics.isEmpty {
                    if hasWork || hasHome { rule }
                    ForEach(otherMetrics) { metric in
                        if metric.title == "记录摘要" {
                            Text(metric.value).font(.subheadline).foregroundStyle(design.muted)
                                .padding(.vertical, 12)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                durationMetric(metric.title, value: metric.value, prominent: !hasWork && !hasHome)
                                if let summary = journal.typeSummaries.first(where: { "\($0.type.displayName)时长" == metric.title }) {
                                    Text("\(summary.detailTitle) · \(summary.detailValue)")
                                        .font(forSharing ? .system(size: 11) : .caption)
                                        .foregroundStyle(design.muted)
                                }
                            }
                        }
                    }
                }

            }

            if let copy {
                VStack(alignment: .leading, spacing: 5) {
                    Text(copy.title).font(forSharing ? .system(size: 13, weight: .semibold) : .subheadline.weight(.semibold))
                        .foregroundStyle(design.ink)
                    Text(copy.body).font(forSharing ? .system(size: 12) : .caption)
                        .foregroundStyle(design.muted).lineSpacing(3)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if journal.unfinishedCount > 0 || showsEvidenceLink {
                Group {
                    if dynamicTypeSize.isAccessibilitySize && !forSharing {
                        VStack(alignment: .leading, spacing: 10) { footerContent }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 12) { footerContent }
                    }
                }
                .font(forSharing ? .system(size: 10) : .caption2)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(forSharing ? 16 : 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(design.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(design.border.opacity(0.65)) }
    }

    @ViewBuilder private var footerContent: some View {
        if journal.unfinishedCount > 0 {
            Text("进行中的时长尚未计入").foregroundStyle(design.muted)
        }
        if !dynamicTypeSize.isAccessibilitySize || forSharing { Spacer(minLength: 0) }
        if showsEvidenceLink && (journal.summaryEvidence != nil || journal.mainFinding != nil) {
            Button(action: showEvidence) {
                HStack(spacing: 4) {
                    Text("查看记录")
                    Image(systemName: "arrow.up.right")
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(design.blue)
        }
    }

    private var typeOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !forSharing && selectType != nil {
                Text("点选类型，查看完整总结")
                    .font(.caption).foregroundStyle(design.muted)
            }
            let count = forSharing ? 3 : dynamicTypeSize.isAccessibilitySize ? 1 : 2
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: count),
                      alignment: .leading, spacing: 8) {
                ForEach(journal.typeSummaries) { summary in
                    if let selectType, !forSharing {
                        Button { selectType(summary.type) } label: { overviewTile(summary) }
                            .buttonStyle(.plain)
                            .accessibilityHint("查看完整总结")
                    } else {
                        overviewTile(summary)
                    }
                }
            }
        }
    }

    private func overviewTile(_ summary: JournalTypeSummary) -> some View {
        VStack(alignment: .leading, spacing: forSharing ? 7 : 10) {
            Label(summary.type.displayName, systemImage: summary.type.systemImage)
                .font(forSharing ? .system(size: 10, weight: .medium) : .caption.weight(.medium))
                .foregroundStyle(design.blue)
            (
                Text(summary.number)
                    .font(.system(size: forSharing ? 23 : secondaryNumberSize, weight: .semibold, design: .rounded))
                    .foregroundColor(design.ink)
                + Text(" " + summary.unit)
                    .font(forSharing ? .system(size: 9) : .caption)
                    .foregroundColor(design.muted)
            )
            .lineLimit(1).minimumScaleFactor(0.7)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.detailTitle).foregroundStyle(design.muted)
                Text(summary.detailValue).foregroundStyle(design.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(forSharing ? .system(size: 9) : .caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(forSharing ? 8 : 12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(design.canvas, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.type.displayName)，\(summary.durationDescription)，\(summary.detailTitle)\(summary.detailValue)")
    }

    private var rule: some View {
        Rectangle().fill(design.border.opacity(0.65)).frame(height: 1)
    }

    private func overtimeBlock(_ overtime: InsightOvertimePresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(overtime.title, systemImage: "clock.badge.exclamationmark")
                .font(forSharing ? .system(size: 10, weight: .medium) : .caption.weight(.medium))
                .foregroundStyle(.orange)
            Spacer(minLength: 8)
            durationText(overtime.value, prominent: false)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(forSharing ? 10 : 12)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(overtime.title + overtime.value)
    }

    @ViewBuilder private func columns<First: View, Second: View>(
        @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize && !forSharing {
            VStack(alignment: .leading, spacing: 18) { first(); second() }
        } else {
            HStack(alignment: .bottom, spacing: 14) {
                first().frame(maxWidth: .infinity, alignment: .leading)
                second().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func durationMetric(_ title: String, value: String, icon: String? = nil, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: forSharing ? 5 : 7) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).foregroundStyle(design.blue) }
                Text(title)
            }
            .font(forSharing ? .system(size: 11, weight: .medium) : .caption.weight(.medium))
            .foregroundStyle(design.muted)
            durationText(value, prominent: prominent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(title + value)
        }
    }

    private func durationText(_ value: String, prominent: Bool) -> Text {
        let size: CGFloat = prominent ? (forSharing ? 40 : primaryNumberSize) : (forSharing ? 24 : secondaryNumberSize)
        return value.split(separator: " ").reduce(Text("")) { text, part in
            if Int(part) != nil {
                return text + Text(String(part))
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .foregroundColor(design.ink)
            }
            return text + Text(" " + String(part) + " ")
                .font(forSharing ? .system(size: 11) : .caption)
                .foregroundColor(design.muted)
        }
    }

    private func clockBand(first: String, firstValue: String?, second: String, secondValue: String?) -> some View {
        columns {
            clockMetric(first, value: firstValue)
        } second: {
            clockMetric(second, value: secondValue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(forSharing ? 10 : 14)
        .background(design.canvas, in: RoundedRectangle(cornerRadius: 14))
    }

    private func clockMetric(_ title: String, value: String?) -> some View {
        let parts = value?.split(separator: " ").map(String.init) ?? []
        let time = parts.last ?? "—"
        let context = parts.dropLast().joined(separator: " ")
        return VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(forSharing ? .system(size: 10) : .caption)
                .foregroundStyle(design.muted)
            Text(time)
                .font(.system(size: forSharing ? 23 : clockNumberSize, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(design.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(context.isEmpty ? (value == nil ? "暂无完整记录" : "当天") : context)
                .font(forSharing ? .system(size: 10) : .caption2)
                .foregroundStyle(design.blue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + (value ?? "暂无完整记录"))
    }
}
