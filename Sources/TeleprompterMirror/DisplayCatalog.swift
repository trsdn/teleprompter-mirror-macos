import AppKit
import CoreGraphics
import ScreenCaptureKit
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

@MainActor
struct ResolvedDisplaySnapshot {
    let descriptor: DisplayDescriptor
    let cgDisplayID: CGDirectDisplayID
    let scDisplay: SCDisplay
    let nsScreen: NSScreen
    let ownApplication: SCRunningApplication

    var maximumOutputDimension: Int {
        max(descriptor.pixelWidth, descriptor.pixelHeight)
    }
}

enum DisplayResolutionError: LocalizedError {
    case displayUnavailable
    case screenCaptureDisplayUnavailable
    case processExclusionUnavailable
    case configurationChanged

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            return "Der gewählte Monitor ist nicht eindeutig verbunden."
        case .screenCaptureDisplayUnavailable:
            return "Der gewählte Monitor ist für ScreenCaptureKit nicht verfügbar."
        case .processExclusionUnavailable:
            return "Die eigene App konnte nicht sicher aus der Aufnahme ausgeschlossen werden."
        case .configurationChanged:
            return "Die Monitorkonfiguration hat sich während des Starts geändert."
        }
    }
}

@MainActor
enum DisplayCatalog {
    static func connectedDisplays() -> [DisplayDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else {
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

    static func makeResolvedSnapshot(
        for identity: PersistentDisplayIdentity
    ) async throws -> ResolvedDisplaySnapshot {
        WindowPrivacyController.protectAllAppWindows()
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return try resolvedSnapshot(for: identity, content: content)
    }

    static func revalidate(_ snapshot: ResolvedDisplaySnapshot) async throws {
        WindowPrivacyController.protectAllAppWindows()
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let current = try resolvedSnapshot(
            for: snapshot.descriptor.identity,
            content: content
        )
        guard current.cgDisplayID == snapshot.cgDisplayID,
              current.descriptor.pixelWidth
                == snapshot.descriptor.pixelWidth,
              current.descriptor.pixelHeight
                == snapshot.descriptor.pixelHeight,
              current.descriptor.frame == snapshot.descriptor.frame else {
            throw DisplayResolutionError.configurationChanged
        }
    }

    private static func resolvedSnapshot(
        for identity: PersistentDisplayIdentity,
        content: SCShareableContent
    ) throws -> ResolvedDisplaySnapshot {
        let displays = connectedDisplays()
        guard let descriptor = resolve(identity, among: displays),
              let screen = NSScreen.screens.first(where: {
                  $0.displayID == descriptor.id
              }) else {
            throw DisplayResolutionError.displayUnavailable
        }
        guard let captureDisplay = content.displays.first(where: {
            $0.displayID == descriptor.id
        }) else {
            throw DisplayResolutionError.screenCaptureDisplayUnavailable
        }
        let ownApplications = content.applications.filter {
            $0.processID == getpid()
        }
        guard ownApplications.count == 1,
              let ownApplication = ownApplications.first else {
            throw DisplayResolutionError.processExclusionUnavailable
        }

        return ResolvedDisplaySnapshot(
            descriptor: descriptor,
            cgDisplayID: descriptor.id,
            scDisplay: captureDisplay,
            nsScreen: screen,
            ownApplication: ownApplication
        )
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

@MainActor
enum WindowPrivacyController {
    static func protectAllAppWindows() {
        for window in NSApplication.shared.windows {
            window.sharingType = .none
        }
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
