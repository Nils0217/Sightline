// labels: production, needs-review
// The search's decision rules, moved out of the app's FindModel so each device failure in docs/TEST_LOG.md has
// a test that keeps it fixed (Nils, 2026-11-03: "I don't want to keep facing an issue that was captured in the
// log"). FindModel calls these; it keeps only the calls, logging and timing.

import Foundation
import simd

public enum FindRules {
    /// Lowercased words, a plural "s" dropped ("vitamins" -> "vitamin").
    public static func plainWords(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map { w in
            w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") ? String(w.dropLast()) : String(w)
        })
    }

    /// T15: the agent widened "vitamin bottle" to "bottle" and the scan locked another bottle. A broader name than
    /// one already looked for, dropping a word the user said, keeps the narrower one as the target. nil: no change.
    public static func narrowerTarget(for noun: String, notFound: [String], heard: Set<String>) -> String? {
        let have = plainWords(noun)
        return notFound.first { n in
            let w = plainWords(n)
            return w.isStrictSuperset(of: have) && TargetVocabulary.sameWords(n, noun) && !w.subtracting(have).isDisjoint(with: heard)
        }
    }

    /// v9.4 (T14 row 3): six names on a view without the bottles. After 2 names found nothing in view, the next
    /// `find_object` scans for the first name instead. nil: look in this view.
    public static func scanInstead(notFound: [String]) -> String? {
        notFound.count >= 2 ? notFound.first : nil
    }

    /// What SAM is asked for, and why (logged). T14 row 5: hold checks asked for the user's word, not the search name.
    /// Order: Spark's pick ("looks like"), the agent's broader name, the saved room's name, Spark's cached name, the word.
    public static func samQuery(noun: String, seenAs: String?, broader: String?, roomName: String?,
                                sparkName: String?) -> (query: String, why: String) {
        if let q = seenAs { return (q, "spark pick") }
        if let q = broader { return (q, "agent") }
        if let q = roomName, q != noun { return (q, "room map") }
        if let q = sparkName, q != noun.lowercased() { return (q, "spark") }
        return (noun, "")
    }

    /// T17: after Spark said no to one candidate, the others in the same photo are checked before scanning on.
    /// Index of the first candidate not near a rejected one (`skip` metres), nil when all are rejected.
    public static func nextCandidate(_ worlds: [SIMD3<Float>], rejected: [SIMD3<Float>], skip: Float = Geometry.skip) -> Int? {
        worlds.firstIndex { w in !rejected.contains { simd_distance($0, w) < skip } }
    }

    /// T18 row 3: Spark pointed at the bottle but SAM drew no outline there; the full SAM search's outline nearest
    /// the point, within `within` metres, gives the target its shape. nil: none close enough.
    public static func nearest(_ worlds: [SIMD3<Float>], to point: SIMD3<Float>, within: Float = Geometry.skip) -> Int? {
        guard let i = worlds.indices.min(by: { simd_distance(worlds[$0], point) < simd_distance(worlds[$1], point) }),
              simd_distance(worlds[i], point) < within else { return nil }
        return i
    }

    /// T18 row 5: Spark's pick failed (not in view, no answer, no depth): the SAM-first search runs as before,
    /// unless the search was stopped or is out of calls.
    public static func samAfterPick(failure reason: String) -> Bool {
        reason != "cancelled" && reason != "budget"
    }

    /// T16 row 2: the saved spot counts as seen clearly (so "it isn't there" may be said) only when nothing is more
    /// than `inFront` metres in front of it at its pixel; 30 cm let a thermos 5-10 cm in front pass.
    public static func spotInClearView(spotDistance d: Float, seenDistance hit: Float, inFront: Float = Geometry.same) -> Bool {
        hit > d - inFront
    }

    /// T19: tapping to finish the room scan while views were still being listed saved an empty room. The tap waits
    /// for them; the save happens when the last one is in.
    public struct RoomScanFinish: Sendable, Equatable {
        public enum Action: Sendable, Equatable { case saveNow, wait, ignore }
        public private(set) var inFlight = 0
        public private(set) var tapped = false

        public init() {}

        public mutating func viewSent() { inFlight += 1 }

        /// A view's answer came (or failed). True: save now (tapped earlier and this was the last one).
        public mutating func viewDone() -> Bool {
            inFlight = max(0, inFlight - 1)
            return tapped && inFlight == 0
        }

        public mutating func tap() -> Action {
            if inFlight == 0 { return .saveNow }
            if tapped { return .ignore }
            tapped = true
            return .wait
        }
    }
}
