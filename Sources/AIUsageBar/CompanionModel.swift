import Foundation
import SwiftUI

/// High-level behavior state of the companion.
enum CompanionState: String, Equatable {
    case idle
    case walking
    case sprinting
    case working
    case celebrating
    case stretching
    case sleeping
    case petting
    case poked
    case dangling
    case falling
    case landing

    var speedMultiplier: CGFloat {
        switch self {
        case .idle, .sleeping, .working, .celebrating, .stretching, .petting, .poked, .dangling, .falling, .landing: return 0
        case .walking: return 1.0
        case .sprinting: return 2.8
        }
    }
}

/// Active speech bubble message displayed above the companion.
struct CompanionSpeech: Equatable {
    let text: String
    let icon: String?
    let expiresAt: Date
    let isWarning: Bool

    init(text: String, icon: String? = nil, duration: TimeInterval = 4.0, isWarning: Bool = false) {
        self.text = text
        self.icon = icon
        self.expiresAt = Date().addingTimeInterval(duration)
        self.isWarning = isWarning
    }

    var isExpired: Bool {
        Date() > expiresAt
    }
}
