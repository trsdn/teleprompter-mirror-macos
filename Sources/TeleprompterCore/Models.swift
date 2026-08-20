import CoreGraphics
import Foundation

public enum DisplayRotation: Int, CaseIterable, Codable, Sendable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270
}

public struct DisplayTransform: Codable, Equatable, Sendable {
    public var rotation: DisplayRotation
    public var mirrorHorizontally: Bool
    public var mirrorVertically: Bool

    public init(
        rotation: DisplayRotation = .degrees0,
        mirrorHorizontally: Bool = true,
        mirrorVertically: Bool = false
    ) {
        self.rotation = rotation
        self.mirrorHorizontally = mirrorHorizontally
        self.mirrorVertically = mirrorVertically
    }

    public static let teleprompterDefault = DisplayTransform()
    public static let identity = DisplayTransform(
        mirrorHorizontally: false
    )
}

public struct PixelSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct FittedRectangle: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct LayerPresentationGeometry: Equatable, Sendable {
    public let sourceBounds: CGRect
    public let affineTransform: CGAffineTransform

    public init(
        sourceBounds: CGRect,
        affineTransform: CGAffineTransform
    ) {
        self.sourceBounds = sourceBounds
        self.affineTransform = affineTransform
    }

    public var presentedExtent: CGRect {
        sourceBounds.applying(affineTransform).standardized
    }
}

public enum TransformGeometry {
    public static func orientedSize(
        sourceWidth: Int,
        sourceHeight: Int,
        rotation: DisplayRotation
    ) -> PixelSize {
        switch rotation {
        case .degrees0, .degrees180:
            return PixelSize(width: sourceWidth, height: sourceHeight)
        case .degrees90, .degrees270:
            return PixelSize(width: sourceHeight, height: sourceWidth)
        }
    }

    public static func aspectFitRectangle(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Double,
        targetHeight: Double,
        rotation: DisplayRotation
    ) -> FittedRectangle {
        let oriented = orientedSize(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            rotation: rotation
        )
        guard oriented.width > 0,
              oriented.height > 0,
              targetWidth > 0,
              targetHeight > 0 else {
            return FittedRectangle(x: 0, y: 0, width: 0, height: 0)
        }

        let scale = min(
            targetWidth / Double(oriented.width),
            targetHeight / Double(oriented.height)
        )
        let width = Double(oriented.width) * scale
        let height = Double(oriented.height) * scale
        return FittedRectangle(
            x: (targetWidth - width) / 2,
            y: (targetHeight - height) / 2,
            width: width,
            height: height
        )
    }

    public static func layerPresentationGeometry(
        sourceWidth: Int,
        sourceHeight: Int,
        targetBounds: CGRect,
        transform displayTransform: DisplayTransform
    ) -> LayerPresentationGeometry? {
        guard sourceWidth > 0,
              sourceHeight > 0,
              targetBounds.width > 0,
              targetBounds.height > 0 else {
            return nil
        }

        let sourceBounds = CGRect(
            x: 0,
            y: 0,
            width: sourceWidth,
            height: sourceHeight
        )
        return LayerPresentationGeometry(
            sourceBounds: sourceBounds,
            affineTransform: affineTransform(
                sourceExtent: sourceBounds,
                targetBounds: targetBounds,
                transform: displayTransform
            )
        )
    }

    public static func orientedAffineTransform(
        sourceExtent: CGRect,
        transform displayTransform: DisplayTransform
    ) -> CGAffineTransform {
        guard sourceExtent.width > 0,
              sourceExtent.height > 0 else {
            return .identity
        }

        let angle: CGFloat = switch displayTransform.rotation {
        case .degrees0: 0
        case .degrees90: -.pi / 2
        case .degrees180: .pi
        case .degrees270: .pi / 2
        }

        var affine = CGAffineTransform(rotationAngle: angle)
        var extent = sourceExtent.applying(affine).standardized
        affine = affine.concatenating(
            CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )
        extent = sourceExtent.applying(affine).standardized

        if displayTransform.mirrorHorizontally {
            affine = affine.concatenating(
                CGAffineTransform(
                    translationX: extent.width,
                    y: 0
                )
                .scaledBy(x: -1, y: 1)
            )
        }
        if displayTransform.mirrorVertically {
            affine = affine.concatenating(
                CGAffineTransform(
                    translationX: 0,
                    y: extent.height
                )
                .scaledBy(x: 1, y: -1)
            )
        }

        extent = sourceExtent.applying(affine).standardized
        return affine.concatenating(
            CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )
    }

