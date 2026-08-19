import Foundation
import Testing
@testable import TeleprompterCore

@Test("Initial capture sample is accepted without a complete status")
func initialCaptureSampleIsAccepted() {
    #expect(
        CaptureFramePolicy.shouldDeliver(
            statusRawValue: nil,
            hasDeliveredInitialFrame: false
        )
    )
}

@Test("Idle capture samples are dropped after initialization")
func idleCaptureSamplesAreDroppedAfterInitialization() {
    #expect(
        !CaptureFramePolicy.shouldDeliver(
            statusRawValue: 1,
            hasDeliveredInitialFrame: true
        )
    )
    #expect(
        CaptureFramePolicy.shouldDeliver(
            statusRawValue: 0,
            hasDeliveredInitialFrame: true
        )
    )
}

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

@Test("Same-display configuration resolves one authoritative monitor")
func sameDisplayConfigurationResolution() {
    let selected = identity(serial: 9, uuid: "SELECTED", name: "Prompter")
    let configuration = SameDisplayConfiguration(
        display: selected,
        transform: .teleprompterDefault
    )

    #expect(configuration.resolvedDisplayIndex(among: [
        identity(serial: 8, uuid: "OTHER", name: "Kontrolle"),
        selected
    ]) == 1)
    #expect(SameDisplayConfiguration().resolvedDisplayIndex(
        among: [selected]
    ) == nil)
}

@Test("Settings normalize to exactly three named slots")
func settingsNormalizePresetSlots() {
    let malformed = AppSettings(
        activePresetIndex: 99,
        presets: [PresetSlot(name: "   ")],
        autoStartOutput: true
    )
    let normalized = malformed.normalized()

    #expect(normalized.presets.count == 3)
    #expect(normalized.presets.map(\.name) == [
        "Preset 1", "Preset 2", "Preset 3"
    ])
    #expect(normalized.activePresetIndex == 2)
    #expect(normalized.autoStartOutput)
}

@Test("Complete settings survive persistence codec")
func settingsCodecRoundTrip() throws {
    var settings = AppSettings.defaults
    settings.activePresetIndex = 1
    settings.autoStartOutput = true
    settings.presets[1] = PresetSlot(
        name: "Teleprompter Bühne",
        configuration: SameDisplayConfiguration(
            display: identity(
                serial: 11,
                uuid: "PROMPTER",
                name: "Prompter"
            ),
            transform: DisplayTransform(
                rotation: .degrees270,
                mirrorHorizontally: true,
                mirrorVertically: true
            )
        )
    )

    let decoded = try AppSettingsCodec.decode(
        AppSettingsCodec.encode(settings)
    )
    #expect(decoded == settings)
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
