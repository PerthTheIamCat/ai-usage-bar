import AppKit

// Shared layout metrics for the custom menu rows so every row's text and bars
// align to the same left/right edges regardless of row type.
enum MenuMetrics {
    static let width: CGFloat = 380
    static let inset: CGFloat = 14
    static var contentWidth: CGFloat { width - inset * 2 }
    /// Two-column stat layout: gap between the columns.
    static let columnGap: CGFloat = 20
    static var columnWidth: CGFloat { (contentWidth - columnGap) / 2 }
}

/// Traffic-light color for a remaining-capacity percentage. The red threshold
/// follows the user's warning setting; orange covers the band above it.
func limitColor(_ remainingPercent: Double) -> NSColor {
    if remainingPercent < AppSettings.shared.warnBelowRemaining { return .systemRed }
    if remainingPercent < 50 { return .systemOrange }
    return .systemGreen
}

/// Rounded capsule meter. Fills with remaining capacity in remaining mode and
/// with consumed capacity in used mode; color always tracks how close the
/// limit is. Draws with semantic colors so it adapts to light/dark.
final class LimitBarView: NSView {
    var remainingPercent: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let clamped = max(0, min(100, remainingPercent))
        let shown = AppSettings.shared.displayMode == .used ? 100 - clamped : clamped
        let w = bounds.width * CGFloat(shown / 100)
        guard w > 0 else { return }
        // Never draw the fill narrower than the capsule's own radius.
        let fillRect = NSRect(x: 0, y: 0, width: max(w, bounds.height), height: bounds.height)
        limitColor(clamped).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
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

/// Disabled menu item hosting a display-only custom view.
private func viewItem(_ view: NSView, accessibilityLabel: String) -> NSMenuItem {
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.staticText)
    view.setAccessibilityLabel(accessibilityLabel)
    let item = NSMenuItem()
    item.view = view
    item.isEnabled = false
    return item
}

/// Section header: optional brand glyph + name, bold.
func headerItem(_ title: String, icon: NSImage? = nil, iconTint: NSColor? = nil) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 26))
    var textX = MenuMetrics.inset
    if let icon {
        let imageView = NSImageView(frame: NSRect(x: MenuMetrics.inset, y: 5, width: 16, height: 16))
        imageView.image = icon
        imageView.contentTintColor = iconTint ?? .labelColor
        view.addSubview(imageView)
        textX += 22
    }
    let l = label(title, font: .boldSystemFont(ofSize: 13), color: .labelColor)
    l.frame = NSRect(x: textX, y: 5, width: MenuMetrics.width - textX - MenuMetrics.inset, height: 17)
    view.addSubview(l)
    return viewItem(view, accessibilityLabel: title)
}

/// Small uppercase group caption ("TODAY'S TOKENS").
func captionItem(_ title: String) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 20))
    let l = label(title.uppercased(), font: .systemFont(ofSize: 10, weight: .semibold), color: .secondaryLabelColor)
    l.frame = NSRect(x: MenuMetrics.inset, y: 3, width: MenuMetrics.contentWidth, height: 13)
    view.addSubview(l)
    return viewItem(view, accessibilityLabel: title)
}

/// One-line secondary note ("Not logged in…").
func noteItem(_ text: String) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 20))
    let l = label(text, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    l.frame = NSRect(x: MenuMetrics.inset, y: 3, width: MenuMetrics.contentWidth, height: 14)
    view.addSubview(l)
    return viewItem(view, accessibilityLabel: text)
}

/// Two stat pairs side by side: `label value   label value`. Halves the menu
/// height for short numeric stats. Pass nil for the right pair to leave it empty.
func statPairItem(_ name1: String, _ value1: String, _ name2: String? = nil, _ value2: String? = nil) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 21))
    let col = MenuMetrics.columnWidth
    let valueWidth: CGFloat = 64

    func addPair(_ name: String, _ value: String, x: CGFloat) {
        let l = label(name, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
        l.frame = NSRect(x: x, y: 2, width: col - valueWidth - 4, height: 17)
        let v = label(value, font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                      color: .labelColor, alignment: .right)
        v.frame = NSRect(x: x + col - valueWidth, y: 2, width: valueWidth, height: 17)
        view.addSubview(l)
        view.addSubview(v)
    }

    addPair(name1, value1, x: MenuMetrics.inset)
    var ax = "\(name1): \(value1)"
    if let name2, let value2 {
        addPair(name2, value2, x: MenuMetrics.inset + col + MenuMetrics.columnGap)
        ax += ", \(name2): \(value2)"
    }
    return viewItem(view, accessibilityLabel: ax)
}

/// Two-column stat row: secondary label left, monospaced-digit value right.
func statRowItem(_ name: String, _ value: String) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 21))
    let valueWidth: CGFloat = 130
    let l = label(name, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
    l.frame = NSRect(x: MenuMetrics.inset, y: 2, width: MenuMetrics.contentWidth - valueWidth - 8, height: 17)
    let v = label(value, font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium), color: .labelColor, alignment: .right)
    v.frame = NSRect(x: MenuMetrics.width - MenuMetrics.inset - valueWidth, y: 2, width: valueWidth, height: 17)
    view.addSubview(l)
    view.addSubview(v)
    return viewItem(view, accessibilityLabel: "\(name): \(value)")
}

/// "Updated 20:10" row with a live countdown ring to the next refresh.
/// The ring drains clockwise and the label counts down in seconds; the timer
/// runs in .common mode so it keeps ticking while the menu is open.
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
        // The open menu keeps this (stale) view after a refresh rebuilds the
        // menu, so past-zero means the refresh already fired behind it.
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

func refreshCountdownItem(updatedAt: Date, nextFire: Date, interval: TimeInterval) -> NSMenuItem {
    let view = RefreshCountdownView(updatedAt: updatedAt, nextFire: nextFire, interval: interval)
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.staticText)
    let item = NSMenuItem()
    item.view = view
    item.isEnabled = false
    return item
}

/// Limit window row: name + colored remaining %, capsule meter, reset caption.
func limitRowItem(name: String, window: LimitWindow) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 48))
    let remaining = window.remainingPercent
    let pctText = AppSettings.shared.displayMode.rowText(remaining: remaining)

    let nameLabel = label(name, font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
    nameLabel.frame = NSRect(x: MenuMetrics.inset, y: 29, width: MenuMetrics.contentWidth - 90, height: 17)

    let pctLabel = label(pctText, font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                         color: limitColor(remaining), alignment: .right)
    pctLabel.frame = NSRect(x: MenuMetrics.width - MenuMetrics.inset - 90, y: 29, width: 90, height: 17)

    let bar = LimitBarView(frame: NSRect(x: MenuMetrics.inset, y: 20, width: MenuMetrics.contentWidth, height: 5))
    bar.remainingPercent = remaining

    let resets = label("resets in \(humanReset(window.resetsAt))",
                       font: .systemFont(ofSize: 10.5), color: .secondaryLabelColor)
    resets.frame = NSRect(x: MenuMetrics.inset, y: 4, width: MenuMetrics.contentWidth, height: 13)

    view.addSubview(nameLabel)
    view.addSubview(pctLabel)
    view.addSubview(bar)
    view.addSubview(resets)
    return viewItem(view, accessibilityLabel: "\(name): \(pctText), resets in \(humanReset(window.resetsAt))")
}
