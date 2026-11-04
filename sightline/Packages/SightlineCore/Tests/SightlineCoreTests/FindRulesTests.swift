// labels: testing, needs-review
// One test per device failure in docs/TEST_LOG.md whose rule lives in the search (FindRules), named after the run.
import Foundation
import simd
import Testing
@testable import SightlineCore

struct FindRulesTests {
    /// T15 row 1: "I need my vitamin" -> "vitamin bottle" (nothing) -> "bottle": the target stays "vitamin bottle".
    @Test func t15WideningKeepsTheUsersWord() {
        let heard = FindRules.plainWords("I need my vitamin")
        #expect(FindRules.narrowerTarget(for: "bottle", notFound: ["vitamin bottle"], heard: heard) == "vitamin bottle")
    }

    /// T15 row 1, the other side: "I'm thirsty" -> "water bottle" -> "bottle" may widen (the user never said water).
    @Test func t15WideningAllowedWhenTheUserNeverSaidIt() {
        let heard = FindRules.plainWords("I'm thirsty")
        #expect(FindRules.narrowerTarget(for: "bottle", notFound: ["water bottle"], heard: heard) == nil)
    }

    /// T14 row 3: after two names found nothing in view, scan for the first.
    @Test func t14TwoMissesScanForTheFirstName() {
        #expect(FindRules.scanInstead(notFound: ["vitamin bottle"]) == nil)
        #expect(FindRules.scanInstead(notFound: ["vitamin bottle", "pill bottle"]) == "vitamin bottle")
    }

    /// T14 row 5 and T18: the hold check asks SAM for the search's name, Spark's pick first.
    @Test func t14HoldChecksAskForTheSearchName() {
        #expect(FindRules.samQuery(noun: "vitamin", seenAs: "pill bottle", broader: nil, roomName: "vitamin bottle",
                                   sparkName: nil) == ("pill bottle", "spark pick"))
        #expect(FindRules.samQuery(noun: "vitamin", seenAs: nil, broader: nil, roomName: "vitamin bottle",
                                   sparkName: "pill bottle") == ("vitamin bottle", "room map"))
        #expect(FindRules.samQuery(noun: "vitamin", seenAs: nil, broader: nil, roomName: nil,
                                   sparkName: "pill bottle") == ("pill bottle", "spark"))
        #expect(FindRules.samQuery(noun: "cup", seenAs: nil, broader: nil, roomName: nil, sparkName: nil) == ("cup", ""))
    }

    /// T17 row 1: the grey phone was rejected; the black phone in the same photo is checked next, not the scan.
    @Test func t17TheOtherCandidateIsCheckedBeforeScanning() {
        let grey = SIMD3<Float>(0, 0, -0.5), black = SIMD3<Float>(0.15, 0, -0.55)
        #expect(FindRules.nextCandidate([grey, black], rejected: [grey]) == 1)
        #expect(FindRules.nextCandidate([grey, black], rejected: [grey, black]) == nil)
    }

    /// T18 row 3: no outline at Spark's point; the full search's outline 5 cm away is taken, one 20 cm away is not.
    @Test func t18TheNearestOutlineGivesTheShape() {
        let point = SIMD3<Float>(0, 0, -0.4)
        #expect(FindRules.nearest([point + [0.2, 0, 0], point + [0.05, 0, 0]], to: point) == 1)
        #expect(FindRules.nearest([point + [0.2, 0, 0]], to: point) == nil)
    }

    /// T18 row 5: "not in view", no answer or no depth from Spark runs the SAM search; a stop or no budget does not.
    @Test func t18EveryFailedPickFallsBackToSAM() {
        for reason in ["no_object", "api_error", "no_depth", "no_frame"] { #expect(FindRules.samAfterPick(failure: reason)) }
        for reason in ["cancelled", "budget"] { #expect(!FindRules.samAfterPick(failure: reason)) }
    }

    /// T16 row 2: a thermos 7 cm in front of the pill bottles hides them; the spot is not "empty".
    @Test func t16AThingJustInFrontHidesTheSpot() {
        #expect(!FindRules.spotInClearView(spotDistance: 0.6, seenDistance: 0.53))
        #expect(FindRules.spotInClearView(spotDistance: 0.6, seenDistance: 0.6))
        #expect(FindRules.spotInClearView(spotDistance: 0.6, seenDistance: 0.9))  // the table behind: it is gone
    }

    /// T21: two saved water bottles; the answer picks one by place, by "nearer"/"far", or by order; unclear is nil.
    @Test func t21TheAnswerPicksOneSavedThing() {
        let labels = ["a water bottle on the nightstand, next to the vitamin bottle", "a water bottle on the floor, next to the clothes"]
        let d: [Float] = [0.3, 1.9]
        #expect(FindRules.pickSaved(heard: "the one on the nightstand", labels: labels) == 0)
        #expect(FindRules.pickSaved(heard: "near the vitamins", labels: labels, distances: d) == 0)
        #expect(FindRules.pickSaved(heard: "floor", labels: labels) == 1)
        #expect(FindRules.pickSaved(heard: "the far one", labels: labels, distances: d) == 1)
        #expect(FindRules.pickSaved(heard: "the second", labels: labels) == 1)
        #expect(FindRules.pickSaved(heard: "the water bottle", labels: labels) == nil)  // both are: ask
        #expect(FindRules.pickSaved(heard: "I need some water", labels: labels) == nil)
        let looks = ["a black metal water bottle with an amd logo, on the nightstand", "a clear plastic water bottle, on the floor"]
        #expect(FindRules.pickSaved(heard: "the black one", labels: looks) == 0)
        #expect(FindRules.pickSaved(heard: "plastic", labels: looks) == 1)
    }

    /// T22: the two brown bottles with yellow caps differ only in their names: no question. AMD vs green lid: ask.
    @Test func t22OnlyAskWhenTheyCanBeToldApart() {
        #expect(!FindRules.canTellApart(["a brown plastic supplement bottle with yellow cap, on the desk",
                                         "a brown plastic vitamin bottle with yellow cap, on the desk"],
                                        names: ["supplement bottle", "vitamin bottle"]))
        #expect(FindRules.canTellApart(["a white plastic water bottle with light green lid, on the side table",
                                        "a black metal water bottle with amd logo, on the desk"],
                                       names: ["water bottle", "water bottle"]))
    }

    /// T22: "Your my phone was last seen …".
    @Test func t22TheAgentsNounLosesMy() {
        #expect(FindRules.cleanNoun("my phone") == "phone")
        #expect(FindRules.cleanNoun("the black water bottle") == "black water bottle")
        #expect(FindRules.cleanNoun("my") == "my")
    }

    /// T19 row 1: a tap 2 s after the second view went out waits for it, then saves once.
    @Test func t19TheTapWaitsForViewsStillBeingListed() {
        var f = FindRules.RoomScanFinish()
        f.viewSent()
        f.viewSent()
        let first = f.viewDone()  // view 1 failed before the tap
        let tap1 = f.tap(), tap2 = f.tap()
        let second = f.viewDone()  // view 2's answer: save now
        #expect(!first && tap1 == .wait && tap2 == .ignore && second)
        var idle = FindRules.RoomScanFinish()
        let now = idle.tap()
        #expect(now == .saveNow)
    }
}
