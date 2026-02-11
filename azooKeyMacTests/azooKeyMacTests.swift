//
//  azooKeyMacTests.swift
//  azooKeyMacTests
//
//  Created by β α on 2021/09/07.
//

import XCTest
import Core
@testable import azooKeyMac

class azooKeyMacTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        XCTAssertEqual(
            azooKeyMacInputController.predictionSelectionIndex(
                current: nil,
                direction: .down,
                candidateCount: 3
            ),
            0
        )
        XCTAssertEqual(
            azooKeyMacInputController.predictionSelectionIndex(
                current: nil,
                direction: .up,
                candidateCount: 3
            ),
            2
        )
    }

    func testPredictionSelectionIndexWrapsAround() throws {
        XCTAssertEqual(
            azooKeyMacInputController.predictionSelectionIndex(
                current: 2,
                direction: .down,
                candidateCount: 3
            ),
            0
        )
        XCTAssertEqual(
            azooKeyMacInputController.predictionSelectionIndex(
                current: 0,
                direction: .up,
                candidateCount: 3
            ),
            2
        )
    }

    func testPredictionSelectionIndexWithNoCandidatesReturnsNil() throws {
        XCTAssertNil(
            azooKeyMacInputController.predictionSelectionIndex(
                current: 1,
                direction: .down,
                candidateCount: 0
            )
        )
    }

}
