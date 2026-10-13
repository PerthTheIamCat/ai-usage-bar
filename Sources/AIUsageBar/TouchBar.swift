import AppKit
import SwiftUI
import Darwin

// MARK: - Private DFR (Dynamic Function Row / Touch Bar) Bridging

private func setControlStripPresence(identifier: CFString, present: Bool) {
    typealias DFRElementSetControlStripPresenceFunc = @convention(c) (CFString, Bool) -> Void
    guard let handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY) else {
        return
    }
    defer { dlclose(handle) }
    if let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") {
        let fn = unsafeBitCast(sym, to: DFRElementSetControlStripPresenceFunc.self)
        fn(identifier, present)
    }
}

// MARK: - Touch Bar Hardware Detection

enum TouchBarHardware {
    private static let touchBarModels: Set<String> = [
        "MacBookPro13,2", "MacBookPro13,3",
        "MacBookPro14,2", "MacBookPro14,3",
        "MacBookPro15,1", "MacBookPro15,2", "MacBookPro15,3",
        "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,3",
        "MacBookPro17,1",
        "Mac14,7"
    ]

    static let modelIdentifier: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }()

    static let modelDisplayName: String = {
        let m = modelIdentifier
        switch m {
        case "Mac14,15": return "MacBook Air (15-inch, M2, 2023)"
        case "Mac14,2": return "MacBook Air (13-inch, M2, 2022)"
        case "Mac15,12": return "MacBook Air (13-inch, M3, 2024)"
        case "Mac15,13": return "MacBook Air (15-inch, M3, 2024)"
        case "MacBookAir10,1": return "MacBook Air (M1, 2020)"
        case "Mac14,7": return "MacBook Pro (13-inch, M2, 2022)"
        case "MacBookPro17,1": return "MacBook Pro (13-inch, M1, 2020)"
        case "MacBookPro16,1": return "MacBook Pro (16-inch, 2019)"
        case "MacBookPro16,2", "MacBookPro16,3": return "MacBook Pro (13-inch, 2020)"
        case _ where m.starts(with: "MacBookAir"): return "MacBook Air"
        case _ where m.starts(with: "MacBookPro"): return "MacBook Pro"
        case _ where m.starts(with: "Macmini"): return "Mac mini"
        case _ where m.starts(with: "MacStudio"): return "Mac Studio"
        case _ where m.starts(with: "MacPro"): return "Mac Pro"
        case _ where m.starts(with: "iMac"): return "iMac"
        default: return m
        }
    }()

    static func dfrStatus() -> Int32? {
        typealias DFRGetStatusFunc = @convention(c) () -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "DFRGetStatus") else { return nil }
        let fn = unsafeBitCast(sym, to: DFRGetStatusFunc.self)
        return fn()
    }

    /// Whether this Mac physically has a Touch Bar.
    static var hasPhysicalTouchBar: Bool {
        if touchBarModels.contains(modelIdentifier) {
            return true
        }
        if let status = dfrStatus(), status != 0 {
            return true
        }
        return false
    }

    /// Whether Touch Bar presentation is available (physical hardware or simulated).
    static func isAvailable(forceEnabled: Bool = false) -> Bool {
        if forceEnabled { return true }
        return hasPhysicalTouchBar
    }
}

// MARK: - Touch Bar Data Model

struct TouchBarProviderItem: Identifiable, Equatable {
    let id: String
    let kind: ProviderKind
    let name: String
    let icon: NSImage
    let text: String
    let warning: Bool

    static func == (lhs: TouchBarProviderItem, rhs: TouchBarProviderItem) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.warning == rhs.warning
    }
}

final class TouchBarState: ObservableObject {
    @Published var items: [TouchBarProviderItem] = []
}

// MARK: - Touch Bar View

