import Foundation
import Testing
@testable import TeleprompterCore

@Test("Teleprompter default mirrors horizontally at zero degrees")
func teleprompterDefaultTransform() {
    let value = DisplayTransform.teleprompterDefault

    #expect(value.rotation == .degrees0)
    #expect(value.mirrorHorizontally)
    #expect(!value.mirrorVertically)
}

@Test("Transform values survive Codable round trips")
func transformCodableRoundTrip() throws {
    for rotation in DisplayRotation.allCases {
        let original = DisplayTransform(
            rotation: rotation,
            mirrorHorizontally: true,
            mirrorVertically: rotation.rawValue.isMultiple(of: 180)
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(
            DisplayTransform.self,
            from: data
        ) == original)
    }
}

@Test("Display identity prefers exact hardware serial")
func displayIdentityUsesSerial() {
    let stored = identity(serial: 42, uuid: "A", name: "Monitor A")
    let candidates = [
        identity(serial: 7, uuid: "A", name: "Monitor A"),
        identity(serial: 42, uuid: "B", name: "Umbenannt")
    ]

    #expect(
        DisplayIdentityMatcher.uniqueMatch(
            for: stored,
            among: candidates
        ) == 1
    )
}

@Test("Display UUID is a stable fallback when serial is absent")
func displayIdentityUsesUUID() {
    let stored = identity(serial: nil, uuid: "ABC", name: "Monitor")
    let candidates = [
        identity(serial: nil, uuid: "DEF", name: "Monitor"),
        identity(serial: nil, uuid: "abc", name: "Anderer Name")
    ]

    #expect(
        DisplayIdentityMatcher.uniqueMatch(
            for: stored,
            among: candidates
        ) == 1
    )
}

@Test("Stored serial and UUID identities never downgrade")
func displayIdentityDoesNotDowngrade() {
    let withSerial = identity(serial: 42, uuid: nil, name: "Monitor")
    let withUUID = identity(serial: nil, uuid: "ABC", name: "Monitor")
    let weak = identity(serial: nil, uuid: nil, name: "Monitor")

    #expect(DisplayIdentityMatcher.uniqueMatch(
        for: withSerial,
        among: [weak]
    ) == nil)
    #expect(DisplayIdentityMatcher.uniqueMatch(
        for: withUUID,
        among: [weak]
    ) == nil)
}

@Test("Known conflicting hardware rejects an equal UUID")
func displayUUIDRejectsHardwareConflict() {
    let stored = identity(
        vendor: 10,
        product: 20,
        serial: nil,
        uuid: "ABC",
        name: "Monitor"
    )
    let conflicting = identity(
        vendor: 10,
        product: 21,
        serial: nil,
        uuid: "ABC",
        name: "Monitor"
    )

    #expect(DisplayIdentityMatcher.uniqueMatch(
        for: stored,
        among: [conflicting]
    ) == nil)
}

@Test("Vendor and product alone never select a replacement display")
func hardwareModelAloneIsInsufficient() {
    let stored = identity(
        vendor: 10,
        product: 20,
        serial: nil,
        uuid: nil,
        name: "Alter Monitor",
        width: 1920,
        height: 1080
    )
    let replacement = identity(
        vendor: 10,
        product: 20,
        serial: nil,
        uuid: nil,
        name: "Neuer Monitor",
        width: 2560,
        height: 1440
    )

    #expect(DisplayIdentityMatcher.uniqueMatch(
        for: stored,
        among: [replacement]
    ) == nil)
}

@Test("Stored vendor and product never downgrade to name-only identity")
func hardwareIdentityDoesNotDowngrade() {
    let stored = identity(
        vendor: 10,
        product: 20,
        serial: nil,
        uuid: nil,
        name: "Monitor",
        width: 1920,
        height: 1080
    )
    let nameOnly = identity(
        vendor: nil,
        product: nil,
        serial: nil,
        uuid: nil,
        name: "Monitor",
        width: 1920,
        height: 1080
    )

    #expect(DisplayIdentityMatcher.uniqueMatch(
        for: stored,
        among: [nameOnly]
    ) == nil)
}

