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
    /// Bumped by every refresh, so detail panes reload what they show.
    @Published private(set) var generation = 0
    /// The build, test or scaffold running now, or the last one. One at a
    /// time: a universal build already takes the whole machine.
    @Published private(set) var job: Job?
    /// An app to select once it appears, like one just scaffolded.
    @Published var focus: Project.ID?
    @Published var isCreatingApp = false
    @Published var problem: String?

    private var followUp: Task<Void, Never>?

    static var appsFolder: URL { folder(appsFolderKey, defaultAppsFolder) }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            generation += 1
        }
        Icons.clear()
        let apps = Self.appsFolder
        let products = Self.folder(Self.siteFolderKey, Self.defaultSiteFolder)
            .appending(path: "config/products.php")

        // Disk and git first: quick, and enough to fill the table.
        let local = await Task.detached { Scanner.scan(apps, products: products) }.value
        projects = local
        hasGitHubCLI = Shell.hasGitHubCLI
        guard hasGitHubCLI else { return }
        projects = await Scanner.checkAllOnGitHub(local)

        // Keep a running release's row current until it finishes.
        if followUp == nil, projects.contains(where: \.isReleaseRunning) {
            followUp = Task {
                try? await Task.sleep(for: .seconds(30))
                followUp = nil
                await refresh()
            }
        }
    }

    // MARK: Git and releases

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

    /// Re-runs the failed jobs of the latest Release run, once whatever failed
    /// it (usually the signing secrets) is fixed. No new commit needed.
    func rerunRelease(_ project: Project) async {
        guard let repo = project.repo else { return }
        do {
            try await Task.detached {
                let id = try Shell.run(["gh", "run", "list", "-R", repo, "--workflow", "release.yml",
                                        "--limit", "1", "--json", "databaseId", "--jq", ".[0].databaseId"])
                try Shell.run(["gh", "run", "rerun", id, "--failed", "-R", repo])
            }.value
        } catch {
            problem = "\(project.name): \(error.localizedDescription)"
        }
        await refresh()
    }

    // MARK: Builds

    /// make-app.sh: build for this Mac, install to /Applications, launch.
    func build(_ p: Project) { start("Build & Run \(p.name)", ["./make-app.sh"], id: p.id, in: p.url) }

    func test(_ p: Project) { start("Test \(p.name)", ["swift", "test"], id: p.id, in: p.url) }

    /// The universal dist/ build, shown in Finder when it's done.
    func package(_ p: Project) {
        start("Package \(p.name)", ["./make-app.sh", "--dist"], id: p.id, in: p.url) { ok in
            if ok { NSWorkspace.shared.activateFileViewerSelecting([p.url.appending(path: "dist")]) }
        }
    }

    /// Scaffolds an app with new-mac-app (local only: no repo, no site entry),
    /// selects it, and with a brief hands it to Claude Code to build.
    func createApp(name: String, about: String, brief: String) {
        let folder = Self.appsFolder
        let id = folder.appending(path: name.lowercased()).path
        start("New App: \(name)", ["new-mac-app", name, about, "--local"], id: id, in: folder,
              environment: ["APPS_DIR": folder.path]) { [weak self] ok in
            guard ok, let self else { return }
            Task {
                await self.refresh()
                self.focus = id
                guard !brief.isEmpty, let p = self.projects.first(where: { $0.id == id }) else { return }
                Open.inClaudeCode(p, prompt: """
                    \(name) was just scaffolded with new-mac-app --local. Build it: \(brief) \
                    Follow the new-app skill from step 4 (build it, verify, commit). Don't publish it.
                    """)
            }
        }
    }

    func dismissJob() {
        if job?.isRunning != true { job = nil }
    }

    private func start(_ title: String, _ command: [String], id: Project.ID, in folder: URL,
                       environment: [String: String] = [:], then: (@MainActor (Bool) -> Void)? = nil) {
        if let job, job.isRunning {
            problem = "\(job.title) is still running. Stop it first."
            return
        }
        let job = Job(projectID: id, title: title)
        self.job = job
        do {
            try job.start(command, in: folder, environment: environment) { [weak self] status in
                self?.objectWillChange.send()  // rows show which app is building
                then?(status == 0)
            }
        } catch {
            problem = "\(title): \(error.localizedDescription)"
        }
    }

    static func folder(_ key: String, _ fallback: String) -> URL {
        let path = UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
}

/// A long command whose output streams in as it runs: a build, a test, a scaffold.
@MainActor
final class Job: ObservableObject {
    let projectID: Project.ID
    let title: String
    @Published private(set) var output = ""
    @Published private(set) var lastLine = ""
    @Published private(set) var isRunning = false
    @Published private(set) var status: Int32?

    private var process: Process?
    private var onExit: (@MainActor (Int32) -> Void)?
    private var exited: Int32?
    private var sawEOF = false

    init(projectID: Project.ID, title: String) {
        self.projectID = projectID
        self.title = title
    }

