import CoreGraphics
import Foundation

/// Called by the portable host for the display it just created, before choosing the capture source.
enum MacBookLayout {
    struct Screen {
        let id: CGDirectDisplayID
        let builtin: Bool
        let awake: Bool
        let drawable: Bool
        let main: Bool
        let mirrorOf: CGDirectDisplayID
        let hardwarePrimary: CGDirectDisplayID
        let bounds: CGRect
    }

    struct Change: Equatable {
        let unmirror: CGDirectDisplayID?
        let makeMain: CGDirectDisplayID?
        let x: Int32
        let y: Int32
    }

    enum Failure: Error, LocalizedError {
        case invalidSnapshot, conflictingMirrors, didNotSettle
        case quartz(CGError)

        var errorDescription: String? {
            switch self {
            case .invalidSnapshot: NSLocalizedString("Could not determine the layout of the iPad and the built-in display.", comment: "")
            case .conflictingMirrors: NSLocalizedString("Another display is mirroring the iPad. Adjust mirroring in Displays settings.", comment: "")
            case .didNotSettle: NSLocalizedString("macOS could not set the iPad as an extended display.", comment: "")
            case .quartz(let error): String(format: NSLocalizedString("macOS display configuration error (%@).", comment: ""), String(error.rawValue))
            }
        }
    }

    static func plan(_ screens: [Screen], ownedID: CGDirectDisplayID) throws -> Change? {
        guard let ipad = screens.first(where: { $0.id == ownedID }), !ipad.builtin else {
            throw Failure.invalidSnapshot
        }
        guard let panel = screens.first(where: {
            $0.builtin && $0.awake && ($0.drawable || $0.mirrorOf != 0)
        }) else { return nil }
        guard let primary = screens.first(where: { $0.main }) else { throw Failure.invalidSnapshot }

        // A third-party follower would still be showing the iPad's desktop.
        // Leave the other screens' groups under the user's control.
        if screens.contains(where: { $0.id != panel.id && $0.mirrorOf == ownedID }) {
            throw Failure.conflictingMirrors
        }
        let panelFollowsIPad = panel.mirrorOf == ownedID
        let ipadMirrored = ipad.mirrorOf != 0 || ipad.hardwarePrimary != ownedID
        guard ipadMirrored || panelFollowsIPad || primary.id == ownedID else {
            return nil  // also preserves a previously chosen left/above arrangement
        }
        let anchor: Screen
        if primary.id == ownedID, panel.mirrorOf != 0, !panelFollowsIPad {
            guard let leader = screens.first(where: { $0.id == panel.mirrorOf }) else {
                throw Failure.invalidSnapshot
            }
            anchor = leader
        } else {
            anchor = primary.id == ownedID ? panel : primary
        }
        let otherScreens = screens.filter {
            $0.id != ownedID && $0.awake && ($0.id == panel.id || ($0.drawable && $0.mirrorOf == 0))
        }
        guard let rightmost = otherScreens.max(by: { $0.bounds.maxX < $1.bounds.maxX }),
              rightmost.bounds.width > 0, rightmost.bounds.height > 0,
              let x = Int32(exactly: rightmost.bounds.maxX - anchor.bounds.minX),
              let y = Int32(exactly: rightmost.bounds.minY - anchor.bounds.minY) else {
            throw Failure.invalidSnapshot
        }
        return Change(unmirror: panelFollowsIPad ? panel.id : (ipadMirrored ? ownedID : nil),
                      makeMain: primary.id == ownedID ? anchor.id : nil, x: x, y: y)
    }

    private static func snapshot() throws -> [Screen] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            throw Failure.invalidSnapshot
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { throw Failure.invalidSnapshot }
        return ids.prefix(Int(count)).map { id in
            Screen(id: id, builtin: CGDisplayIsBuiltin(id) != 0, awake: CGDisplayIsAsleep(id) == 0,
                   drawable: CGDisplayIsActive(id) != 0, main: CGDisplayIsMain(id) != 0,
                   mirrorOf: CGDisplayMirrorsDisplay(id), hardwarePrimary: CGDisplayPrimaryDisplay(id),
                   bounds: CGDisplayBounds(id))
        }
    }

    static func extendIfNeeded(displayID: CGDirectDisplayID) throws {
        // The ID is the session's own handle. Never select a target by name or geometry.
        guard CGDisplayVendorNumber(displayID) == 0x5744, CGDisplayModelNumber(displayID) == 1 else {
            throw Failure.invalidSnapshot
        }
        guard let change = try plan(snapshot(), ownedID: displayID) else { return }
        var transaction: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&transaction)
        guard begun == .success, let transaction else { throw Failure.quartz(begun) }
        func stage(_ result: CGError) throws {
            guard result == .success else {
                CGCancelDisplayConfiguration(transaction)
                throw Failure.quartz(result)
            }
        }
        if let follower = change.unmirror {
            try stage(CGConfigureDisplayMirrorOfDisplay(transaction, follower, kCGNullDirectDisplay))
        }
        if let primary = change.makeMain {
            try stage(CGConfigureDisplayOrigin(transaction, primary, 0, 0))
        }
        try stage(CGConfigureDisplayOrigin(transaction, displayID, change.x, change.y))
        let result = CGCompleteDisplayConfiguration(transaction, .forSession)
        guard result == .success else { throw Failure.quartz(result) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        repeat {
            if try plan(snapshot(), ownedID: displayID) == nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Failure.didNotSettle
    }
}
