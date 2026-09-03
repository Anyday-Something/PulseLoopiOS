import Charts
import HealthKit
import SwiftUI

/// One day of Apple Health across every source — the Apple Watch, PulseLoop's own export, any other
/// ring app — drawn on top of each other. Tap a source in a legend to bring it to the front (the others
/// fade); green marks where sources agree, each source keeps its own colour where they differ.
///
/// Read-only over HealthKit. It shows PulseLoop's *exported* data, so a ring metric that is not exported
/// (or not yet exported) is absent here by design.
struct CompareSourcesView: View {
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var heartRate: [SourcedHeartRate] = []
    @State private var sleep: [SourcedSleep] = []
    @State private var spo2: [SourcedSpO2] = []
    @State private var loading = false
    @State private var error: String?
    @State private var hrFocus: String?
    @State private var sleepFocus: String?
    @State private var spo2Focus: String?
    @State private var connecting = false

    private let reader = HealthSourceReader()
    private let calendar = Calendar.current
    private var service: HealthSyncService { .shared }

    private var dayEnd: Date { calendar.date(byAdding: .day, value: 1, to: day) ?? day }
    /// Sleep is shown for the night that ended on `day`: previous noon to this noon.
    private var nightStart: Date { calendar.date(byAdding: .hour, value: -12, to: day) ?? day }
    private var nightEnd: Date { calendar.date(byAdding: .hour, value: 12, to: day) ?? day }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                dayHeader
                if service.authState == .notDetermined || service.authState == .denied {
                    connectCard
                }
                heartRateCard
                sleepCard
                spo2Card
                if let error {
                    PulseCard {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(PulseFont.caption)
                            .foregroundStyle(PulseColors.warning)
                    }
                }
                Text("Green = sources agree (heart rate within \(Int(SourceComparison.heartRateToleranceBpm)) bpm "
                     + "in the same 5-minute bin; same sleep stage in the same minute). Tap a source to focus it.")
                    .font(PulseFont.caption2)
                    .foregroundStyle(PulseColors.textMuted)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, PulseLayout.floatingBottomInset)
        }
        .background(PulseColors.background.ignoresSafeArea())
        .navigationTitle("Compare sources")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: day) { await load() }
        .refreshable { await load() }
    }

    // MARK: Header

    private var dayHeader: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").font(PulseFont.headline) }
            Spacer()
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.wide)))
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.textMuted)
                Text(day.formatted(date: .long, time: .omitted))
                    .font(PulseFont.title3)
                    .foregroundStyle(PulseColors.textPrimary)
            }
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right").font(PulseFont.headline) }
                .disabled(dayEnd > Date())
            if loading { ProgressView().controlSize(.small).padding(.leading, 6) }
        }
        .foregroundStyle(PulseColors.accent)
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private var connectCard: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Apple Health access")
                    .font(PulseFont.headline)
                    .foregroundStyle(PulseColors.textPrimary)
                Text("Reading other sources (like the Apple Watch) needs Health read access for heart rate, sleep "
                     + "and blood oxygen. Without it only PulseLoop's own export is visible.")
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.textSecondary)
                QuickActionButton(label: connecting ? "Connecting…" : "Connect Apple Health", accent: true) {
                    connecting = true
                    Task {
                        try? await service.requestAuthorization()
                        connecting = false
                        await load()
                    }
                }
                .disabled(connecting)
            }
        }
    }

    // MARK: Heart rate

    private var hrSources: [String] { SourceComparison.orderedSources(heartRate.map(\.source)) }
    private var hrBins: [SourceComparison.HeartRateBin] { SourceComparison.bins(heartRate) }
    private var hrAgree: [SourceComparison.HeartRateAgreement] { SourceComparison.agreements(hrBins) }

    private var heartRateCard: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("Heart rate", color: PulseColors.heartRate)
                if heartRate.isEmpty {
                    emptyRow("No heart-rate samples for this day.")
                } else {
                    Chart {
                        ForEach(hrSources, id: \.self) { source in
                            let color = CompareColors.source(source, in: hrSources)
                            let faded = hrFocus != nil && hrFocus != source
                            ForEach(hrBins.filter { $0.values[source] != nil }) { bin in
                                LineMark(x: .value("Time", bin.date), y: .value("bpm", bin.values[source] ?? 0),
                                         series: .value("Source", source))
                                    .foregroundStyle(color)
                                    .opacity(faded ? 0.18 : 1)
                                    .lineStyle(StrokeStyle(lineWidth: faded ? 1.5 : 2.2))
                                    .interpolationMethod(.monotone)
                            }
                        }
                        ForEach(hrAgree) { a in
                            PointMark(x: .value("Time", a.date), y: .value("bpm", a.bpm))
                                .foregroundStyle(CompareColors.agree)
                                .symbolSize(70)
                        }
                    }
                    .chartXScale(domain: day...dayEnd)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) }
                    }
                    .chartLegend(.hidden)
                    .frame(height: 230)
                    SourceLegendChips(sources: hrSources, selected: $hrFocus)
                    statsRows(hrStats)
                }
            }
        }
    }

    private var hrStats: [(String, String)] {
        hrSources.map { s in
            let v = heartRate.filter { $0.source == s }.map(\.bpm)
            let avg = v.reduce(0, +) / Double(max(1, v.count))
            return (s, "\(v.count) samples · \(Int(v.min() ?? 0))–\(Int(v.max() ?? 0)) · avg \(Int(avg))")
        }
    }

    // MARK: Sleep

    private var sleepSources: [String] { SourceComparison.orderedSources(sleep.map(\.source)) }
    private var sleepStages: [SourcedSleep] { sleep.filter { $0.value != .inBed } }
    private var sleepAgree: [SourceComparison.SleepAgreementBlock] {
        SourceComparison.sleepAgreement(sleep, from: nightStart, to: nightEnd)
    }
    private static let agreeRow = "◆ agree"

    private var sleepCard: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    cardTitle("Sleep", color: PulseColors.sleep)
                    Spacer()
                    Text("night to \(day.formatted(.dateTime.weekday(.abbreviated)))")
                        .font(PulseFont.caption2)
                        .foregroundStyle(PulseColors.textMuted)
                }
                if sleep.isEmpty {
                    emptyRow("No sleep samples for this night.")
                } else {
                    let rows = (sleepSources.count >= 2 ? [Self.agreeRow] : []) + sleepSources
                    Chart {
                        ForEach(sleepStages) { s in
                            let faded = sleepFocus != nil && sleepFocus != s.source
                            RectangleMark(xStart: .value("Start", s.start), xEnd: .value("End", s.end), y: .value("Row", s.source))
                                .foregroundStyle(CompareColors.stage(s.stageLabel))
                                .opacity(faded ? 0.18 : 0.95)
                        }
                        ForEach(sleepAgree) { a in
                            RectangleMark(xStart: .value("Start", a.start), xEnd: .value("End", a.end), y: .value("Row", Self.agreeRow))
                                .foregroundStyle(CompareColors.agree)
                        }
                    }
                    .chartYScale(domain: rows)
                    .chartXScale(domain: nightStart...nightEnd)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 3)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisValueLabel { Text(value.as(String.self) ?? "").font(PulseFont.caption2).lineLimit(1) }
                        }
                    }
                    .chartLegend(.hidden)
                    .frame(height: CGFloat(34 * rows.count + 50))
                    SourceLegendChips(sources: sleepSources, selected: $sleepFocus)
                    stageLegend
                    statsRows(sleepStats)
                }
            }
        }
    }

    private var stageLegend: some View {
        HStack(spacing: 10) {
            ForEach(["Deep", "Core", "REM", "Awake"], id: \.self) { label in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(CompareColors.stage(label)).frame(width: 10, height: 10)
                    Text(label).font(PulseFont.caption2).foregroundStyle(PulseColors.textMuted)
                }
            }
        }
    }

    private var sleepStats: [(String, String)] {
        sleepSources.map { source in
            let samples = sleep.filter { $0.source == source }
            func total(_ f: (SourcedSleep) -> Bool) -> Int { Int(samples.filter(f).map(\.minutes).reduce(0, +)) }
            func fmt(_ m: Int) -> String { "\(m / 60)h\(String(format: "%02d", m % 60))" }
            var parts = ["asleep \(fmt(total { $0.isAsleep }))"]
            let deep = total { $0.value == .asleepDeep }, rem = total { $0.value == .asleepREM }, awake = total { $0.value == .awake }
            if deep > 0 { parts.append("deep \(fmt(deep))") }
            if rem > 0 { parts.append("REM \(fmt(rem))") }
            if awake > 0 { parts.append("awake \(fmt(awake))") }
            if let a = samples.map(\.start).min(), let b = samples.map(\.end).max() {
                parts.append("\(a.formatted(date: .omitted, time: .shortened))–\(b.formatted(date: .omitted, time: .shortened))")
            }
            return (source, parts.joined(separator: " · "))
        }
    }

    // MARK: SpO2

    private var spo2Sources: [String] { SourceComparison.orderedSources(spo2.map(\.source)) }

    private var spo2Card: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("Blood oxygen", color: PulseColors.spo2)
                if spo2.isEmpty {
                    emptyRow("No SpO₂ samples for this day.")
                } else {
                    Chart(spo2) { s in
                        let faded = spo2Focus != nil && spo2Focus != s.source
                        PointMark(x: .value("Time", s.date), y: .value("%", s.percent))
                            .foregroundStyle(CompareColors.source(s.source, in: spo2Sources))
                            .opacity(faded ? 0.18 : 1)
                    }
                    .chartXScale(domain: day...dayEnd)
                    .chartYScale(domain: 85...100)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) }
                    }
                    .chartLegend(.hidden)
                    .frame(height: 170)
                    SourceLegendChips(sources: spo2Sources, selected: $spo2Focus, showAgree: false)
                }
            }
        }
    }

    // MARK: Shared bits

    private func cardTitle(_ title: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title.uppercased())
                .font(PulseFont.caption2)
                .foregroundStyle(PulseColors.textMuted)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(PulseFont.caption)
            .foregroundStyle(PulseColors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statsRows(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.0) { source, text in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(CompareColors.source(source, in: rows.map(\.0))).frame(width: 8, height: 8)
                    Text(source).font(PulseFont.caption.weight(.semibold)).foregroundStyle(PulseColors.textPrimary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(text)
                        .font(PulseFont.caption2)
                        .foregroundStyle(PulseColors.textSecondary)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func shift(_ days: Int) {
        day = calendar.date(byAdding: .day, value: days, to: day) ?? day
    }

    private func load() async {
        loading = true
        defer { loading = false }
        error = nil
        do {
            async let hr = reader.heartRate(from: day, to: dayEnd)
            async let sl = reader.sleep(from: nightStart, to: nightEnd)
            async let ox = reader.spo2(from: day, to: dayEnd)
            heartRate = try await hr
            sleep = try await sl
            spo2 = try await ox
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Colours

enum CompareColors {
    static let agree = PulseColors.success

    /// One colour per source, stable for a given source list: the Apple Watch always takes the
    /// heart-rate red, everything else walks the accent palette.
    static func source(_ source: String, in sources: [String]) -> Color {
        if source.localizedCaseInsensitiveContains("watch") { return PulseColors.heartRate }
        let others = sources.filter { !$0.localizedCaseInsensitiveContains("watch") }
        let palette = [
            PulseColors.accent, PulseColors.info, PulseColors.calories, PulseColors.readiness, PulseColors.hrv, PulseColors.distance,
        ]
        let i = others.firstIndex(of: source) ?? 0
        return palette[i % palette.count]
    }

    static func stage(_ label: String) -> Color {
        switch label {
        case "Deep": return PulseColors.accent
        case "Core": return PulseColors.sleep
        case "REM": return PulseColors.info
        case "Awake": return PulseColors.warning
        case "Asleep": return PulseColors.zoneMint
        default: return PulseColors.textMuted.opacity(0.4)
        }
    }
}

// MARK: - Legend

/// Tap a source to make it the focus; the others fade behind it. Tap again to clear.
struct SourceLegendChips: View {
    let sources: [String]
    @Binding var selected: String?
    var showAgree = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sources, id: \.self) { s in
                    let color = CompareColors.source(s, in: sources)
                    let isOn = selected == s
                    Button {
                        selected = isOn ? nil : s
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 9, height: 9)
                            Text(s)
                                .font(PulseFont.caption.weight(isOn ? .bold : .regular))
                                .foregroundStyle(PulseColors.textPrimary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(color.opacity(isOn ? 0.25 : 0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(color.opacity(isOn ? 0.9 : 0), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(isOn ? "\(s), focused" : s))
                }
                if showAgree, sources.count >= 2 {
                    HStack(spacing: 6) {
                        Circle().fill(CompareColors.agree).frame(width: 9, height: 9)
                        Text("agree").font(PulseFont.caption).foregroundStyle(PulseColors.textSecondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(CompareColors.agree.opacity(0.10), in: Capsule())
                }
            }
        }
    }
}