    public static func affineTransform(
        sourceExtent: CGRect,
        targetBounds: CGRect,
        transform displayTransform: DisplayTransform
    ) -> CGAffineTransform {
        guard sourceExtent.width > 0,
              sourceExtent.height > 0,
              targetBounds.width > 0,
              targetBounds.height > 0 else {
            return .identity
        }

        var affine = orientedAffineTransform(
            sourceExtent: sourceExtent,
            transform: displayTransform
        )
        var extent = sourceExtent.applying(affine).standardized
        let scale = min(
            targetBounds.width / extent.width,
            targetBounds.height / extent.height
        )
        affine = affine.concatenating(
            CGAffineTransform(scaleX: scale, y: scale)
        )

        extent = sourceExtent.applying(affine).standardized
        return affine.concatenating(
            CGAffineTransform(
                translationX: targetBounds.midX - extent.midX,
                y: targetBounds.midY - extent.midY
            )
        )
    }
}

public struct PersistentDisplayIdentity: Codable, Equatable, Hashable, Sendable {
    public let vendorID: UInt32?
    public let productID: UInt32?
    public let serialNumber: UInt32?
    public let displayUUID: String?
    public let localizedName: String
    public let nativeLongEdge: Int
    public let nativeShortEdge: Int

    public init(
        vendorID: UInt32?,
        productID: UInt32?,
        serialNumber: UInt32?,
        displayUUID: String? = nil,
        localizedName: String,
        nativePixelWidth: Int,
        nativePixelHeight: Int
    ) {
        self.vendorID = vendorID.flatMap { $0 == 0 ? nil : $0 }
        self.productID = productID.flatMap { $0 == 0 ? nil : $0 }
        self.serialNumber = serialNumber.flatMap { $0 == 0 ? nil : $0 }
        self.displayUUID = displayUUID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .nilIfEmpty
        self.localizedName = localizedName
        nativeLongEdge = max(nativePixelWidth, nativePixelHeight)
        nativeShortEdge = min(nativePixelWidth, nativePixelHeight)
    }

    fileprivate var normalizedName: String {
        localizedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    fileprivate var normalizedUUID: String? {
        displayUUID?.uppercased()
    }
}

public enum DisplayIdentityMatcher {
    public static func uniqueMatch(
        for stored: PersistentDisplayIdentity,
        among candidates: [PersistentDisplayIdentity]
    ) -> Int? {
        let scored = candidates.enumerated().compactMap { index, candidate in
            score(stored: stored, candidate: candidate).map {
                (index: index, score: $0)
            }
        }
        guard let bestScore = scored.map(\.score).max() else {
            return nil
        }
        let best = scored.filter { $0.score == bestScore }
        return best.count == 1 ? best[0].index : nil
    }

    private static func score(
        stored: PersistentDisplayIdentity,
        candidate: PersistentDisplayIdentity
    ) -> Int? {
        let storedHardware = hardwarePair(stored)
        let candidateHardware = hardwarePair(candidate)

        if storedHardware != nil, candidateHardware == nil {
            return nil
        }
        if stored.serialNumber != nil, candidate.serialNumber == nil {
            return nil
        }
        if let storedSerial = stored.serialNumber,
           let candidateSerial = candidate.serialNumber {
            guard storedSerial == candidateSerial,
                  storedHardware == candidateHardware else {
                return nil
            }
            return 400
        }

        if stored.normalizedUUID != nil, candidate.normalizedUUID == nil {
            return nil
        }
        if let storedUUID = stored.normalizedUUID,
           let candidateUUID = candidate.normalizedUUID {
            if let storedHardware, let candidateHardware,
               storedHardware != candidateHardware {
                return nil
            }
            guard storedUUID == candidateUUID else {
                return nil
            }
            return storedHardware == candidateHardware ? 350 : 325
        }

        if let storedHardware, let candidateHardware,
           storedHardware != candidateHardware {
            return nil
        }

        let fallbackMatches =
            !stored.normalizedName.isEmpty
            && stored.normalizedName == candidate.normalizedName
            && stored.nativeLongEdge == candidate.nativeLongEdge
            && stored.nativeShortEdge == candidate.nativeShortEdge

        if storedHardware != nil, storedHardware == candidateHardware {
            return fallbackMatches ? 220 : nil
        }
        return fallbackMatches ? 100 : nil
    }

