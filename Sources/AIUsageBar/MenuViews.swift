import AppKit

// Shared layout metrics for the custom popover rows so every row's text and
// bars align to the same left/right edges regardless of row type.
enum MenuMetrics {
    static let width: CGFloat = 380
    static let inset: CGFloat = 14
    static var contentWidth: CGFloat { width - inset * 2 }
}

/// Traffic-light color for a remaining-capacity percentage. The red threshold
/// follows the user's warning setting; orange covers the band above it.
func limitColor(_ remainingPercent: Double) -> NSColor {
    if remainingPercent < AppSettings.shared.warnBelowRemaining { return .systemRed }
    if remainingPercent < 50 { return .systemOrange }
    return .systemGreen
}

/// One color per provider, shared by the hourly and daily-trend charts (and
/// their legends) so a color always means the same provider everywhere.
enum ProviderColor {
    static let claude = BrandIcons.claudeBrandColor
    static let codex = NSColor.systemGreen
    static let antigravity = BrandIcons.geminiBrandColor
}

/// Draws a capsule meter filling `rect` in the current graphics context —
/// shared by `LimitBarView` (a live popover NSView) and `MiniMeter` (an
/// offscreen NSImage for the menu-bar title), so the two only ever draw the
/// bar one way.
func drawCapsuleMeter(in rect: NSRect, remainingPercent: Double, color: NSColor) {
    let radius = rect.height / 2
    NSColor.quaternaryLabelColor.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

    let clamped = max(0, min(100, remainingPercent))
    let shown = AppSettings.shared.displayMode == .used ? 100 - clamped : clamped
    let w = rect.width * CGFloat(shown / 100)
    guard w > 0 else { return }
    // Never draw the fill narrower than the capsule's own radius.
    let fillRect = NSRect(x: rect.minX, y: rect.minY, width: max(w, rect.height), height: rect.height)
    color.setFill()
    NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
}

/// Draws a circular arc meter filling `rect`, same clockwise-drain-from-12
/// o'clock technique as `RefreshCountdownView`'s ring. Shared by `MiniMeter`
/// (menu-bar title) — there's no popover ring anymore, the dropdown always
/// uses the bar (Settings › General › Limit style only affects the menu bar).
func drawRingMeter(in rect: NSRect, remainingPercent: Double, color: NSColor) {
    let lineWidth = max(1.5, min(rect.width, rect.height) * 0.16)
    let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
    let center = NSPoint(x: inset.midX, y: inset.midY)
    let radius = min(inset.width, inset.height) / 2

    let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    track.lineWidth = lineWidth
    NSColor.quaternaryLabelColor.setStroke()
    track.stroke()

    let clamped = max(0, min(100, remainingPercent))
    let shown = AppSettings.shared.displayMode == .used ? 100 - clamped : clamped
    let fraction = CGFloat(shown / 100)
    guard fraction > 0 else { return }

    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - fraction * 360, clockwise: true)
    arc.lineWidth = lineWidth
    arc.lineCapStyle = .round
    color.setStroke()
    arc.stroke()
}

/// Rounded capsule meter, live in the popover. Fills with remaining capacity
/// in remaining mode and with consumed capacity in used mode; color always
/// tracks how close the limit is. Hosted via `NSViewRepresentable`.
final class LimitBarView: NSView {
    var remainingPercent: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        drawCapsuleMeter(in: bounds, remainingPercent: remainingPercent, color: limitColor(remainingPercent))
    }
}