    func start(_ command: [String], in folder: URL, environment extra: [String: String],
               onExit: @escaping @MainActor (Int32) -> Void) throws {
        self.onExit = onExit
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = Shell.environment.merging(extra) { $1 }
        process.currentDirectoryURL = folder
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe  // one stream, in the order it was printed
        process.standardInput = FileHandle.nullDevice
        // Each hop to main is queued in order, so output lands in order and the
        // end of the stream lands after the last of it.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { data.isEmpty ? self.endOfOutput() : self.append(text) }
            }
        }
        process.terminationHandler = { finished in
            let code = finished.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self.exit(code) } }
        }
        append("$ \(command.joined(separator: " "))\n")
        do {
            try process.run()
        } catch {
            append("\(error.localizedDescription)\n")
            status = -1
            throw error
        }
        // Our copy of the write end has to close, or the stream never ends.
        try? pipe.fileHandleForWriting.close()
        self.process = process
        isRunning = true
    }

    // ponytail: terminate() stops make-app.sh but not a swift build it already
    // started; that finishes on its own. Kill the process group if that bites.
    func stop() {
        guard isRunning, let process else { return }
        process.terminate()
        append("\n■ Stopped\n")
        finish(15)
    }

    private func append(_ text: String) {
        output += text
        if output.utf8.count > 600_000 { output = String(output.suffix(400_000)) }
        if let line = text.split(whereSeparator: \.isNewline).last(where: { !$0.allSatisfy(\.isWhitespace) }) {
            lastLine = String(line)
        }
    }

    private func endOfOutput() {
        sawEOF = true
        if let exited { finish(exited) }
    }

    private func exit(_ code: Int32) {
        exited = code
        if sawEOF { finish(code) }
    }

    private func finish(_ code: Int32) {
        guard isRunning else { return }
        isRunning = false
        status = code
        if code != 15 { append(code == 0 ? "\n✓ Done\n" : "\n✗ Exited with status \(code)\n") }
        process?.terminationHandler = nil
        onExit?(code)
        onExit = nil
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

    /// What the detail pane lists: changed files, recent commits, releases.
    static func details(_ p: Project) -> ProjectDetails {
        var d = ProjectDetails()
        guard p.isGit else { return d }
        func git(_ args: String...) -> String { (try? Shell.run(["git"] + args, in: p.url)) ?? "" }
        d.changes = git("status", "--porcelain").split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return .init(status: String(parts[0]), path: parts[1].trimmingCharacters(in: .whitespaces))
        }
        d.commits = git("log", "-8", "--format=%h%x09%s%x09%cr").split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            return f.count == 3 ? .init(hash: String(f[0]), subject: String(f[1]), when: String(f[2])) : nil
        }
        if let repo = p.repo, let out = try? Shell.run([
            "gh", "release", "list", "-R", repo, "--limit", "5", "--json", "tagName,publishedAt",
            "--jq", #".[] | "\(.tagName)\t\(.publishedAt)""#,
        ]) {
            d.releases = out.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t")
                return f.count == 2 ? .init(tag: String(f[0]), date: String(f[1].prefix(10))) : nil
            }
        }
        return d
    }
}

struct ShellError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Shell {
    /// An app opened from Finder gets a bare PATH; Homebrew's gh and
    /// ~/.local/bin's new-mac-app live outside it.
    static let path = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["GIT_TERMINAL_PROMPT"] = "0"  // fail rather than wait on a prompt nobody sees
        env["GH_PROMPT_DISABLED"] = "1"
        return env
    }()

    static var hasGitHubCLI: Bool {
        path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/gh") }
    }

    /// Runs a quick command to the end: its trimmed output, or a ShellError
    /// with what it printed to stderr. Long ones with output to watch are a Job.
    @discardableResult
    static func run(_ command: [String], in folder: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = environment
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

enum Quote {
    /// Single-quoted for the shell: safe for any text.
    static func shell(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// A TOML basic string, quotes included.
    static func toml(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

/// Hands a project to other apps. NSWorkspace rather than Apple Events, which
/// need an entitlement under the hardened runtime and fail silently without one.
@MainActor
enum Open {
    static func inFinder(_ p: Project) { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
    static func inXcode(_ p: Project) { with("com.apple.dt.Xcode", p.url.appending(path: "Package.swift")) }
    static func inTerminal(_ p: Project) { with("com.apple.Terminal", p.url) }

    /// The copy make-app.sh installed, if there is one.
    static func installed(_ p: Project) {
        if let app = p.installedApp { NSWorkspace.shared.open(app) }
    }

    /// Warp's agent, working in the app's folder.
    static func inAITerminal(_ p: Project) { inWarp(p, file: "shipyard", pane: #"type = "agent""#) }

    /// A Warp tab in the app's folder running Claude Code, optionally with a first prompt.
    static func inClaudeCode(_ p: Project, prompt: String? = nil) {
        // One line: Warp types startup commands into the shell.
        let command = prompt.map { "claude " + Quote.shell($0.replacingOccurrences(of: "\n", with: " ")) } ?? "claude"
        inWarp(p, file: "shipyard-claude", pane: "type = \"terminal\"\ncommands = [\(Quote.toml(command))]")
    }

    /// Rewrites a Warp tab config for this app and opens it by URL — Warp's own
    /// way in, no Apple Events. Without Warp, a plain Terminal window.
    private static func inWarp(_ p: Project, file: String, pane: String) {
        guard let warp = URL(string: "warp://tab_config/\(file)"),
              NSWorkspace.shared.urlForApplication(toOpen: warp) != nil
        else { return inTerminal(p) }
        let toml = """
        # Written by Shipyard each time it opens an app; changes here are overwritten.
        name = \(Quote.toml("Shipyard: \(p.name)"))

        [[panes]]
        id = "main"
        \(pane)
        directory = \(Quote.toml(p.url.path))
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

/// App icons, read once per refresh rather than on every row draw.
@MainActor
enum Icons {
    private static var cache: [URL: NSImage] = [:]

    static func image(for url: URL) -> NSImage {
        if let hit = cache[url] { return hit }
        let image = NSImage(contentsOf: url)
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        cache[url] = image
        return image
    }

    static func clear() { cache.removeAll() }
}
