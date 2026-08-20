import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import TeleprompterCore

struct DisplayDescriptor: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let frame: CGRect
    let identity: PersistentDisplayIdentity

    var label: String {
        "\(name) — \(pixelWidth)×\(pixelHeight)"
    }
}

/// An immutable, validated pairing of the virtual capture source and the
/// physical output target. The source is always the private virtual display;
/// the target is a physical `NSScreen` that shows the transformed image.
@MainActor
struct ResolvedDisplaySnapshot {
    let sourceDisplayID: CGDirectDisplayID
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceCaptureDisplay: SCDisplay
    let targetDescriptor: DisplayDescriptor
    let targetScreen: NSScreen
}

enum DisplayResolutionError: LocalizedError {
    case virtualSourceUnavailable
    case screenCaptureSourceUnavailable(CGDirectDisplayID)
    case targetDisplayUnavailable
    case configurationChanged

    var errorDescription: String? {
        switch self {
        case .virtualSourceUnavailable:
            return "Der virtuelle Quellmonitor ist für die Bildschirmaufnahme nicht verfügbar."
        case let .screenCaptureSourceUnavailable(displayID):
            return "ScreenCaptureKit hat den virtuellen Quellmonitor mit ID \(displayID) nicht gefunden."
        case .targetDisplayUnavailable:
            return "Der gewählte Zielmonitor ist nicht eindeutig verbunden."
        case .configurationChanged:
            return "Die Monitorkonfiguration hat sich während des Starts geändert."
        }
    }
}