/// Small inline bar/ring meter embedded in the menu-bar title via
/// `NSTextAttachment`, vertically centered on `font` like
/// `BrandIcons.attachment`. Settings › General › Limit style picks bar vs.
/// ring; `.percentOnly` never reaches this — callers keep plain text then.
enum MiniMeter {
    static func attachment(remainingPercent: Double, style: LimitStyle, font: NSFont, color: NSColor) -> NSAttributedString {
        let height = font.pointSize * 0.75
        let image: NSImage
        switch style {
        case .bar, .percentOnly:
            let size = NSSize(width: height * 2.4, height: height)
            image = NSImage(size: size, flipped: false) { rect in
                drawCapsuleMeter(in: rect, remainingPercent: remainingPercent, color: color)
                return true
            }
        case .ring:
            let size = NSSize(width: height, height: height)
            image = NSImage(size: size, flipped: false) { rect in
                drawRingMeter(in: rect, remainingPercent: remainingPercent, color: color)
                return true
            }
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }
}

private func label(_ text: String, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = font
    l.textColor = color
    l.alignment = alignment
    l.lineBreakMode = .byTruncatingTail
    return l
}

/// "Updated 20:10" row with a live countdown ring to the next refresh.
/// The ring drains clockwise and the label counts down in seconds. Hosted in
/// the popover via `NSViewRepresentable`; a fresh instance is created (via
/// SwiftUI's `.id()`) whenever the underlying refresh time changes, so the
/// view's own state can stay purely init-time like it always has.
final class RefreshCountdownView: NSView {
    private let nextFire: Date
    private let interval: TimeInterval
    private let updatedText: String
    private let label: NSTextField
    private var timer: Timer?

    private static let ringSize: CGFloat = 12

    init(updatedAt: Date, nextFire: Date, interval: TimeInterval) {
        self.nextFire = nextFire
        self.interval = max(1, interval)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        self.updatedText = "Updated \(fmt.string(from: updatedAt))"
        self.label = NSTextField(labelWithString: "")
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 20))
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(
            x: MenuMetrics.inset + Self.ringSize + 6, y: 3,
            width: MenuMetrics.contentWidth - Self.ringSize - 6, height: 14)
        addSubview(label)
        updateLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { timer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateLabel()
            self?.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var remaining: TimeInterval { max(0, nextFire.timeIntervalSinceNow) }

    private func updateLabel() {
        label.stringValue = remaining <= 0
            ? "\(updatedText) · refreshing…"
            : "\(updatedText) · refresh in \(Int(remaining.rounded()))s"
        setAccessibilityLabel(label.stringValue)
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = Self.ringSize
        let rect = NSRect(x: MenuMetrics.inset, y: (bounds.height - size) / 2, width: size, height: size)
            .insetBy(dx: 1, dy: 1)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2

        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = 2
        NSColor.quaternaryLabelColor.setStroke()
        track.stroke()

        let fraction = CGFloat(remaining / interval)
        guard fraction > 0 else { return }
        // Ring drains as the countdown approaches zero: green → orange → red.
        let color: NSColor = fraction > 0.5 ? .systemGreen : (fraction > 0.2 ? .systemOrange : .systemRed)
        let arc = NSBezierPath()
        // NSBezierPath angles are counter-clockwise; sweep backwards from 12
        // o'clock so the ring visually drains clockwise.
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - fraction * 360, clockwise: true)
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }
}

/// Compact hourly usage chart. Values are normalized to the busiest hour so
/// providers with different units can still be viewed together as activity.
/// Hosted in the popover via `NSViewRepresentable`.
final class HourlyUsageChartView: NSView {
    private let usage: HourlyUsage

