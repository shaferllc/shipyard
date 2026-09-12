import Foundation

/// One app folder, as its files, git and GitHub describe it. Nothing is
/// stored: every refresh reads it again from those sources.
struct Project: Identifiable, Sendable {
    let url: URL
    var version: String?
    var hasUpdates = false      // links Sparkle, so it can update itself
    var isProduct = false       // listed in shafer.llc's config/products.php
    var isGit = false
    var repo: String?           // owner/name on GitHub
    var branch: String?
    var changes = 0             // uncommitted files
    var unpushed: Int?          // commits ahead of upstream; nil without one
    var releaseChecked = false  // GitHub answered, so `released` is real
    var released: String?       // the latest release's version, without the v
    var releaseRun: String?     // the latest Release run: success, failure, in_progress…

    var id: String { url.path }
    var slug: String { url.lastPathComponent }
    var name: String { slug.prefix(1).uppercased() + slug.dropFirst() }

    var isReleaseRunning: Bool { ["in_progress", "queued", "waiting", "pending"].contains(releaseRun ?? "") }
    var iconURL: URL { url.appending(path: "AppIcon.icns") }

    /// The copy make-app.sh installs, when it's there.
    var installedApp: URL? {
        let app = URL(fileURLWithPath: "/Applications/\(name).app")
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
    }

    /// A name new-mac-app accepts: one capitalized word, like Swab or Wheelhouse.
    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Z][A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }

    /// VERSION is ahead of the latest release: a release is due, pushed or not.
    var isReleasePending: Bool { releaseChecked && version != nil && version != released }

    /// Why a version bump can't go out now, or nil when it can.
    var bumpBlocker: String? {
        guard isGit else { return "Not a git repository." }
        guard repo != nil else { return "No GitHub remote." }
        guard branch == "main" else { return "On \(branch ?? "no branch"), not main." }
        guard changes == 0 else { return "Uncommitted changes — commit them first." }
        guard let version else { return "No VERSION file." }
        guard Version(version) != nil else { return "VERSION “\(version)” isn't x.y.z — fix it by hand." }
        guard releaseChecked else { return "Couldn't check GitHub for releases." }
        guard released == version else {
            return "v\(version) hasn't shipped yet — check its Release run."
        }
        return nil
    }

    /// What needs a person, for the Needs Attention column.
    var issues: [String] {
        guard isGit else { return ["Not in git"] }
        var out: [String] = []
        if repo == nil { out.append("No GitHub remote") }
        if changes > 0 { out.append("\(changes) uncommitted") }
        if let unpushed, unpushed > 0 { out.append("\(unpushed) unpushed") }
        if isReleasePending, let version { out.append("v\(version) not released") }
        if releaseRun == "failure" { out.append("Release run failed") }
        return out
    }

    /// "owner/name" from an https or ssh GitHub remote; nil for anything else.
    static func githubRepo(fromRemote remote: String) -> String? {
        guard let host = remote.range(of: "github.com") else { return nil }
        var path = remote[host.upperBound...].dropFirst()  // the ":" or "/" after the host
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/")
        return parts.count == 2 ? parts.joined(separator: "/") : nil
    }
}

/// What the detail pane loads for the selected app, on demand.
struct ProjectDetails: Sendable {
    struct Change: Identifiable, Sendable {
        let status: String
        let path: String
        var id: String { path }
    }

    struct Commit: Identifiable, Sendable {
        let hash: String
        let subject: String
        let when: String
        var id: String { hash }
    }

    struct Release: Identifiable, Sendable {
        let tag: String
        let date: String
        var id: String { tag }
    }

    var changes: [Change] = []
    var commits: [Commit] = []
    var releases: [Release] = []
}
