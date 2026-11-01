import Foundation

struct HaasSegmentLedger: Codable, Equatable {
    enum Disposition: String, Codable {
        case pending, posting, posted, uncertain, copied
    }

    struct Segment: Codable, Equatable, Identifiable {
        let id: String
        let text: String
        var disposition: Disposition
    }

    private(set) var segments: [Segment] = []

    var fullText: String { segments.map(\.text).joined() }
    var pendingText: String { text(for: [.pending]) }
    var uncertainText: String { text(for: [.uncertain]) }
    var hasUnresolvedSegments: Bool {
        segments.contains { [.pending, .posting, .uncertain].contains($0.disposition) }
    }
    var nextPendingSegment: Segment? { segments.first { $0.disposition == .pending } }

    var unresolvedArchive: HaasSegmentLedger {
        var archive = HaasSegmentLedger()
        archive.segments = segments.compactMap { segment in
            switch segment.disposition {
            case .pending, .uncertain:
                return segment
            case .posting:
                var interrupted = segment
                interrupted.disposition = .uncertain
                return interrupted
            case .posted, .copied:
                return nil
            }
        }
        return archive
    }

    @discardableResult
    mutating func append(id: String, text: String) -> Bool {
        guard !segments.contains(where: { $0.id == id }), !text.isEmpty else { return false }
        segments.append(Segment(id: id, text: text, disposition: .pending))
        return true
    }

    mutating func setDisposition(_ disposition: Disposition, for id: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].disposition = disposition
    }

    @discardableResult
    mutating func replacePendingText(_ text: String, for id: String) -> Bool {
        guard !text.isEmpty,
            let index = segments.firstIndex(where: { $0.id == id && $0.disposition == .pending })
        else { return false }
        segments[index] = Segment(id: id, text: text, disposition: .pending)
        return true
    }

    mutating func markPendingAsCopied() {
        for index in segments.indices where segments[index].disposition == .pending {
            segments[index].disposition = .copied
        }
    }

    mutating func acknowledgeUncertainSegments() {
        for index in segments.indices where [.posting, .uncertain].contains(segments[index].disposition) {
            segments[index].disposition = .copied
        }
    }

    mutating func recoverInterruptedPaste() {
        for index in segments.indices where segments[index].disposition == .posting {
            segments[index].disposition = .uncertain
        }
    }

    private func text(for dispositions: Set<Disposition>) -> String {
        segments.filter { dispositions.contains($0.disposition) }.map(\.text).joined()
    }
}