    private static func hardwarePair(
        _ identity: PersistentDisplayIdentity
    ) -> [UInt32]? {
        guard let vendorID = identity.vendorID,
              let productID = identity.productID else {
            return nil
        }
        return [vendorID, productID]
    }
}

/// Where the mirrored image comes from. The private virtual display stays the
/// default for a classic teleprompter setup, but an existing physical display
/// or a single window can be mirrored instead — the latter two need no private
/// API and stay fully visible while working.
public enum CaptureSourceKind: String, Codable, CaseIterable, Sendable {
    case virtualDisplay
    case display
    case window

    public var localizedName: String {
        switch self {
        case .virtualDisplay:
            return "Virtueller Monitor"
        case .display:
            return "Monitor"
        case .window:
            return "Fenster"
        }
    }
}

/// A window is identified by its owning application plus its title. Window IDs
/// are per-launch handles and are therefore never persisted.
public struct WindowIdentity: Codable, Equatable, Hashable, Sendable {
    public let bundleIdentifier: String?
    public let applicationName: String
    public let title: String?

    public init(
        bundleIdentifier: String?,
        applicationName: String,
        title: String?
    ) {
        self.bundleIdentifier = bundleIdentifier?.nilIfEmpty
        self.applicationName = applicationName
        self.title = title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    public var localizedName: String {
        guard let title else {
            return applicationName
        }
        return "\(applicationName) — \(title)"
    }
}

public enum WindowIdentityMatcher {
    /// Returns an index only when exactly one candidate is the best match, so
    /// an ambiguous set of same-titled windows never selects one at random.
    public static func uniqueMatch(
        for stored: WindowIdentity,
        among candidates: [WindowIdentity]
    ) -> Int? {
        let scored = candidates.enumerated().compactMap { index, candidate in
            score(stored: stored, candidate: candidate).map {
                (index: index, score: $0)
            }
        }
        guard let bestScore = scored.map(\.score).max() else {
            return nil
        }
        let best = scored.filter { $0.score == bestScore }
        return best.count == 1 ? best[0].index : nil
    }

    private static func score(
        stored: WindowIdentity,
        candidate: WindowIdentity
    ) -> Int? {
        if let storedBundle = stored.bundleIdentifier,
           let candidateBundle = candidate.bundleIdentifier,
           storedBundle != candidateBundle {
            return nil
        }
        if stored.bundleIdentifier == nil || candidate.bundleIdentifier == nil,
           stored.applicationName != candidate.applicationName {
            return nil
        }
        if let storedTitle = stored.title {
            guard let candidateTitle = candidate.title else {
                return 100
            }
            return storedTitle == candidateTitle ? 300 : 100
        }
        return 200
    }
}

public struct CaptureSourceSelection: Codable, Equatable, Sendable {
    public var kind: CaptureSourceKind
    /// Remembered physical source display; only used when `kind == .display`.
    public var display: PersistentDisplayIdentity?
    /// Remembered window; only used when `kind == .window`.
    public var window: WindowIdentity?

    public init(
        kind: CaptureSourceKind = .virtualDisplay,
        display: PersistentDisplayIdentity? = nil,
        window: WindowIdentity? = nil
    ) {
        self.kind = kind
        self.display = display
        self.window = window
    }

    public static let virtualDisplay = CaptureSourceSelection()