@Test("Name and native dimensions fallback must be unique")
func displayFallbackMustBeUnique() {
    let stored = identity(
        vendor: nil,
        product: nil,
        serial: nil,
        uuid: nil,
        name: "Extern",
        width: 1920,
        height: 1080
    )
    let matching = identity(
        vendor: nil,
        product: nil,
        serial: nil,
        uuid: nil,
        name: "extern",
        width: 1080,
        height: 1920
    )

    #expect(
        DisplayIdentityMatcher.uniqueMatch(
            for: stored,
            among: [matching]
        ) == 0
    )
    #expect(
        DisplayIdentityMatcher.uniqueMatch(
            for: stored,
            among: [matching, matching]
        ) == nil
    )
}

@Test("Target configuration resolves one authoritative monitor")
func targetConfigurationResolution() {
    let selected = identity(serial: 9, uuid: "SELECTED", name: "Prompter")
    let configuration = TeleprompterConfiguration(
        target: selected,
        transform: .teleprompterDefault
    )

    #expect(configuration.resolvedTargetIndex(among: [
        identity(serial: 8, uuid: "OTHER", name: "Kontrolle"),
        selected
    ]) == 1)
    #expect(TeleprompterConfiguration().resolvedTargetIndex(
        among: [selected]
    ) == nil)
}

@Test("Legacy preset display key is decoded as the target")
func legacyDisplayKeyDecodesAsTarget() throws {
    struct LegacyConfiguration: Encodable {
        let display: PersistentDisplayIdentity
        let transform: DisplayTransform
    }

    let saved = identity(serial: 5, uuid: "LEGACY", name: "Prompter")
    let legacy = LegacyConfiguration(
        display: saved,
        transform: DisplayTransform(
            rotation: .degrees90,
            mirrorHorizontally: true,
            mirrorVertically: true
        )
    )
    let data = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(
        TeleprompterConfiguration.self,
        from: data
    )

    #expect(decoded.target == saved)
    #expect(decoded.transform.rotation == .degrees90)
    #expect(decoded.transform.mirrorVertically)
}

@Test("Target configuration survives an encode/decode round trip")
func targetConfigurationRoundTrip() throws {
    let configuration = TeleprompterConfiguration(
        target: identity(serial: 7, uuid: "PROMPTER", name: "Prompter"),
        transform: DisplayTransform(
            rotation: .degrees270,
            mirrorHorizontally: false,
            mirrorVertically: true
        )
    )
    let decoded = try JSONDecoder().decode(
        TeleprompterConfiguration.self,
        from: JSONEncoder().encode(configuration)
    )

    #expect(decoded == configuration)
}

@Test("Settings normalize the source to its selected kind")
func settingsNormalizeSource() {
    let malformed = AppSettings(
        configuration: TeleprompterConfiguration(
            source: CaptureSourceSelection(
                kind: .window,
                display: identity(serial: 3, uuid: "STALE", name: "Alt"),
                window: WindowIdentity(
                    bundleIdentifier: "com.example.deck",
                    applicationName: "Deck",
                    title: "Sprecheransicht"
                )
            ),
            target: identity(serial: 4, uuid: "TARGET", name: "Prompter")
        ),
        autoStartOutput: true
    )
    let normalized = malformed.normalized()

    #expect(normalized.configuration.source.display == nil)
    #expect(normalized.configuration.source.window != nil)
    #expect(normalized.schemaVersion == AppSettings.currentSchemaVersion)
    #expect(normalized.autoStartOutput)
}