    init(usage: HourlyUsage) {
        self.usage = usage
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 132))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(usage.peakHour.map { "Peak usage at \($0):00" } ?? "No usage recorded today")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: MenuMetrics.inset, dy: 12)
        // Top strip reserved for the per-provider legend; bottom strip
        // (below `chart`) already had room for the hour-axis labels.
        let chart = NSRect(x: plot.minX, y: plot.minY + 10, width: plot.width, height: plot.height - 34)

        NSColor.quaternaryLabelColor.setStroke()
        for fraction in [0.0, 0.5, 1.0] {
            let y = chart.minY + chart.height * CGFloat(fraction)
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: chart.minX, y: y))
            grid.line(to: NSPoint(x: chart.maxX, y: y))
            grid.lineWidth = 0.5
            grid.stroke()
        }

        guard usage.total > 0 else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            ("No usage recorded today" as NSString).draw(
                in: NSRect(x: chart.minX, y: chart.midY - 8, width: chart.width, height: 16),
                withAttributes: attrs)
            return
        }

        let step = chart.width / 23
        // Each series is normalized to its own peak (not a shared max) —
        // tokens and prompt-counts aren't comparable units, so the useful
        // signal is "when is this provider busiest," not relative magnitude.
        func drawSeries(_ values: [Int], color: NSColor) {
            guard let peak = values.max(), peak > 0 else { return }
            let maxValue = CGFloat(peak)
            func point(_ index: Int) -> NSPoint {
                NSPoint(x: chart.minX + CGFloat(index) * step, y: chart.minY + chart.height * CGFloat(values[index]) / maxValue)
            }
            let line = NSBezierPath()
            line.move(to: point(0))
            for index in 1..<24 { line.line(to: point(index)) }
            line.lineWidth = 1.75
            color.setStroke()
            line.stroke()

            if let peakIndex = values.firstIndex(of: peak) {
                let p = point(peakIndex)
                let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5))
                color.setFill()
                dot.fill()
            }
        }
        drawSeries(usage.claude, color: ProviderColor.claude)
        drawSeries(usage.codex, color: ProviderColor.codex)
        drawSeries(usage.antigravity, color: ProviderColor.antigravity)

        for index in [0, 6, 12, 18, 23] {
            let text = label(String(format: "%02d", index), font: .monospacedDigitSystemFont(ofSize: 9, weight: .regular), color: .secondaryLabelColor, alignment: .center)
            text.frame = NSRect(x: chart.minX + CGFloat(index) * step - 12, y: chart.minY - 15, width: 24, height: 12)
            text.draw(text.bounds)
        }

        var legendX = chart.minX
        let legendY = chart.maxY + 10
        for (name, color) in [("Claude", ProviderColor.claude), ("Codex", ProviderColor.codex), ("Antigravity", ProviderColor.antigravity)] {
            let dot = NSBezierPath(ovalIn: NSRect(x: legendX, y: legendY, width: 6, height: 6))
            color.setFill()
            dot.fill()
            let textWidth: CGFloat = name == "Antigravity" ? 64 : 42
            let text = label(name, font: .systemFont(ofSize: 9), color: .secondaryLabelColor)
            text.frame = NSRect(x: legendX + 10, y: legendY - 3, width: textWidth, height: 12)
            text.draw(text.bounds)
            legendX += 10 + textWidth
        }
    }
}

/// Stacked daily-cost bars over a trend range (Claude/Codex/Antigravity),
/// so a spike is traceable to which provider drove it. Cost (not tokens) is
/// the axis because it's the one unit comparable across providers — tokens
/// vs. Antigravity's prompt-count aren't the same thing.
final class DailyTrendChartView: NSView {
    private let trend: DailyTrend