@MainActor
enum DisplayCatalog {
    /// Physical displays eligible as output targets. The virtual source is
    /// never listed, so the user can never mirror the source onto itself.
    static func connectedDisplays(
        excluding excludedID: CGDirectDisplayID?
    ) -> [DisplayDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID,
                  displayID != excludedID,
                  CGDisplayVendorNumber(displayID) != 0x544D else {
                return nil
            }

            let currentMode = CGDisplayCopyDisplayMode(displayID)
            let nativeMode =
                (CGDisplayCopyAllDisplayModes(displayID, nil)
                    as? [CGDisplayMode])?
                    .max {
                        ($0.pixelWidth * $0.pixelHeight)
                            < ($1.pixelWidth * $1.pixelHeight)
                    }
            let nativeWidth = nativeMode?.pixelWidth
                ?? currentMode?.pixelWidth
                ?? CGDisplayPixelsWide(displayID)
            let nativeHeight = nativeMode?.pixelHeight
                ?? currentMode?.pixelHeight
                ?? CGDisplayPixelsHigh(displayID)

            return DisplayDescriptor(
                id: displayID,
                name: screen.localizedName,
                pixelWidth: CGDisplayPixelsWide(displayID),
                pixelHeight: CGDisplayPixelsHigh(displayID),
                frame: screen.frame,
                identity: PersistentDisplayIdentity(
                    vendorID: CGDisplayVendorNumber(displayID),
                    productID: CGDisplayModelNumber(displayID),
                    serialNumber: CGDisplaySerialNumber(displayID),
                    displayUUID: displayUUID(for: displayID),
                    localizedName: screen.localizedName,
                    nativePixelWidth: nativeWidth,
                    nativePixelHeight: nativeHeight
                )
            )
        }
        .sorted {
            if $0.name == $1.name {
                return $0.id < $1.id
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func resolve(
        _ identity: PersistentDisplayIdentity?,
        among displays: [DisplayDescriptor]
    ) -> DisplayDescriptor? {
        guard let identity,
              let index = DisplayIdentityMatcher.uniqueMatch(
                for: identity,
                among: displays.map(\.identity)
              ) else {
            return nil
        }
        return displays[index]
    }

    /// Fallback target when no saved target resolves: the display named
    /// `preferredName` (AAA) if present, otherwise the smallest external
    /// display, otherwise the smallest connected display.
    static func defaultTarget(
        among displays: [DisplayDescriptor],
        preferredName: String
    ) -> DisplayDescriptor? {
        if let named = displays.first(where: {
            $0.name.compare(
                preferredName,
                options: [.caseInsensitive]
            ) == .orderedSame
        }) {
            return named
        }

        let externals = displays.filter { CGDisplayIsBuiltin($0.id) == 0 }
        let pool = externals.isEmpty ? displays : externals
        return pool.min {
            ($0.pixelWidth * $0.pixelHeight)
                < ($1.pixelWidth * $1.pixelHeight)
        }
    }

    static func makeResolvedSnapshot(
        virtualDisplayID: CGDirectDisplayID,
        sourceWidth: Int,
        sourceHeight: Int,
        target: DisplayDescriptor
    ) async throws -> ResolvedDisplaySnapshot {
        guard onlineDisplayIDs().contains(virtualDisplayID) else {
            throw DisplayResolutionError.virtualSourceUnavailable
        }
        let captureDisplay = try await screenCaptureDisplay(
            matching: virtualDisplayID
        )
        // On macOS 26 a newly published CGVirtualDisplay can already appear in
        // SCShareableContent while its capture framebuffer is not ready yet.
        // Starting SCStream in that interval succeeds but never emits frames.
        try await Task.sleep(for: .seconds(5))
        guard let screen = NSScreen.screens.first(where: {
            $0.displayID == target.id
        }) else {
            throw DisplayResolutionError.targetDisplayUnavailable
        }

        return ResolvedDisplaySnapshot(
            sourceDisplayID: virtualDisplayID,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceCaptureDisplay: captureDisplay,
            targetDescriptor: target,
            targetScreen: screen
        )
    }

    static func revalidate(
        _ snapshot: ResolvedDisplaySnapshot,
        virtualDisplayID: CGDirectDisplayID
    ) async throws {
        guard snapshot.sourceDisplayID == virtualDisplayID,
              onlineDisplayIDs().contains(virtualDisplayID) else {
            throw DisplayResolutionError.virtualSourceUnavailable
        }

        let physical = connectedDisplays(excluding: virtualDisplayID)
        guard let current = physical.first(where: {
            $0.id == snapshot.targetDescriptor.id
        }),
        current.pixelWidth == snapshot.targetDescriptor.pixelWidth,
        current.pixelHeight == snapshot.targetDescriptor.pixelHeight,
        current.frame == snapshot.targetDescriptor.frame else {
            throw DisplayResolutionError.configurationChanged
        }
    }

    /// The set of currently online `CGDirectDisplayID`s, including the private
    /// virtual source. Empty when the list cannot be queried.
    private static func onlineDisplayIDs() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual: UInt32 = 0
        guard CGGetOnlineDisplayList(count, &ids, &actual) == .success else {
            return []
        }
        return Set(ids.prefix(Int(actual)))
    }

    /// Resolves only the retained virtual display's live ID. Newly created
    /// virtual displays can take a short time to appear in ScreenCaptureKit,
    /// so enumeration is retried briefly but never falls back to a name,
    /// position, or another display.
    private static func screenCaptureDisplay(
        matching displayID: CGDirectDisplayID
    ) async throws -> SCDisplay {
        let maximumAttempts = 8
        var lastEnumerationError: (any Error)?

        for attempt in 1...maximumAttempts {
            do {
                let content =
                    try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: false
                    )
                if let display = content.displays.first(where: {
                    $0.displayID == displayID
                }) {
                    return display
                }
                lastEnumerationError = nil
            } catch {
                lastEnumerationError = error
            }

            if attempt < maximumAttempts {
                try await Task.sleep(for: .milliseconds(125))
            }
        }

        if let lastEnumerationError {
            NSLog(
                "ScreenCaptureKit-Aufzählung für Display %u fehlgeschlagen: %@",
                displayID,
                lastEnumerationError.localizedDescription
            )
        }
        throw DisplayResolutionError.screenCaptureSourceUnavailable(displayID)
    }

    private static func displayUUID(
        for displayID: CGDirectDisplayID
    ) -> String? {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID)
        else {
            return nil
        }
        let uuid = unmanagedUUID.takeRetainedValue()
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
