import Foundation

enum LibreWatchDirectStage: String, Equatable {
    case unavailable
    case ready
    case handingOff
    case scanning
    case connecting
    case reconnecting
    case receiving
    case failed
    case returningToPhone
}

/// Presentation only: sensor ownership, Bluetooth progress and measurement freshness
/// are separate facts. In particular, an old reading does not prove a disconnected link.
struct LibreWatchConnectionPresentation: Equatable {
    enum Connection: Equatable {
        case phone, takingOver, searching, connecting, reconnecting, connected
        case returningToPhone, unavailable, failed
    }

    enum Reading: Equatable {
        case notDirect, waiting, current, stale
    }

    enum Emphasis: Equatable {
        case neutral, healthy, attention, failure
    }

    let connection: Connection
    let reading: Reading
    let readingAge: TimeInterval?

    init(ownership: LibreWatchOwnership, stage: LibreWatchDirectStage,
         directReadingAt: Date?, directReadingIsCurrent: Bool, at date: Date) {
        // A retained Watch reading or collector stage must never describe the phone's link.
        guard ownership == .watch else {
            switch ownership {
            case .iphone: connection = stage == .unavailable ? .unavailable : .phone
            case .releasingToWatch: connection = .takingOver
            case .releasingToPhone: connection = .returningToPhone
            case .recovery: connection = .failed
            case .watch: preconditionFailure("Handled by the guard")
            }
            reading = .notDirect
            readingAge = nil
            return
        }

        switch stage {
        case .unavailable: connection = .unavailable
        case .ready, .handingOff: connection = .takingOver
        case .scanning: connection = directReadingAt == nil ? .searching : .reconnecting
        case .connecting: connection = directReadingAt == nil ? .connecting : .reconnecting
        case .reconnecting: connection = .reconnecting
        case .receiving: connection = .connected
        case .failed: connection = .failed
        case .returningToPhone: connection = .returningToPhone
        }

        if let directReadingAt {
            readingAge = max(0, date.timeIntervalSince(directReadingAt))
            reading = directReadingIsCurrent ? .current : .stale
        } else {
            readingAge = nil
            reading = .waiting
        }
    }

    var emphasis: Emphasis {
        switch connection {
        case .failed, .unavailable: return .failure
        case .phone: return .neutral
        case .connected: return reading == .current ? .healthy : .attention
        default: return .attention
        }
    }
}
