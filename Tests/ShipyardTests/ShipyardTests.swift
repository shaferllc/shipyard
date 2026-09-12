import XCTest

@testable import Shipyard

final class ShipyardTests: XCTestCase {
    @MainActor
    func testContentViewBuilds() {
        _ = ContentView().body
    }
}
