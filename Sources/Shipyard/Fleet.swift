import AppKit
import Foundation

/// Every app in the apps folder, read from disk, git and GitHub.
@MainActor
final class Fleet: ObservableObject {
    static let appsFolderKey = "appsFolder"
    static let siteFolderKey = "siteFolder"
    static let defaultAppsFolder = "~/Projects/Apps/desktop"
    static let defaultSiteFolder = "~/Projects/shaferllc"

    @Published private(set) var projects: [Project] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasGitHubCLI = true
    @Published var problem: String?

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let apps = Self.folder(Self.appsFolderKey, Self.defaultAppsFolder)
        let products = Self.folder(Self.siteFolderKey, Self.defaultSiteFolder)
            .appending(path: "config/products.php")

        // Disk and git first: quick, and enough to fill the table.
        let local = await Task.detached { Scanner.scan(apps, products: products) }.value
        projects = local
        hasGitHubCLI = Shell.hasGitHubCLI
        guard hasGitHubCLI else { return }
        projects = await Scanner.checkAllOnGitHub(local)
    }

    /// Bumps VERSION, commits it and pushes main. The push is what cuts the
    /// signed, notarized release (shaferllc/.github mac-release).
    func release(_ project: Project, _ part: Version.Part) async {
        do {
            try await Task.detached {
                // Check again against the folder as it is now, not as the table last saw it.
                let now = Scanner.checkGitHub(Scanner.local(project.url, productsText: ""))
                if let blocker = now.bumpBlocker { throw ShellError(message: blocker) }
                guard let current = now.version.flatMap({ Version($0) }) else { return }
                let next = current.bumped(part)
                try "\(next)\n".write(to: project.url.appending(path: "VERSION"), atomically: true, encoding: .utf8)
                try Shell.run(["git", "commit", "--quiet", "-m", "Release v\(next)", "--", "VERSION"], in: project.url)
                try Shell.run(["git", "push", "--quiet"], in: project.url)
            }.value
        } catch {
            problem = "\(project.name): \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Commits everything `git status` lists (the commit sheet shows it first),
    /// then pushes when asked. A push that changes VERSION cuts a release.
    func commit(_ project: Project, message: String, push: Bool) async {
        do {
            try await Task.detached {
                try Shell.run(["git", "add", "--all"], in: project.url)
                try Shell.run(["git", "commit", "--quiet", "-m", message], in: project.url)
                if push { try Shell.run(["git", "push", "--quiet"], in: project.url) }
            }.value
        } catch {
            problem = "\(project.name): \(error.localizedDescription)"
        }
        await refresh()
    }

    func push(_ project: Project) async {
        do {
            _ = try await Task.detached { try Shell.run(["git", "push", "--quiet"], in: project.url) }.value
        } catch {
            problem = "\(project.name): \(error.localizedDescription)"
        }
        await refresh()
    }

    static func folder(_ key: String, _ fallback: String) -> URL {
        let path = UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
}

enum Scanner {
    /// Every folder with a make-app.sh, the mark of a Shafer Mac app.
    static func scan(_ folder: URL, products: URL) -> [Project] {
        let fm = FileManager.default
        let productsText = (try? String(contentsOf: products, encoding: .utf8)) ?? ""
        let folders = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { fm.fileExists(atPath: $0.appending(path: "make-app.sh").path) }
            .map { local($0, productsText: productsText) }
            .sorted { $0.slug < $1.slug }
    }

    static func local(_ url: URL, productsText: String) -> Project {
        func read(_ file: String) -> String? {
            (try? String(contentsOf: url.appending(path: file), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func git(_ args: String...) -> String? { try? Shell.run(["git"] + args, in: url) }

        var p = Project(url: url)
        p.version = read("VERSION")
        p.hasUpdates = read("Package.swift")?.contains("sparkle-project") ?? false
        p.isProduct = productsText.contains("'\(p.slug)' => [")
        p.isGit = FileManager.default.fileExists(atPath: url.appending(path: ".git").path)
        guard p.isGit else { return p }
        p.repo = git("remote", "get-url", "origin").flatMap { Project.githubRepo(fromRemote: $0) }
        p.branch = git("rev-parse", "--abbrev-ref", "HEAD")
        p.changes = git("status", "--porcelain")?.split(separator: "\n").count ?? 0
        // Local refs only: no fetch, so this is "waiting to push", not "behind".
        p.unpushed = git("rev-list", "--count", "@{u}..HEAD").flatMap { Int($0) }
        return p
    }

    // ponytail: each check blocks a cooperative thread on gh, so they run
    // core-count at a time. Fine for dozens of apps; use async Process for hundreds.
    static func checkAllOnGitHub(_ projects: [Project]) async -> [Project] {
        await withTaskGroup(of: Project.self) { group in
            for p in projects { group.addTask { checkGitHub(p) } }
            var out: [Project] = []
            for await p in group { out.append(p) }
            return out.sorted { $0.slug < $1.slug }
        }
    }

    /// The latest release and Release workflow run, from gh.
    static func checkGitHub(_ project: Project) -> Project {
        var p = project
        guard let repo = p.repo else { return p }
        do {
            let tag = try Shell.run(["gh", "release", "view", "-R", repo, "--json", "tagName", "--jq", ".tagName"])
            p.released = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            p.releaseChecked = true
        } catch let error as ShellError where error.message.contains("release not found") {
            p.releaseChecked = true
        } catch {}
        p.releaseRun = (try? Shell.run([
            "gh", "run", "list", "-R", repo, "--workflow", "release.yml", "--limit", "1",
            "--json", "status,conclusion",
            "--jq", #".[] | if .status == "completed" then .conclusion else .status end"#,
        ])).flatMap { $0.isEmpty ? nil : $0 }
        return p
    }
}

struct ShellError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Shell {
    /// An app opened from Finder gets a bare PATH; Homebrew's gh lives outside it.
    static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    static var hasGitHubCLI: Bool {
        path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/gh") }
    }

    /// Runs a command to the end: its trimmed output, or a ShellError with what it printed to stderr.
    @discardableResult
    static func run(_ command: [String], in folder: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["GIT_TERMINAL_PROMPT"] = "0"  // fail rather than wait on a prompt nobody sees
        env["GH_PROMPT_DISABLED"] = "1"
        process.environment = env
        process.currentDirectoryURL = folder
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // ponytail: stdout is drained before stderr, so a command that fills the
        // stderr pipe (64 KB) first would hang. git and gh here print a few lines.
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShellError(message: message.isEmpty ? "\(command.joined(separator: " ")) failed." : message)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Hands a project to other apps. NSWorkspace rather than Apple Events, which
/// need an entitlement under the hardened runtime and fail silently without one.
@MainActor
enum Open {
    static func inFinder(_ p: Project) { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
    static func inXcode(_ p: Project) { with("com.apple.dt.Xcode", p.url.appending(path: "Package.swift")) }
    static func inTerminal(_ p: Project) { with("com.apple.Terminal", p.url) }

    /// Warp's agent, working in the app's folder.
    static func inAITerminal(_ p: Project) { inWarp(p, file: "shipyard", pane: #"type = "agent""#) }
    /// A Warp tab in the app's folder running Claude Code.
    static func inClaudeCode(_ p: Project) {
        inWarp(p, file: "shipyard-claude", pane: #"type = "terminal""# + "\n" + #"commands = ["claude"]"#)
    }

    /// Rewrites a Warp tab config for this app and opens it by URL — Warp's own
    /// way in, no Apple Events. Without Warp, a plain Terminal window.
    private static func inWarp(_ p: Project, file: String, pane: String) {
        guard let warp = URL(string: "warp://tab_config/\(file)"),
              NSWorkspace.shared.urlForApplication(toOpen: warp) != nil
        else { return inTerminal(p) }
        let folder = p.url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let toml = """
        # Written by Shipyard each time it opens an app; changes here are overwritten.
        name = "Shipyard: \(p.name)"

        [[panes]]
        id = "main"
        \(pane)
        directory = "\(folder)"
        is_focused = true

        """
        let configs = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".warp/tab_configs")
        do {
            try FileManager.default.createDirectory(at: configs, withIntermediateDirectories: true)
            try toml.write(to: configs.appending(path: "\(file).toml"), atomically: true, encoding: .utf8)
        } catch {
            return inTerminal(p)
        }
        NSWorkspace.shared.open(warp)
    }

    /// `page` follows the repo URL: "/releases", "/actions".
    static func onGitHub(_ p: Project, _ page: String = "") {
        guard let repo = p.repo, let url = URL(string: "https://github.com/\(repo)\(page)") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func with(_ bundleID: String, _ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