@Test("Complete settings survive persistence codec")
func settingsCodecRoundTrip() throws {
    let settings = AppSettings(
        configuration: TeleprompterConfiguration(
            source: CaptureSourceSelection(
                kind: .display,
                display: identity(serial: 12, uuid: "SOURCE", name: "Quelle")
            ),
            target: identity(
                serial: 11,
                uuid: "PROMPTER",
                name: "Prompter"
            ),
            transform: DisplayTransform(
                rotation: .degrees270,
                mirrorHorizontally: true,
                mirrorVertically: true
            )
        ),
        autoStartOutput: true
    )

    let decoded = try AppSettingsCodec.decode(
        AppSettingsCodec.encode(settings)
    )
    #expect(decoded == settings)
}

@Test("Schema version 1 presets migrate to the single configuration")
func legacyPresetsMigrateToSingleConfiguration() throws {
    struct LegacySlot: Encodable {
        let name: String
        let configuration: TeleprompterConfiguration
    }
    struct LegacySettings: Encodable {
        let schemaVersion: Int
        let activePresetIndex: Int
        let presets: [LegacySlot]
        let autoStartOutput: Bool
    }

    let wanted = TeleprompterConfiguration(
        target: identity(serial: 21, uuid: "ACTIVE", name: "Prompter"),
        transform: DisplayTransform(
            rotation: .degrees180,
            mirrorHorizontally: false,
            mirrorVertically: true
        )
    )
    let legacy = LegacySettings(
        schemaVersion: 1,
        activePresetIndex: 1,
        presets: [
            LegacySlot(name: "Preset 1", configuration: .init()),
            LegacySlot(name: "Preset 2", configuration: wanted),
            LegacySlot(name: "Preset 3", configuration: .init())
        ],
        autoStartOutput: true
    )

    let decoded = try AppSettingsCodec.decode(
        JSONEncoder().encode(legacy)
    )

    #expect(decoded.configuration == wanted)
    #expect(decoded.configuration.source.kind == .virtualDisplay)
    #expect(decoded.autoStartOutput)
    #expect(decoded.schemaVersion == AppSettings.currentSchemaVersion)
}

@Test("Window identity resolves only when it is unambiguous")
func windowIdentityResolution() {
    let deck = WindowIdentity(
        bundleIdentifier: "com.example.deck",
        applicationName: "Deck",
        title: "Sprecheransicht"
    )
    let notes = WindowIdentity(
        bundleIdentifier: "com.example.deck",
        applicationName: "Deck",
        title: "Notizen"
    )
    let other = WindowIdentity(
        bundleIdentifier: "com.example.browser",
        applicationName: "Browser",
        title: "Sprecheransicht"
    )

    #expect(
        WindowIdentityMatcher.uniqueMatch(for: deck, among: [other, notes, deck])
            == 2
    )
    #expect(
        WindowIdentityMatcher.uniqueMatch(for: deck, among: [other]) == nil
    )
    #expect(
        WindowIdentityMatcher.uniqueMatch(for: deck, among: [deck, deck]) == nil
    )
}

@Test("Only a complete source selection can start the output")
func sourceSelectionCompleteness() {
    #expect(CaptureSourceSelection.virtualDisplay.isComplete)
    #expect(!CaptureSourceSelection(kind: .display).isComplete)
    #expect(!CaptureSourceSelection(kind: .window).isComplete)
    #expect(
        CaptureSourceSelection(
            kind: .display,
            display: identity(serial: 1, uuid: "A", name: "A")
        ).isComplete
    )
}

private func identity(
    vendor: UInt32? = 10,
    product: UInt32? = 20,
    serial: UInt32?,
    uuid: String?,
    name: String,
    width: Int = 1920,
    height: Int = 1080
) -> PersistentDisplayIdentity {
    PersistentDisplayIdentity(
        vendorID: vendor,
        productID: product,
        serialNumber: serial,
        displayUUID: uuid,
        localizedName: name,
        nativePixelWidth: width,
        nativePixelHeight: height
    )
}
