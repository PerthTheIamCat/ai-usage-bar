import AppKit
import SwiftUI
import Combine

/// Coordinates the screen physics, AI activity reactions, speech bubbles, and window movement.
final class CompanionManager: ObservableObject {
    static let shared = CompanionManager()

    @Published var state: CompanionState = .idle
    @Published var facingLeft: Bool = false
    @Published var currentSpeech: CompanionSpeech?
    @Published var currentFrame: PixelFrame = PixelSpriteLibrary.farmerIdle1
    @Published var activeProvider: ProviderKind = .claude
    @Published var isPetting: Bool = false
    @Published var isPokedJump: Bool = false
    @Published var isDragging: Bool = false
    @Published var isLandingDust: Bool = false
    @Published var petHeartCount: Int = 0

    private var panel: CompanionPanel?
    private var subagentPanels: [String: (panel: CompanionPanel, position: CGPoint)] = [:]
    private var timer: Timer?
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?
    private var currentPosition: CGPoint = CGPoint(x: 200, y: 100)
    private var targetPosition: CGPoint = CGPoint(x: 200, y: 100)

    private var frameTick = 0
    private var stateDuration: TimeInterval = 0
    private var idleDuration: TimeInterval = 0
    private var cursorHoverTimer: TimeInterval = 0
    private var fallVelocity: CGFloat = 0
    private var isMouseDownOnCompanion: Bool = false
    private var mouseDownLocation: CGPoint = .zero
    private var mouseDownTime: Date = Date()
    private var cancellables = Set<AnyCancellable>()

    private let panelSize = CGSize(width: 180, height: 110)
    private let subagentPanelSize = CGSize(width: 140, height: 90)

    private init() {
        // Observe settings changes
        NotificationCenter.default.publisher(for: .usageSettingsChanged)
            .sink { [weak self] _ in
                self?.applySettings()
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func start() {
        guard AppSettings.shared.companionEnabled else {
            stop()
            return
        }

        if panel == nil {
            setupPanel()
        }

        panel?.orderFront(nil)
        startLoop()
        setupEventMonitors()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        removeEventMonitors()
        panel?.orderOut(nil)
        for (_, entry) in subagentPanels {
            entry.panel.orderOut(nil)
        }
        subagentPanels.removeAll()
    }

    func applySettings() {
        if AppSettings.shared.companionEnabled {
            if panel == nil || timer == nil {
                start()
            }
            panel?.ignoresMouseEvents = AppSettings.shared.companionClickThrough
        } else {
            stop()
        }
    }

    private func setupPanel() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initialOrigin = CGPoint(
            x: screen.maxX - panelSize.width - 60,
            y: screen.minY + 30
        )
        currentPosition = initialOrigin
        targetPosition = initialOrigin

        let p = CompanionPanel(contentRect: NSRect(origin: initialOrigin, size: panelSize))
        p.contentView = NSHostingView(rootView: CompanionView(manager: self))
        p.ignoresMouseEvents = AppSettings.shared.companionClickThrough
        self.panel = p
    }

    private func setupEventMonitors() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleMouseEvent(event)
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
    }

    private func removeEventMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard AppSettings.shared.companionEnabled else { return }
        let mousePos = NSEvent.mouseLocation
        let center = CGPoint(x: currentPosition.x + 90, y: currentPosition.y + 35)
        let dist = hypot(mousePos.x - center.x, mousePos.y - center.y)

