import AppKit
import FivebarsCore
import SwiftUI

/// The live top of the status menu: quality, latency chart and stats. It sits on the system menu
/// material, so it draws no background of its own and leaves vibrancy to the menu.
struct StatusMenuView: View {
    let monitor: Monitor

    /// Matches the system menu: item text starts 14 pt in, rows are 320 pt wide.
    static let width: CGFloat = 320
    static let inset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            chartCaption
            LatencyChart(
                samples: monitor.samples,
                lowThreshold: monitor.prefs.slowPingThresholdMs,
                highThreshold: monitor.prefs.slowPingThresholdMs + 900,
                pingInterval: monitor.prefs.pingInterval
            )
            .frame(height: 64)
            StatsGrid(session: monitor.sessionStats, allTime: monitor.siteStats)
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: Self.width, alignment: .leading)
    }

    private var isDown: Bool {
        monitor.status == .down
    }

    private var chartCaption: some View {
        HStack(spacing: 6) {
            Text("Last 5 minutes")
            Spacer()
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: 12, y: 0.5))
            }
            .stroke(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            .frame(width: 12, height: 1)
            Text("slow above \(Format.wholeMs(monitor.prefs.slowPingThresholdMs))")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.bottom, -6)
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SignalBars(active: isDown ? 0 : monitor.bars, color: monitor.qualityTone.color)
                .frame(width: 22, height: 16)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(monitor.qualityTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(isDown ? monitor.downReasonText : hostLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    // Two lines are always reserved: the menu measures the header once when it
                    // opens, so a two-line down reason arriving later must already fit.
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(isDown ? monitor.lastError ?? "" : "")
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(latencyText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(isDown ? LatencyPalette.bad : .primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if monitor.showsLoss && !isDown {
                    Text("\(Int(monitor.lossPercent.rounded()))% loss")
                        .font(.system(size: 11))
                        .foregroundStyle(monitor.lossPercent > 0 ? LatencyPalette.warn : .secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var latencyText: String {
        if isDown {
            return "Down"
        }
        return monitor.latestPingMs.map(Format.wholeMs) ?? "–"
    }

    private var hostLine: String {
        let host = monitor.prefs.hostname
        guard let address = monitor.resolvedAddress, address != host else { return host }
        return "\(host) · \(address)"
    }
}

struct SignalBars: View {
    let active: Int
    let color: Color
    var levels = 5

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 2
            let width = (proxy.size.width - gap * CGFloat(levels - 1)) / CGFloat(levels)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<levels, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(index < active ? color : Color.secondary.opacity(0.3))
                        .frame(width: width, height: proxy.size.height * CGFloat(index + 1) / CGFloat(levels))
                }
            }
        }
    }
}

/// Five minutes of pings as a row of chunky bars. Samples are grouped into fixed time buckets so a
/// bar stays readable at a glance; each bar is as tall as its slowest reply and takes the colour of
/// its worst moment: green, orange when slow, red when a ping was lost.
struct LatencyChart: View {
    let samples: [Monitor.Sample]
    let lowThreshold: Double
    let highThreshold: Double
    var pingInterval: TimeInterval = 1

    static let window: TimeInterval = 5 * 60
    static let barCount = 36

    struct Bucket: Identifiable {
        let id: Int
        var worstRtt: Double?
        var lost = false
    }

    /// Buckets are aligned to the clock, not to the last ping, so bars don't shuffle every second:
    /// only the newest one grows. Pings sparser than a bucket get one bucket each.
    static func buckets(samples: [Monitor.Sample], now: Date, pingInterval: TimeInterval) -> [Bucket] {
        let span = max(window / Double(barCount), pingInterval)
        let count = min(barCount, max(1, Int((window / span).rounded())))
        let newest = Int((now.timeIntervalSinceReferenceDate / span).rounded(.down))
        let oldest = newest - count + 1
        var result = (oldest...newest).map { Bucket(id: $0) }
        for sample in samples {
            let index = Int((sample.date.timeIntervalSinceReferenceDate / span).rounded(.down)) - oldest
            guard result.indices.contains(index) else { continue }
            if let rtt = sample.rttMs {
                result[index].worstRtt = max(result[index].worstRtt ?? 0, rtt)
            } else if sample.lost {
                result[index].lost = true
            }
        }
        return result
    }

    var body: some View {
        let buckets = Self.buckets(samples: samples, now: Date(), pingInterval: pingInterval)
        let rtts = buckets.compactMap(\.worstRtt)
        let lost = buckets.filter(\.lost).count
        let yMax = Self.scaleMax(rtts: rtts, lowThreshold: lowThreshold)
        let isEmpty = buckets.allSatisfy { $0.worstRtt == nil && !$0.lost }
        GeometryReader { proxy in
            let gap: CGFloat = 2
            let barWidth = max(1, (proxy.size.width - gap * CGFloat(buckets.count - 1)) / CGFloat(buckets.count))
            let height = proxy.size.height
            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
                if !isEmpty, lowThreshold <= yMax {
                    thresholdLine(at: (height * (1 - lowThreshold / yMax)).rounded() + 0.5, width: proxy.size.width)
                }
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(buckets) { bucket in
                        bar(bucket, yMax: yMax, height: height)
                            .frame(width: barWidth)
                    }
                }
            }
            .frame(width: proxy.size.width, height: height, alignment: .bottomLeading)
        }
        .overlay {
            if isEmpty {
                Text("Waiting for replies…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Latency, last 5 minutes")
        .accessibilityValue(Self.summary(rtts: rtts, lost: lost))
    }

    @ViewBuilder
    private func bar(_ bucket: Bucket, yMax: Double, height: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
        if let rtt = bucket.worstRtt {
            let barHeight = max(3, height * min(rtt, yMax) / yMax)
            shape
                .fill(bucket.lost ? LatencyPalette.bad : tone(for: rtt).color)
                .frame(height: barHeight)
                .overlay(alignment: .top) {
                    // A capped spike: the bar hits the top and gets a notch to say "more than this".
                    if rtt > yMax {
                        Rectangle().fill(.background.opacity(0.6)).frame(height: 1).padding(.top, 3)
                    }
                }
        } else if bucket.lost {
            shape
                .fill(LatencyPalette.bad.opacity(0.85))
                .frame(height: height)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    /// Subtle on purpose: a hairline the bars stand in front of; its label lives in the caption.
    private func thresholdLine(at y: CGFloat, width: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
        }
        .stroke(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        .allowsHitTesting(false)
    }

    private func tone(for rtt: Double) -> QualityTone {
        LatencyPalette.tone(forRtt: rtt, lowThreshold: lowThreshold, highThreshold: highThreshold)
    }

    /// The top of the y-axis follows typical latency, not the worst spike: outliers are capped and marked
    /// so a few slow pings don't flatten normal traffic into a sliver. The threshold line is kept in
    /// view while it is within reach of the data.
    static func scaleMax(rtts: [Double], lowThreshold: Double) -> Double {
        guard !rtts.isEmpty else { return niceCeil(lowThreshold * 1.5) }
        let sorted = rtts.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        var top = max(p95 * 1.25, 20)
        if lowThreshold <= p95 * 3 {
            top = max(top, lowThreshold * 1.25)
        }
        return niceCeil(top)
    }

    private static func niceCeil(_ value: Double) -> Double {
        for step in [10.0, 25, 50, 100, 250, 500] where value <= step * 10 {
            return (value / step).rounded(.up) * step
        }
        return (value / 1000).rounded(.up) * 1000
    }

    private static func summary(rtts: [Double], lost: Int) -> String {
        guard !rtts.isEmpty else { return lost > 0 ? "\(lost) lost, no replies" : "No replies yet" }
        let sorted = rtts.sorted()
        let median = sorted[sorted.count / 2]
        return "Median \(Int(median.rounded())) milliseconds, slowest \(Int(sorted.last!.rounded())) "
            + "milliseconds, \(lost) lost"
    }
}

struct StatsGrid: View {
    let session: StatCounter
    let allTime: StatCounter

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Session").fontWeight(.semibold)
                    .frame(minWidth: 72, alignment: .trailing)
                    .gridColumnAlignment(.trailing)
                Text("All Time").fontWeight(.semibold)
                    .frame(minWidth: 72, alignment: .trailing)
                    .gridColumnAlignment(.trailing)
            }
            .accessibilityHidden(true)
            row("Pings sent") { $0.sent.formatted() }
            row("Replies lost") { $0.lost.formatted() }
            row("Packet loss") { Format.percent($0.lossPercent) }
            row("Average") { milliseconds($0.averageMs, $0) }
            row("Fastest") { milliseconds($0.fastestMs, $0) }
            row("Slowest") { milliseconds($0.slowestMs, $0) }
        }
        .font(.callout)
        .monospacedDigit()
    }

    private func row(_ label: String, value: @escaping (StatCounter) -> String) -> some View {
        let sessionValue = value(session)
        let allTimeValue = value(allTime)
        return GridRow {
            Text(label).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(sessionValue)
            Text(allTimeValue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): session \(sessionValue), all time \(allTimeValue)")
    }

    private func milliseconds(_ value: Double, _ stats: StatCounter) -> String {
        stats.replied > 0 ? Format.statMs(value) : "–"
    }
}