    /// True when the selection carries everything the chosen kind needs.
    public var isComplete: Bool {
        switch kind {
        case .virtualDisplay:
            return true
        case .display:
            return display != nil
        case .window:
            return window != nil
        }
    }
}

public struct TeleprompterConfiguration: Codable, Equatable, Sendable {
    /// What is captured and mirrored.
    public var source: CaptureSourceSelection
    /// The physical display that shows the transformed teleprompter image.
    public var target: PersistentDisplayIdentity?
    public var transform: DisplayTransform

    public init(
        source: CaptureSourceSelection = .virtualDisplay,
        target: PersistentDisplayIdentity? = nil,
        transform: DisplayTransform = .teleprompterDefault
    ) {
        self.source = source
        self.target = target
        self.transform = transform
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case target
        case display
        case transform
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let target = try container.decodeIfPresent(
            PersistentDisplayIdentity.self,
            forKey: .target
        )
        // Two earlier builds stored a bare display identity under `display`:
        // the same-display build meant the output target, the virtual-source
        // build did not write it at all. Decoding it as the target preserves
        // the user's monitor choice; a modern `source` object wins.
        let legacyDisplay = try? container.decodeIfPresent(
            PersistentDisplayIdentity.self,
            forKey: .display
        )
        self.target = target ?? legacyDisplay
        source = try container.decodeIfPresent(
            CaptureSourceSelection.self,
            forKey: .source
        ) ?? .virtualDisplay
        transform = try container.decodeIfPresent(
            DisplayTransform.self,
            forKey: .transform
        ) ?? .teleprompterDefault
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encode(transform, forKey: .transform)
    }

    public func resolvedTargetIndex(
        among candidates: [PersistentDisplayIdentity]
    ) -> Int? {
        guard let target else {
            return nil
        }
        return DisplayIdentityMatcher.uniqueMatch(
            for: target,
            among: candidates
        )
    }
}

/// Legacy container for the three preset slots written by schema version 1.
/// Only used to migrate an existing installation to the single configuration.
private struct LegacyPresetSlot: Codable {
    var name: String?
    var configuration: TeleprompterConfiguration?
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var configuration: TeleprompterConfiguration
    public var autoStartOutput: Bool

    public init(
        schemaVersion: Int = currentSchemaVersion,
        configuration: TeleprompterConfiguration = .init(),
        autoStartOutput: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.configuration = configuration
        self.autoStartOutput = autoStartOutput
    }

    public static var defaults: AppSettings {
        AppSettings()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case configuration
        case activePresetIndex
        case presets
        case autoStartOutput
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? 1
        autoStartOutput = try container.decodeIfPresent(
            Bool.self,
            forKey: .autoStartOutput
        ) ?? false

        if let configuration = try container.decodeIfPresent(
            TeleprompterConfiguration.self,
            forKey: .configuration
        ) {
            self.configuration = configuration
            return
        }

        // Schema version 1 stored three slots; carry over the one that was
        // active so an upgrade keeps the setup the user last worked with.
        let presets = try container.decodeIfPresent(
            [LegacyPresetSlot].self,
            forKey: .presets
        ) ?? []
        let index = try container.decodeIfPresent(
            Int.self,
            forKey: .activePresetIndex
        ) ?? 0
        let active = presets.indices.contains(index)
            ? presets[index].configuration
            : presets.compactMap(\.configuration).first
        configuration = active ?? TeleprompterConfiguration()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(autoStartOutput, forKey: .autoStartOutput)
    }

    public func normalized() -> AppSettings {
        var result = self
        result.schemaVersion = Self.currentSchemaVersion
        switch result.configuration.source.kind {
        case .virtualDisplay:
            result.configuration.source.display = nil
            result.configuration.source.window = nil
        case .display:
            result.configuration.source.window = nil
        case .window:
            result.configuration.source.display = nil
        }
        return result
    }
}

public enum AppSettingsCodec {
    public static func encode(_ settings: AppSettings) throws -> Data {
        try JSONEncoder().encode(settings.normalized())
    }

    public static func decode(_ data: Data) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: data).normalized()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