    init(trend: DailyTrend) {
        self.trend = trend
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 140))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Daily cost trend over the last \(trend.days.count) days")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: MenuMetrics.inset, dy: 12)
        let chart = NSRect(x: plot.minX, y: plot.minY + 10, width: plot.width, height: plot.height - 22)
        let days = trend.days.count
        guard days > 0 else { return }

        NSColor.quaternaryLabelColor.setStroke()
        for fraction in [0.0, 0.5, 1.0] {
            let y = chart.minY + chart.height * CGFloat(fraction)
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: chart.minX, y: y))
            grid.line(to: NSPoint(x: chart.maxX, y: y))
            grid.lineWidth = 0.5
            grid.stroke()
        }

        let totals = trend.totalCostUSD
        guard totals.reduce(0, +) > 0 else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            ("No cost recorded in this range" as NSString).draw(
                in: NSRect(x: chart.minX, y: chart.midY - 8, width: chart.width, height: 16),
                withAttributes: attrs)
            return
        }
        let maxValue = max(0.01, totals.max() ?? 0)

        let gap: CGFloat = days > 14 ? 1 : 3
        let barWidth = max(1, (chart.width - CGFloat(days - 1) * gap) / CGFloat(days))

        for i in 0..<days {
            let x = chart.minX + CGFloat(i) * (barWidth + gap)
            var y = chart.minY
            for (value, color) in [(trend.claudeCostUSD[i], ProviderColor.claude),
                                    (trend.codexCostUSD[i], ProviderColor.codex),
                                    (trend.antigravityCostUSD[i], ProviderColor.antigravity)] {
                guard value > 0 else { continue }
                let h = chart.height * CGFloat(value / maxValue)
                color.setFill()
                NSBezierPath(rect: NSRect(x: x, y: y, width: barWidth, height: h)).fill()
                y += h
            }
        }

        let fmt = DateFormatter()
        fmt.dateFormat = days > 10 ? "M/d" : "E"
        for i in Set([0, days / 2, days - 1]).sorted() {
            let text = label(fmt.string(from: trend.days[i]), font: .systemFont(ofSize: 9), color: .secondaryLabelColor, alignment: .center)
            let x = chart.minX + CGFloat(i) * (barWidth + gap) + barWidth / 2 - 16
            text.frame = NSRect(x: x, y: chart.minY - 15, width: 32, height: 12)
            text.draw(text.bounds)
        }
    }
}

/// GitHub-contributions-style grid: one cell per day (rows = weekday,
/// columns = week), colored by that day's combined cost intensity. Reuses
/// the same `DailyTrend` already fetched for the trend chart — no separate
/// file scan just for this view.
final class CalendarHeatmapView: NSView {
    private let trend: DailyTrend

    init(trend: DailyTrend) {
        self.trend = trend
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 120))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Calendar heatmap of the last \(trend.days.count) days")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: MenuMetrics.inset, dy: 8)
        guard !trend.days.isEmpty else { return }

        let calendar = Calendar.current
        // Calendar.weekday is 1=Sunday...7=Saturday; use 0=Sunday...6=Saturday
        // as the row index so the grid reads Sun (top) to Sat (bottom).
        let firstRow = calendar.component(.weekday, from: trend.days[0]) - 1
        let totalCells = firstRow + trend.days.count
        let columns = Int(ceil(Double(totalCells) / 7.0))

        let gap: CGFloat = 3
        let cellSize = min((plot.width - CGFloat(columns - 1) * gap) / CGFloat(columns),
                            (plot.height - 6 * gap) / 7)
        let gridWidth = CGFloat(columns) * cellSize + CGFloat(columns - 1) * gap
        let gridHeight = 7 * cellSize + 6 * gap
        let originX = plot.minX + max(0, (plot.width - gridWidth) / 2)
        let originY = plot.minY + max(0, (plot.height - gridHeight) / 2)

        let totals = trend.totalCostUSD
        let maxValue = max(0.01, totals.max() ?? 0)

        for (index, _) in trend.days.enumerated() {
            let cellIndex = firstRow + index
            let column = cellIndex / 7
            let row = cellIndex % 7 // 0 = Sunday
            let x = originX + CGFloat(column) * (cellSize + gap)
            // Grid is laid out Sunday-at-top, but AppKit's y grows upward,
            // so row 0 (Sunday) needs the highest y within the grid.
            let y = originY + gridHeight - cellSize - CGFloat(row) * (cellSize + gap)

            let color: NSColor
            if totals[index] <= 0 {
                color = NSColor.quaternaryLabelColor
            } else {
                let intensity = min(1, totals[index] / maxValue)
                color = NSColor.systemBlue.withAlphaComponent(0.25 + 0.65 * intensity)
            }
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: cellSize, height: cellSize), xRadius: 2, yRadius: 2).fill()
        }
    }
}
