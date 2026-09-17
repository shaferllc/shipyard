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

    @MainActor
    func testJobStreamsBothOutputsAndFinishesLast() async throws {
        let job = Job(projectID: "test", title: "Test")
        let exited = expectation(description: "exited")
        var code: Int32?
        try job.start(["sh", "-c", "echo out; echo err >&2; exit 3"],
                      in: URL(fileURLWithPath: NSTemporaryDirectory()), environment: [:]) { status in
            code = status
            exited.fulfill()
        }
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(code, 3)
        XCTAssertFalse(job.isRunning)
        XCTAssertTrue(job.output.contains("out\n") && job.output.contains("err\n"), job.output)
        // The end of the stream is waited for, so nothing lands after the result.
        XCTAssertTrue(job.output.hasSuffix("✗ Exited with status 3\n"), job.output)
    }

    func testQuotingForWarpAndTheShell() {
        XCTAssertEqual(Quote.shell("it's"), #"'it'\''s'"#)
        XCTAssertEqual(Quote.toml(#"say "hi" \ now"# + "\n"), #""say \"hi\" \\ now\n""#)
    }

    func testAppNamesNewMacAppAccepts() {
        for good in ["Swab", "Wheelhouse", "Spyglass2"] { XCTAssertTrue(Project.isValidName(good), good) }
        for bad in ["swab", "S", "Two Words", "Swab!", "Swab-Two", ""] { XCTAssertFalse(Project.isValidName(bad), bad) }
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

    private func checkout(_ path: String, version: String?, root: String) -> Project {
        var p = Project(url: URL(fileURLWithPath: path))
        p.version = version
        p.isGit = true
        p.repoRoot = root
        return p
    }

    func testWorktreesFoldIntoOneRowNewestFirst() {
        // ledge-1.1 is a worktree of ledge: one app, two folders.
        let main = checkout("/apps/ledge", version: "1.2", root: "/apps/ledge")
        let old = checkout("/apps/ledge-1.1", version: "1.1", root: "/apps/ledge")
        let other = checkout("/apps/quay", version: "0.4", root: "/apps/quay")

        let combined = Scanner.combineCheckouts([old, main, other]).sorted { $0.slug < $1.slug }
        XCTAssertEqual(combined.map(\.slug), ["ledge", "quay"])
        // The newest VERSION is the row, whichever order they turned up in.
        XCTAssertEqual(combined[0].version, "1.2")
        XCTAssertEqual(combined[0].checkouts.map(\.slug), ["ledge-1.1"])
        XCTAssertTrue(combined[1].checkouts.isEmpty)
    }

    func testVersionsCompareLoosely() {
        // Not every VERSION is x.y.z, so this can't lean on Version.
        XCTAssertTrue(Project.newer("1.2", "1.1"))
        XCTAssertTrue(Project.newer("1.10", "1.9"))     // not a string compare
        XCTAssertFalse(Project.newer("1.2", "1.2.0"))   // same version, spelled differently
        XCTAssertTrue(Project.newer("1.2.1", "1.2"))
        XCTAssertTrue(Project.newer("1.0", nil))        // something beats nothing
        XCTAssertFalse(Project.newer(nil, "1.0"))
    }

    func testACheckoutKnowsItIsOne() {
        XCTAssertTrue(checkout("/apps/ledge-1.1", version: "1.1", root: "/apps/ledge").isCheckout)
        XCTAssertFalse(checkout("/apps/ledge", version: "1.2", root: "/apps/ledge").isCheckout)
        XCTAssertFalse(Project(url: URL(fileURLWithPath: "/apps/loose")).isCheckout)
    }
}