        switch event.type {
        case .leftMouseDown:
            if dist < 48 {
                isMouseDownOnCompanion = true
                mouseDownLocation = mousePos
                mouseDownTime = Date()
            }

        case .leftMouseDragged:
            guard isMouseDownOnCompanion else { return }
            let moveDist = hypot(mousePos.x - mouseDownLocation.x, mousePos.y - mouseDownLocation.y)
            if !isDragging && moveDist > 6 {
                startDragging(at: mousePos)
            } else if isDragging {
                updateDrag(to: mousePos)
            }

        case .leftMouseUp:
            if isDragging {
                endDragging(at: mousePos)
            } else if isMouseDownOnCompanion {
                poke()
            }
            isMouseDownOnCompanion = false

        default:
            break
        }
    }

    private func startLoop() {
        timer?.invalidate()
        // Run loop at ~25 FPS
        timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.tick(delta: 0.04)
        }
    }

    // MARK: - Physics & Behavior Loop

    private func tick(delta: TimeInterval) {
        stateDuration += delta
        idleDuration += delta

        // Check speech expiration
        if let speech = currentSpeech, speech.isExpired {
            currentSpeech = nil
        }

        // Falling gravity physics
        if state == .falling {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let groundY = screen.minY + 25
            let gravity: CGFloat = 1700.0 // px/s²
            fallVelocity += gravity * CGFloat(delta)
            currentPosition.y -= fallVelocity * CGFloat(delta)

            if currentPosition.y <= groundY {
                currentPosition.y = groundY
                panel?.setFrameOrigin(currentPosition)
                targetPosition = currentPosition
                triggerLanding()
            } else {
                panel?.setFrameOrigin(currentPosition)
            }
            return
        }

        guard !isDragging else { return }

        // Mouse & Cursor interactions (look, pet, chase, dodge)
        updateCursorInteraction(delta: delta)

        // Behavior state transitions
        updateStateTransitions(delta: delta)

        // Move towards target
        updateMovement(delta: delta)

        // Move following subagents in parade
        updateSubagentsMovement(delta: delta)

        // Update animation frames
        updateAnimationFrames()
    }

    private func updateStateTransitions(delta: TimeInterval) {
        switch state {
        case .dangling, .falling:
            break
        case .landing:
            if stateDuration > 0.8 && !isLandingDust {
                transitionTo(.idle)
            }
        case .sprinting:
            // Sprints for a while when AI is generating, then returns to walking
            if idleDuration > 8.0 {
                transitionTo(.walking)
            }
        case .working:
            if stateDuration > 4.5 || idleDuration > 6.0 {
                transitionTo(.walking)
            }
        case .celebrating:
            if stateDuration > 3.5 {
                transitionTo(.walking)
            }
        case .stretching:
            if stateDuration > 3.0 {
                transitionTo(.walking)
            }
        case .petting:
            if stateDuration > 3.0 && !isPetting {
                transitionTo(.idle)
            }
        case .poked:
            if stateDuration > 1.2 {
                transitionTo(.idle)
            }
        case .walking:
            // Pick a new random target waypoint when reached or after some time
            let dist = hypot(targetPosition.x - currentPosition.x, targetPosition.y - currentPosition.y)
            if dist < 15 || stateDuration > 6.0 {
                if idleDuration > 40.0 {
                    transitionTo(Bool.random() ? .sleeping : .idle)
                } else if Bool.random() && stateDuration > 3.0 {
                    transitionTo(Bool.random() ? .stretching : .idle)
                } else {
                    pickRandomTarget()
                }
            }
        case .idle:
            if stateDuration > 4.0 {
                if idleDuration > 50.0 {
                    transitionTo(.sleeping)
                } else {
                    transitionTo(Bool.random() ? .stretching : .walking)
                }
            }
        case .sleeping:
            if idleDuration < 40.0 {
                transitionTo(.idle)
            }
        }
    }

    private func transitionTo(_ newState: CompanionState) {
        state = newState
        stateDuration = 0
        if newState == .walking || newState == .sprinting {
            pickRandomTarget()
        }
    }

    private func pickRandomTarget() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let margin: CGFloat = 30
        let minX = screen.minX + margin
        let maxX = screen.maxX - panelSize.width - margin

        // Walk predominantly along the lower half of the screen
        let minY = screen.minY + 10
        let maxY = state == .sprinting ? (screen.maxY - panelSize.height - margin) : (screen.minY + screen.height * 0.35)

        let newX = CGFloat.random(in: minX...maxX)
        let newY = CGFloat.random(in: minY...maxY)
        targetPosition = CGPoint(x: newX, y: newY)
    }

    private func updateMovement(delta: TimeInterval) {
        guard state == .walking || state == .sprinting else { return }

        let dx = targetPosition.x - currentPosition.x
        let dy = targetPosition.y - currentPosition.y
        let dist = hypot(dx, dy)

        guard dist > 2 else { return }

        // Determine facing direction
        if abs(dx) > 1 {
            facingLeft = dx < 0
        }

        let baseSpeed: CGFloat = 60.0 * CGFloat(AppSettings.shared.companionSpeed)
        let speed = baseSpeed * state.speedMultiplier
        let moveDist = min(dist, speed * CGFloat(delta))

        let vx = (dx / dist) * moveDist
        let vy = (dy / dist) * moveDist

        currentPosition.x += vx
        currentPosition.y += vy

        // Apply position to panel
        panel?.setFrameOrigin(currentPosition)
    }

    private func updateAnimationFrames() {
        frameTick += 1
        let tickThreshold: Int
        switch state {
        case .sprinting, .working, .celebrating, .petting, .poked, .dangling, .falling, .landing:
            tickThreshold = 3
        case .stretching:
            tickThreshold = 8
        case .walking:
            tickThreshold = 5
        case .idle, .sleeping:
            tickThreshold = 12
        }

        guard frameTick >= tickThreshold else { return }
        frameTick = 0

        let char: CompanionCharacter
        if AppSettings.shared.companionAutoProvider {
            char = AppSettings.shared.mascot(for: activeProvider)
        } else {
            char = AppSettings.shared.companionCharacter
        }
        let stage = ProgressionStore.shared.currentStage
        let frames = PixelSpriteLibrary.frames(for: char, state: state, stage: stage)
        guard !frames.isEmpty else { return }

        // Find next frame index
        if let idx = frames.firstIndex(where: { $0.rows == currentFrame.rows }) {
            let nextIdx = (idx + 1) % frames.count
            currentFrame = frames[nextIdx]
        } else {
            currentFrame = frames[0]
        }
    }

    // MARK: - Mouse & Cursor Interactivity

    private func updateCursorInteraction(delta: TimeInterval) {
        let mode = AppSettings.shared.companionCursorMode
        guard mode != .disabled else {
            if isPetting { isPetting = false }
            return
        }

        let mousePos = NSEvent.mouseLocation
        let center = CGPoint(x: currentPosition.x + 90, y: currentPosition.y + 35)
        let dx = mousePos.x - center.x
        let dy = mousePos.y - center.y
        let dist = hypot(dx, dy)

        // 1. Look towards cursor when within 250px (unless sleeping, sprinting, or poked)
        if dist < 250 && abs(dx) > 12 && state != .sprinting && state != .sleeping && state != .poked {
            facingLeft = dx < 0
        }

        // 2. Hover / Petting Detection (< 48px from center)
        let isHovering = dist < 48
        if isHovering {
            cursorHoverTimer += delta
            if cursorHoverTimer > 0.35 {
                if !isPetting {
                    isPetting = true
                    transitionTo(.petting)
                    petHeartCount += 1

                    let petQuotes = [
                        "Purr~ ❤️",
                        "❤️",
                        "Happy! ✨",
                        "*happy wiggle* 💕",
                        "Best programmer! 🌸"
                    ]
                    speak(text: petQuotes.randomElement() ?? "❤️", icon: "❤️", duration: 2.0)
                }
            }
        } else {
            if cursorHoverTimer > 0 {
                cursorHoverTimer = max(0, cursorHoverTimer - delta * 2)
            }
            if isPetting && cursorHoverTimer == 0 {
                isPetting = false
                if state == .petting {
                    transitionTo(.idle)
                }
            }
        }

        guard !isPetting && !isDragging && state != .poked && state != .sleeping && state != .dangling && state != .falling && state != .landing else { return }

        // 3. Playful Dodge
        if mode == .dodge {
            if dist < 85 && stateDuration > 0.4 {
                let dodgeDx = dx == 0 ? (Bool.random() ? -120 : 120) : -(dx / dist) * 140
                let dodgeDy = dy == 0 ? 30 : -(dy / dist) * 90

                guard let screen = NSScreen.main?.visibleFrame else { return }
                let clampedX = min(max(currentPosition.x + dodgeDx, screen.minX + 20), screen.maxX - panelSize.width - 20)
                let clampedY = min(max(currentPosition.y + dodgeDy, screen.minY + 20), screen.minY + screen.height * 0.4)

                targetPosition = CGPoint(x: clampedX, y: clampedY)
                transitionTo(.sprinting)
                speak(text: "Whoa, excuse me! 💨", icon: "💨", duration: 1.5)
            }
        }

        // 4. Curious Follow / Chase Cursor
        if mode == .follow || mode == .all {
            if dist > 75 && dist < 360 {
                if state == .idle || state == .walking {
                    // Head towards mouse, but stop ~65px away so we don't cover the cursor
                    let offsetDistance: CGFloat = 65
                    let targetX = mousePos.x - (dx / dist) * offsetDistance - 90
                    let targetY = mousePos.y - (dy / dist) * offsetDistance - 35

                    guard let screen = NSScreen.main?.visibleFrame else { return }
                    let clampedX = min(max(targetX, screen.minX + 20), screen.maxX - panelSize.width - 20)
                    let clampedY = min(max(targetY, screen.minY + 20), screen.minY + screen.height * 0.5)

                    targetPosition = CGPoint(x: clampedX, y: clampedY)
                    if state != .walking {
                        transitionTo(.walking)
                    }
                }
            }
        }
    }

    // MARK: - AI Activity Hook

    /// Called by UsageReader or AppDelegate when new AI activity / tool calls / tokens are detected.
    func reportAIActivity(provider: String, tool: String? = nil, tokens: Int? = nil, isGenerating: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.idleDuration = 0

            let pLower = provider.lowercased()
            if pLower.contains("claude") {
                self.activeProvider = .claude
            } else if pLower.contains("codex") {
                self.activeProvider = .codex
            } else if pLower.contains("antigravity") {
                self.activeProvider = .antigravity
            }

            if let tool, !tool.isEmpty {
                self.transitionTo(.working)
                self.speak(text: "Using \(tool)...", icon: "🔧")
            } else if let tokens, tokens > 0 {
                self.transitionTo(.sprinting)
                self.speak(text: "+\(formatTokens(tokens)) tokens!", icon: "⚡️")
            } else if isGenerating {
                self.transitionTo(.working)
                let quotes = [
                    "Watering the code...",
                    "Harvesting tokens!",
                    "Brewing code logic...",
                    "Tending the fields..."
                ]
                self.speak(text: quotes.randomElement() ?? "Working...", icon: "✨")
            }
        }
    }

    /// Trigger a custom speech bubble
    func speak(text: String, icon: String? = nil, duration: TimeInterval = 4.0, isWarning: Bool = false) {
        guard AppSettings.shared.companionSpeechEnabled else { return }
        currentSpeech = CompanionSpeech(text: text, icon: icon, duration: duration, isWarning: isWarning)
    }

    /// Interaction when the user clicks or pokes the companion
    func poke() {
        idleDuration = 0
        stateDuration = 0
        isPokedJump = true
        transitionTo(.poked)

        if state == .sleeping {
            speak(text: "Good morning! Ready to farm code!", icon: "☀️", duration: 3.5)
        } else {
            let pokeQuotes = [
                "Boop! 🎈",
                "Hey there! ⭐",
                "Ready to ship code! 🚀",
                "*Giggle* 💫",
                "Stardrop power! 🌟",
                "Meow! 🐾",
                "Junimo bounce! ✨"
            ]
            speak(text: pokeQuotes.randomElement() ?? "Boop!", icon: "✨", duration: 2.2)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.isPokedJump = false
            if self.state == .poked {
                self.transitionTo(.idle)
            }
        }
    }

    /// Interaction when the user clicks the companion
    func userTappedCompanion() {
        poke()
    }

    /// Simulate petting reaction for testing from Settings
    func simulatePetting() {
        idleDuration = 0
        isPetting = true
        transitionTo(.petting)
        speak(text: "Purr~ ❤️", icon: "❤️", duration: 2.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.isPetting = false
            if self.state == .petting {
                self.transitionTo(.idle)
            }
        }
    }

    // MARK: - Dragging & Drop Physics

    func handleSwiftUIDragChanged(translation: CGSize) {
        guard AppSettings.shared.companionEnabled else { return }
        let mousePos = NSEvent.mouseLocation
        if !isDragging {
            startDragging(at: mousePos)
        } else {
            updateDrag(to: mousePos)
        }
    }

    func handleSwiftUIDragEnded() {
        if isDragging {
            let mousePos = NSEvent.mouseLocation
            endDragging(at: mousePos)
        }
    }

    func startDragging(at mousePos: CGPoint) {
        isDragging = true
        transitionTo(.dangling)
        speak(text: "Whoa, got picked up! 🎢", icon: "🐾", duration: 2.0)
        updateDrag(to: mousePos)
    }

    func updateDrag(to mousePos: CGPoint) {
        guard isDragging else { return }
        currentPosition = CGPoint(x: mousePos.x - 90, y: mousePos.y - 35)
        panel?.setFrameOrigin(currentPosition)

        // Height awareness quotes
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let groundY = screen.minY + 25
        let heightAboveGround = currentPosition.y - groundY

        if heightAboveGround > 260 && stateDuration > 1.8 {
            let highQuotes = [
                "Look at that drop! 🪂",
                "High in the sky! 🦅",
                "Please hold tight! 🎢",
                "Don't drop me! ☁️"
            ]
            speak(text: highQuotes.randomElement() ?? "So high!", icon: "🪂", duration: 2.0)
            stateDuration = 0
        }
    }

    func endDragging(at mousePos: CGPoint) {
        isDragging = false
        isMouseDownOnCompanion = false

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let groundY = screen.minY + 25

        if currentPosition.y > groundY + 12 {
            // Drop down with gravity
            fallVelocity = 0
            transitionTo(.falling)
            speak(text: "Incoming! 🪂", icon: "💨", duration: 1.5)
        } else {
            // Already near ground
            currentPosition.y = groundY
            panel?.setFrameOrigin(currentPosition)
            triggerLanding()
        }
    }

    private func triggerLanding() {
        transitionTo(.landing)
        isLandingDust = true

        let landingQuotes = [
            "Phew! Safe landing! 🌾",
            "Ta-da! ✨",
            "Oof! 💥",
            "Dusty landing! 💨",
            "Back on solid ground! 🐾"
        ]
        speak(text: landingQuotes.randomElement() ?? "Phew!", icon: "💨", duration: 2.5)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.isLandingDust = false
            if self.state == .landing {
                self.transitionTo(.idle)
            }
        }
    }

    func simulateDropTest() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        idleDuration = 0
        currentPosition = CGPoint(x: screen.midX - 90, y: screen.minY + 360)
        panel?.setFrameOrigin(currentPosition)
        fallVelocity = 0
        transitionTo(.falling)
        speak(text: "Dropping from above! 🪂", icon: "💨", duration: 1.5)
    }

    /// Direct trigger for manual testing from Settings
    func triggerAction(_ newState: CompanionState, speechText: String? = nil, icon: String? = nil) {
        idleDuration = 0
        transitionTo(newState)
        if let speechText {
            speak(text: speechText, icon: icon, duration: 3.5)
        }
    }

    // MARK: - Subagents Management & Follower Parade

    func syncSubagents(_ subagents: [ActiveSubagentInfo]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, AppSettings.shared.companionEnabled else { return }

            guard AppSettings.shared.companionSpawnSubagents else {
                for (_, entry) in self.subagentPanels { entry.panel.orderOut(nil) }
                self.subagentPanels.removeAll()
                return
            }

            let currentIDs = Set(subagents.map(\.id))

            // Remove ended subagents
            for (id, entry) in self.subagentPanels where !currentIDs.contains(id) {
                entry.panel.orderOut(nil)
                self.subagentPanels.removeValue(forKey: id)
            }

            // Spawn or update new subagents
            for sub in subagents {
                if self.subagentPanels[sub.id] == nil {
                    let initialOrigin = CGPoint(
                        x: self.currentPosition.x - 50,
                        y: self.currentPosition.y
                    )
                    let p = CompanionPanel(contentRect: NSRect(origin: initialOrigin, size: self.subagentPanelSize))
                    p.contentView = NSHostingView(rootView: SubagentCompanionView(role: sub.role, tool: sub.tool))
                    p.ignoresMouseEvents = AppSettings.shared.companionClickThrough
                    p.orderFront(nil)
                    self.subagentPanels[sub.id] = (panel: p, position: initialOrigin)
                }
            }
        }
    }

    private func updateSubagentsMovement(delta: TimeInterval) {
        let keys = Array(subagentPanels.keys)
        for (index, id) in keys.enumerated() {
            guard var entry = subagentPanels[id] else { continue }
            let spacing: CGFloat = 50.0
            let targetX = currentPosition.x + (facingLeft ? (CGFloat(index + 1) * spacing) : -(CGFloat(index + 1) * spacing))
            let targetY = currentPosition.y + (sin(stateDuration * 3.5 + Double(index)) * 3.0)

            entry.position.x += (targetX - entry.position.x) * 0.12
            entry.position.y += (targetY - entry.position.y) * 0.12
            entry.panel.setFrameOrigin(entry.position)
            subagentPanels[id] = entry
        }
    }

    /// Simulate spawning a test subagent buddy from Settings
    func simulateSubagentBuddy() {
        let testID = "test-subagent-\(UUID().uuidString.prefix(4))"
        let testSub = ActiveSubagentInfo(
            id: testID,
            role: "Audit Agent",
            tool: "security_audit",
            provider: activeProvider,
            lastActive: Date()
        )
        syncSubagents([testSub])

        // Automatically clean up after 8 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            self?.syncSubagents([])
        }
    }
}
