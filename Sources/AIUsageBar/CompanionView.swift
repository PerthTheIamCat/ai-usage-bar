import SwiftUI

/// SwiftUI view that renders the animated 8-bit character, ground shadow, and speech bubble.
struct CompanionView: View {
    @ObservedObject var manager: CompanionManager

    var body: some View {
        VStack(spacing: 2) {
            // Speech Bubble
            if let speech = manager.currentSpeech, !speech.isExpired {
                speechBubble(speech)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else if manager.state == .sleeping {
                Text("zZz...")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Capsule())
                    .transition(.opacity)
            } else if manager.isPetting {
                HStack(spacing: 4) {
                    Text("❤️")
                        .font(.system(size: 12))
                        .offset(y: -2)
                    Text("💕")
                        .font(.system(size: 9))
                        .offset(y: -5)
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                Spacer().frame(height: 22)
            }

            // Character & Ground Shadow
            ZStack(alignment: .bottom) {
                // Dynamic ground shadow
                Ellipse()
                    .fill(Color.black.opacity(0.2))
                    .frame(
                        width: manager.isLandingDust ? 38 : (manager.state == .dangling || manager.state == .falling ? 16 : 28),
                        height: manager.isLandingDust ? 8 : (manager.state == .dangling || manager.state == .falling ? 4 : 6)
                    )
                    .offset(y: 2)

                // Dust blow puffs upon landing
                if manager.isLandingDust {
                    HStack(spacing: 34) {
                        Text("💨")
                            .font(.system(size: 14))
                            .offset(x: -6, y: -1)
                            .scaleEffect(x: -1, y: 1) // facing left outwards
                        Text("💨")
                            .font(.system(size: 14))
                            .offset(x: 6, y: -1)
                    }
                    .transition(.scale.combined(with: .opacity))
                }

                // 8-bit Animated Sprite
                PixelFrameView(
                    frame: manager.currentFrame,
                    pixelSize: 3.0,
                    flipHorizontal: manager.facingLeft
                )
                .offset(y: manager.isPokedJump ? -15 : (manager.state == .landing ? 3 : 0))
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: manager.isPokedJump)
            }
            .frame(width: 60, height: 60)
        }
        .frame(width: 180, height: 110)
        .contentShape(Rectangle())
        .onTapGesture {
            manager.poke()
        }
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { val in
                    manager.handleSwiftUIDragChanged(translation: val.translation)
                }
                .onEnded { _ in
                    manager.handleSwiftUIDragEnded()
                }
        )
    }

    @ViewBuilder
    private func speechBubble(_ speech: CompanionSpeech) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if let icon = speech.icon {
                    Text(icon)
                        .font(.system(size: 11))
                }
                Text(speech.text)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(speech.isWarning ? .yellow : .white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(speech.isWarning ? Color.yellow.opacity(0.8) : Color.white.opacity(0.3), lineWidth: 1)
                    )
            )

            // Speech bubble tail pointing downward
            Image(systemName: "arrowtriangle.down.fill")
                .resizable()
                .frame(width: 8, height: 5)
                .foregroundColor(Color.black.opacity(0.85))
                .offset(y: -1)
        }
    }
}

/// SwiftUI view rendering a follower subagent companion (mini Junimo/helper).
struct SubagentCompanionView: View {
    let role: String
    let tool: String?
    @State private var frameIndex = 0
    @State private var timer: Timer?

    private let frames = [PixelSpriteLibrary.junimoHop1, PixelSpriteLibrary.junimoHop2]

    var body: some View {
        VStack(spacing: 2) {
            // Action badge
            HStack(spacing: 3) {
                Text(tool != nil ? "🔧" : "🛡️")
                    .font(.system(size: 8))
                Text(tool ?? role)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.85))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.green.opacity(0.6), lineWidth: 1))

            // Mini Sprite
            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(Color.black.opacity(0.2))
                    .frame(width: 20, height: 4)
                    .offset(y: 2)

                let current = frames.indices.contains(frameIndex) ? frames[frameIndex] : frames[0]
                PixelFrameView(frame: current, pixelSize: 2.2)
            }
            .frame(width: 40, height: 35)

            // Role label
            Text(role)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.blue.opacity(0.8))
                .clipShape(Capsule())
        }
        .frame(width: 140, height: 90)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                frameIndex = (frameIndex + 1) % frames.count
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}
