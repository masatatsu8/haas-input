import Foundation

enum AppStorageIdentity {
    private static let productionIdentifier = "com.tatsumi.VoiceInkHaas"
    private static let testHostIdentifier = "com.tatsumi.VoiceInkHaas.TestsHost"

    static let applicationSupportDirectoryName = Bundle.main.bundleIdentifier == testHostIdentifier
        ? testHostIdentifier : productionIdentifier
    static let customSoundsDirectoryName = "\(applicationSupportDirectoryName)/CustomSounds"
}
