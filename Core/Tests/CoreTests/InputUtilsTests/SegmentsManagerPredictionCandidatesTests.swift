@testable import Core
import KanaKanjiConverterModule
import Testing

private func makePredictionSourceCandidate(text: String, ruby: String) -> Candidate {
    Candidate(
        text: text,
        value: 0,
        composingCount: .surfaceCount(ruby.count),
        lastMid: 0,
        data: [
            .init(
                word: text,
                ruby: ruby,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )
        ]
    )
}

@Test func predictionCandidatesReturnsUpToThreeMatchesInOrder() async throws {
    let predictions = SegmentsManager.predictionCandidates(
        target: "かな",
        from: [
            makePredictionSourceCandidate(text: "無関係", ruby: "ことば"),
            makePredictionSourceCandidate(text: "完全一致", ruby: "かな"),
            makePredictionSourceCandidate(text: "候補1", ruby: "かなく"),
            makePredictionSourceCandidate(text: "候補2", ruby: "かなる"),
            makePredictionSourceCandidate(text: "候補3", ruby: "かなり"),
            makePredictionSourceCandidate(text: "候補4", ruby: "かなよ")
        ]
    )

    #expect(predictions.count == 3)
    #expect(predictions.map(\.displayText) == ["候補1", "候補2", "候補3"])
    #expect(predictions.map(\.appendText) == ["く", "る", "り"])
}

@Test func predictionCandidatesSupportsTrailingASCIILetterFallback() async throws {
    let predictions = SegmentsManager.predictionCandidates(
        target: "かなa",
        from: [
            makePredictionSourceCandidate(text: "候補A", ruby: "かなみ")
        ]
    )

    #expect(predictions.count == 1)
    #expect(predictions.first?.displayText == "候補A")
    #expect(predictions.first?.appendText == "み")
}

@Test func predictionCandidatesReturnsEmptyWhenPrefixIsTooShortAfterFallback() async throws {
    let predictions = SegmentsManager.predictionCandidates(
        target: "かa",
        from: [
            makePredictionSourceCandidate(text: "候補A", ruby: "かな")
        ]
    )

    #expect(predictions.isEmpty)
}
