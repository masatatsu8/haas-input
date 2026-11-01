import Foundation

extension HaasSettingsStore {
    var runtimeSelection: HaasRuntimeSelection {
        HaasRuntimeSelection(executablePath: executablePath, modelPath: modelPath, vadModelPath: vadModelPath)
    }

    func runtimeConfiguration() throws -> HaasRuntimeConfiguration {
        try HaasModelAssets.shared.resolvedConfiguration(for: runtimeSelection)
    }
}
