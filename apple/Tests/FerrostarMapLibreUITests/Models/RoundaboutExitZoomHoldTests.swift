import CoreLocation
import XCTest
@testable import FerrostarMapLibreUI

final class RoundaboutExitZoomHoldTests: XCTestCase {
    private typealias Progress = NavigationManeuverCamera.RouteProgress
    private typealias Hold = NavigationManeuverCamera.RoundaboutExitZoomHold

    private let exit = Progress.Turn(coordinate: .init(latitude: 47, longitude: 13))
    private let nextTurn = Progress.Turn(coordinate: .init(latitude: 47.001, longitude: 13))

    func testHoldStartsAtExitAndPersistsAcrossAnotherStep() throws {
        let approach = progress(steps: 5, distanceToTurn: 15, remainingDistance: 615, nextTurn: exit)
        let afterExit = progress(steps: 4, distanceToTurn: 25, remainingDistance: 585, currentStepStart: exit)
        let afterNextTurn = progress(steps: 3, distanceToTurn: 220, remainingDistance: 520, currentStepStart: nextTurn)
        let hold = try XCTUnwrap(Hold(after: approach, advancingTo: afterExit, wasApproachingExit: true,
                                      distance: 100, zoom: 16))

        XCTAssertEqual(hold.minimumZoom, 16)
        XCTAssertTrue(hold.isActive(at: afterExit.remainingDistance))
        XCTAssertTrue(hold.isActive(at: afterNextTurn.remainingDistance))
        XCTAssertTrue(hold.isActive(at: 501))
        XCTAssertFalse(hold.isActive(at: 500))
        XCTAssertFalse(hold.isActive(at: 499))
    }

    func testHoldRequiresAdvancingOntoRecognizedExitStep() {
        let approach = progress(steps: 5, distanceToTurn: 15, remainingDistance: 615, nextTurn: exit)
        let wrongStep = progress(steps: 4, distanceToTurn: 25, remainingDistance: 585, currentStepStart: nextTurn)
        let afterExit = progress(steps: 4, distanceToTurn: 25, remainingDistance: 585, currentStepStart: exit)

        XCTAssertNil(Hold(after: approach, advancingTo: wrongStep, wasApproachingExit: true, distance: 100, zoom: 16))
        XCTAssertNil(Hold(after: approach, advancingTo: afterExit, wasApproachingExit: false, distance: 100, zoom: 16))
        XCTAssertNil(Hold(after: approach, advancingTo: afterExit, wasApproachingExit: true, distance: 0, zoom: 16))
        XCTAssertNil(Hold(after: approach, advancingTo: approach, wasApproachingExit: true, distance: 100, zoom: 16))
    }

    private func progress(
        steps: Int, distanceToTurn: Double, remainingDistance: Double,
        currentStepStart: Progress.Turn? = nil, nextTurn: Progress.Turn? = nil
    ) -> Progress {
        .init(remainingStepCount: steps, distanceToTurn: distanceToTurn, remainingDistance: remainingDistance,
              currentStepStart: currentStepStart, nextTurn: nextTurn,
              startsRoundaboutExitHoldAtNextTurn: nextTurn == exit,
              outgoingPath: [], compoundManeuvers: nil, approach: nil)
    }
}
