import XCTest

@testable import Shipyard

final class ShipyardTests: XCTestCase {
    func testVersionParsesOnlyXYZ() {
        XCTAssertEqual(Version("1.2.3"), Version(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(Version(" 0.10.0\n")?.description, "0.10.0")
        for bad in ["1.0", "v1.2.3", "1.2.3-beta", "1..3", "1.2.3.4", "+1.2.3", "", "１.2.3"] {
            XCTAssertNil(Version(bad), bad)
        }
    }

    func testBumpResetsLowerParts() {
        let v = Version(major: 1, minor: 4, patch: 2)
        XCTAssertEqual(v.bumped(.patch).description, "1.4.3")
        XCTAssertEqual(v.bumped(.minor).description, "1.5.0")
        XCTAssertEqual(v.bumped(.major).description, "2.0.0")
    }

    func testGitHubRepoFromRemote() {
        XCTAssertEqual(Project.githubRepo(fromRemote: "https://github.com/shaferllc/swab.git"), "shaferllc/swab")
        XCTAssertEqual(Project.githubRepo(fromRemote: "git@github.com:shaferllc/swab.git"), "shaferllc/swab")
        XCTAssertEqual(Project.githubRepo(fromRemote: "https://github.com/shaferllc/swab"), "shaferllc/swab")
        XCTAssertNil(Project.githubRepo(fromRemote: "https://gitlab.com/shaferllc/swab.git"))
    }

    func testBumpOnlyFromACleanReleasedMain() {
        var p = Project(url: URL(fileURLWithPath: "/tmp/swab"))
        p.isGit = true
        p.repo = "shaferllc/swab"
        p.branch = "main"
        p.version = "0.2.0"
        p.releaseChecked = true
        p.released = "0.2.0"
        XCTAssertNil(p.bumpBlocker)
        XCTAssertTrue(p.issues.isEmpty)

        var dirty = p
        dirty.changes = 2
        XCTAssertNotNil(dirty.bumpBlocker)

        var pending = p
        pending.version = "0.2.1"
        XCTAssertNotNil(pending.bumpBlocker)
        XCTAssertTrue(pending.isReleasePending)

        var neverShipped = p
        neverShipped.released = nil
        XCTAssertNotNil(neverShipped.bumpBlocker)

        var twoPart = p
        twoPart.version = "1.0"
        twoPart.released = "1.0"
        XCTAssertNotNil(twoPart.bumpBlocker)

        var branch = p
        branch.branch = "feature"
        XCTAssertNotNil(branch.bumpBlocker)

        var unknown = p
        unknown.releaseChecked = false
        XCTAssertNotNil(unknown.bumpBlocker)
        XCTAssertFalse(unknown.isReleasePending)
    }
}
