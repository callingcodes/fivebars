import AppKit
import FivebarsCore
import Charts
import SwiftUI

/// The popover shown when clicking the menu bar item (the original's Statistics window).
struct PanelView: View {
    let monitor: Monitor
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            LatencyChart(
                samples: monitor.samples,
                lowThreshold: monitor.prefs.slowPingThresholdMs,
                highThreshold: monitor.prefs.slowPingThresholdMs + 900
            )
            .frame(height: 110)
            StatsGrid(session: monitor.sessionStats, allTime: monitor.siteStats)
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    private var isDown: Bool {
        monitor.status == .down
    }

    private var header: some View {
        HStack(alignment: isDown ? .top : .center, spacing: 12) {
            SignalBars(active: isDown ? 0 : monitor.bars, color: monitor.qualityTone.color)
                .frame(width: 30, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(monitor.qualityTitle)
                        .font(.headline)
                    if isDown {
                        Text(monitor.downReasonText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(monitor.lastError ?? "")
                    } else {
                        Text(hostLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
                if isDown {
                    let changeHost = { openSettings() }
                    Button(action: changeHost) {
                        Text("Change Host…")
                    }
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(latencyText)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(isDown ? LatencyPalette.bad : .primary)
                    .monospacedDigit()
                if monitor.showsLoss && !isDown {
                    Text("\(Int(monitor.lossPercent.rounded()))% loss")
                        .font(.caption)
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

    private var footer: some View {
        HStack(spacing: 12) {
            Menu("Reset") {
                let resetSession = { monitor.resetSessionStats() }
                Button(action: resetSession) {
                    Text("Reset Session Stats")
                }
                let resetAllTime = { confirmResetAllTime() }
                Button(action: resetAllTime) {
                    Text("Reset All Time Stats…")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            let settings = { openSettings() }
            Button(action: settings) {
                Text("Settings…")
            }
            .keyboardShortcut(",", modifiers: .command)
            let quit = { NSApp.terminate(nil) }
            Button(action: quit) {
                Text("Quit")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q", modifiers: .command)
        }
        .controlSize(.small)
    }

    private func confirmResetAllTime() {
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to reset the all time stats for \(monitor.prefs.hostname)?"
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            monitor.resetAllTimeStats()
        }
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

struct LatencyChart: View {
    let samples: [Monitor.Sample]
    let lowThreshold: Double
    let highThreshold: Double

    private static let window: TimeInterval = 5 * 60

    var body: some View {
        let end = Date()
        let start = end.addingTimeInterval(-Self.window)
        let visible = samples.filter { $0.date >= start }
        let rtts = visible.compactMap(\.rttMs)
        let yMax = Self.scaleMax(rtts: rtts, lowThreshold: lowThreshold)
        let lost = visible.filter { $0.rttMs == nil && $0.lost }.count
        Chart {
            if !visible.isEmpty, lowThreshold <= yMax {
                RuleMark(y: .value("Slow ping threshold", lowThreshold))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .annotation(position: .overlay, alignment: .leading, spacing: 0) {
                        Text("slow")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.background.opacity(0.85), in: Capsule())
                            .padding(.leading, 2)
                    }
            }
            ForEach(visible) { sample in
                if let rtt = sample.rttMs {
                    BarMark(x: .value("Time", sample.date), y: .value("Latency", min(rtt, yMax)), width: .fixed(1))
                        .foregroundStyle(tone(for: rtt).color)
                    if rtt > yMax {
                        PointMark(x: .value("Time", sample.date), y: .value("Latency", yMax))
                            .symbol(.triangle)
                            .symbolSize(12)
                            .foregroundStyle(tone(for: rtt).color)
                    }
                } else if sample.lost {
                    RuleMark(x: .value("Time", sample.date))
                        .foregroundStyle(LatencyPalette.bad.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...yMax)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let ms = value.as(Double.self) {
                        Text(Format.wholeMs(ms))
                    }
                }
            }
        }
        .chartYAxis(visible.isEmpty ? .hidden : .automatic)
        .chartPlotStyle { $0.clipped() }
        .overlay {
            if visible.isEmpty {
                Text("Waiting for replies…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Latency, last 5 minutes")
        .accessibilityValue(Self.summary(rtts: rtts, lost: lost))
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