struct TouchBarControlStripView: View {
    @ObservedObject var state: TouchBarState
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if state.items.isEmpty {
                    Text("AI …")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                } else {
                    ForEach(state.items) { item in
                        HStack(spacing: 4) {
                            Image(nsImage: item.icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 14, height: 14)
                            Text(item.text)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(item.warning ? Color.red : Color.white)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Touch Bar Manager

final class TouchBarManager: NSObject, NSTouchBarDelegate {
    static let shared = TouchBarManager()

    static let controlStripIdentifier = NSTouchBarItem.Identifier("com.aiusagebar.touchbar.controlstrip")
    static let appTouchBarIdentifier = NSTouchBar.CustomizationIdentifier("com.aiusagebar.touchbar.main")

    let state = TouchBarState()
    var onItemTapped: (() -> Void)?

    private var isRegistered = false
    private var customItem: NSCustomTouchBarItem?
    private var latestSnapshot: UsageSnapshot?

    func start() {
        syncWithSettings()
    }

    func syncWithSettings() {
        let settings = AppSettings.shared
        let shouldEnable = settings.touchBarEnabled && TouchBarHardware.isAvailable(forceEnabled: settings.forceTouchBarSupport)
        if shouldEnable && !isRegistered {
            registerControlStripItem()
        } else if !shouldEnable && isRegistered {
            unregisterControlStripItem()
        }
        if let snap = latestSnapshot {
            update(snapshot: snap)
        }
    }

    func update(snapshot: UsageSnapshot) {
        latestSnapshot = snapshot
        let settings = AppSettings.shared
        guard isRegistered else { return }

        var newItems: [TouchBarProviderItem] = []
        for kind in settings.providerOrder {
            guard settings.isShownInMenuBar(kind) else { continue }
            var remaining: Double?
            var text = ""
            let icon = kind.icon

            switch kind {
            case .claude:
                guard let usage = snapshot.claude else { continue }
                if let limits = snapshot.claudeLimits, case .ok = limits.state {
                    remaining = limits.fiveHour?.remainingPercent ?? limits.sevenDay?.remainingPercent
                }
                text = remaining.map { settings.displayMode.shortText(remaining: $0) } ?? formatTokens(usage.total)
            case .codex:
                guard let usage = snapshot.codex else { continue }
                if let limits = snapshot.codexLimits {
                    remaining = limits.primary?.remainingPercent ?? limits.secondary?.remainingPercent
                }
                text = remaining.map { settings.displayMode.shortText(remaining: $0) } ?? formatTokens(usage.totalTokens)
            case .antigravity:
                guard let usage = snapshot.antigravity else { continue }
                remaining = usage.fiveHour?.remainingPercent ?? usage.weekly?.remainingPercent
                text = remaining.map { settings.displayMode.shortText(remaining: $0) } ?? "\(usage.totalPrompts)P"
            }

            let warning = remaining.map { $0 < settings.warnBelowRemaining } ?? false
            newItems.append(TouchBarProviderItem(
                id: kind.rawValue,
                kind: kind,
                name: kind.displayName,
                icon: icon,
                text: text,
                warning: warning
            ))
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state.items = newItems
        }
    }

    private func registerControlStripItem() {
        guard !isRegistered else { return }
        let item = NSCustomTouchBarItem(identifier: Self.controlStripIdentifier)
        let hosting = NSHostingView(rootView: TouchBarControlStripView(state: state, onTap: { [weak self] in
            self?.onItemTapped?()
        }))
        item.view = hosting
        customItem = item

        let addSel = NSSelectorFromString("addSystemTrayItem:")
        if NSTouchBarItem.responds(to: addSel) {
            _ = NSTouchBarItem.perform(addSel, with: item)
        }
        setControlStripPresence(identifier: Self.controlStripIdentifier.rawValue as CFString, present: true)
        isRegistered = true
    }

    private func unregisterControlStripItem() {
        guard isRegistered else { return }
        setControlStripPresence(identifier: Self.controlStripIdentifier.rawValue as CFString, present: false)
        if let item = customItem {
            let removeSel = NSSelectorFromString("removeSystemTrayItem:")
            if NSTouchBarItem.responds(to: removeSel) {
                _ = NSTouchBarItem.perform(removeSel, with: item)
            }
        }
        customItem = nil
        isRegistered = false
    }
}
