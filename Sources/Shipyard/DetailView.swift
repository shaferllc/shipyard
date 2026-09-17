import AppKit
import SwiftUI

/// The selected app: everything you can do to it, and what it's been up to.
struct ProjectDetail: View {
    let project: Project
    @Binding var committing: Project?
    @Binding var pending: PendingRelease?
    // Passed in, not @EnvironmentObject: the inspector, table cells and menus
    // don't reliably inherit environment objects.
    @ObservedObject var fleet: Fleet
    @State private var details = ProjectDetails()

    /// The job for this app, if the current one is.
    private var job: Job? { fleet.job?.projectID == project.id ? fleet.job : nil }
    private var busy: Bool { fleet.job?.isRunning == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                actions
                if !project.issues.isEmpty { attention }
                if let job {
                    section("Console") {
                        ConsoleView(job: job)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                    }
                }
                facts
                if !details.changes.isEmpty { changes }
                if !details.commits.isEmpty { commits }
                if !details.releases.isEmpty { releases }
            }
            .padding(16)
        }
        .task(id: "\(project.id)#\(fleet.generation)") {
            let p = project
            details = await Task.detached { Scanner.details(p) }.value
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIcon(project: project, size: 60)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.title2.bold())
                Text(project.repo ?? "Not on GitHub")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Pill(text: "v\(project.version ?? "?")", tint: .accentColor)
                    if let released = project.released {
                        Pill(text: "shipped v\(released)", tint: project.isReleasePending ? .orange : .green)
                    }
                    RunLabel(run: project.releaseRun).font(.caption)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("Work on It") {
                Tile("Warp Agent", "sparkles") { Open.inAITerminal(project) }
                Tile("Claude Code", "terminal") { Open.inClaudeCode(project) }
                Tile("Xcode", "hammer") { Open.inXcode(project) }
                Tile("Finder", "folder") { Open.inFinder(project) }
            }
            group("Build") {
                Tile("Build & Run", "play.fill") { fleet.build(project) }.disabled(busy)
                Tile("Test", "checklist") { fleet.test(project) }.disabled(busy)
                Tile("Package", "archivebox") { fleet.package(project) }.disabled(busy)
                // Sign, notarize and publish from here. Right-click for the
                // dry run: the whole thing short of making it public.
                Tile("Ship", "paperplane.fill") { fleet.ship(project) }
                    .disabled(busy)
                    .contextMenu { Button("Dry Run…") { fleet.ship(project, dryRun: true) } }
                if let job, job.isRunning {
                    Tile("Stop", "stop.fill", tint: .red) { job.stop() }
                } else {
                    Tile("Launch", "arrow.up.forward.app") { Open.installed(project) }
                        .disabled(project.installedApp == nil)
                }
            }
            group("Ship") {
                Tile("Commit", "checkmark.circle") { committing = project }
                    .disabled(project.changes == 0)
                Tile("Push", "arrow.up.circle") { Task { await fleet.push(project) } }
                    .disabled((project.unpushed ?? 0) == 0)
                ForEach(Version.Part.allCases, id: \.self) { part in
                    let next = project.version.flatMap { Version($0) }?.bumped(part)
                    Tile(part.rawValue.capitalized + (next.map { " v\($0.description)" } ?? ""),
                         "shippingbox", tint: .purple) {
                        if let next { pending = PendingRelease(project: project, part: part, next: next) }
                    }
                    .disabled(project.bumpBlocker != nil)
                }
            }
            // Folded into this row rather than listed as apps of their own —
            // still worth naming, or an old release branch checked out beside
            // the repo becomes invisible.
            if !project.checkouts.isEmpty {
                group("Other Checkouts") {
                    ForEach(project.checkouts) { checkout in
                        Tile("\(checkout.slug) · \(checkout.branch ?? "detached")", "arrow.triangle.branch") {
                            Open.inFinder(checkout)
                        }
                    }
                }
            }
            if let blocker = project.bumpBlocker, project.isGit {
                Label(blocker, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var attention: some View {
        section("Needs Attention") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(project.issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    if project.releaseRun == "failure" {
                        Button("Re-run Release") { Task { await fleet.rerunRelease(project) } }
                        Button("See Why") { Open.onGitHub(project, "/actions/workflows/release.yml") }
                    }
                    if project.changes > 0 { Button("Commit…") { committing = project } }
                    if (project.unpushed ?? 0) > 0 { Button("Push") { Task { await fleet.push(project) } } }
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.08)))
        }
    }

    private var facts: some View {
        section("Status") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                fact("Branch", project.branch ?? "—")
                fact("Uncommitted", "\(project.changes) file\(project.changes == 1 ? "" : "s")")
                fact("Unpushed", project.unpushed.map { "\($0) commit\($0 == 1 ? "" : "s")" } ?? "no upstream")
                fact("Auto-updates", project.hasUpdates ? "Sparkle" : "None")
                fact("shafer.llc", project.isProduct ? "Listed" : "Not listed")
                fact("Installed", project.installedApp == nil ? "No" : "/Applications")
            }
            .font(.callout)
        }
    }

    private var changes: some View {
        section("Changes") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(details.changes.prefix(12)) { change in
                    HStack(spacing: 8) {
                        Text(change.status)
                            .font(.caption.monospaced().bold())
                            .foregroundStyle(change.status == "??" ? .green : .orange)
                            .frame(width: 22, alignment: .leading)
                        Text(change.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if details.changes.count > 12 {
                    Text("and \(details.changes.count - 12) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var commits: some View {
        section("Recent Commits") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(details.commits) { commit in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(commit.subject).lineLimit(1)
                        Text("\(commit.hash) · \(commit.when)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var releases: some View {
        section("Releases") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(details.releases) { release in
                    HStack {
                        if let repo = project.repo, let url = URL(string: "https://github.com/\(repo)/releases/tag/\(release.tag)") {
                            Link(release.tag, destination: url).font(.callout.monospaced())
                        }
                        Spacer()
                        Text(release.date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) { content() }
        }
    }
}

/// A big square action button: symbol over a short label.
struct Tile: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    let action: () -> Void

    init(_ title: String, _ symbol: String, tint: Color = .accentColor, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).frame(height: 20)
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(TileStyle(tint: tint))
    }
}

private struct TileStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration, tint: tint)
    }

    private struct TileBody: View {
        let configuration: Configuration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? tint : Color.secondary)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(configuration.isPressed ? 0.24 : 0.10)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.20)))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
    }
}

struct Pill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium).monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

/// A job's output, following the end as it grows.
struct ConsoleView: View {
    @ObservedObject var job: Job

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(job.output)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: job.output.utf8.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}
