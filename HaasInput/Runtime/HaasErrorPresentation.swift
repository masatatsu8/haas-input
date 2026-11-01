import Foundation

enum HaasErrorPresentation {
    static func message(
        for error: Error,
        fallback: String = "処理を完了できませんでした。もう一度お試しください。"
    ) -> String {
        switch error {
        case let error as HaasRuntimeError:
            return error.errorDescription ?? fallback
        case let error as HaasModelDownloadError:
            return error.errorDescription ?? fallback
        case is CancellationError:
            return "操作を取り消しました。"
        default:
            return fallback
        }
    }
}
