import AppKit
import SwiftUI

enum Filter: String, CaseIterable, Identifiable {
    case all = "All Apps"
    case attention = "Needs Attention"
    case releasing = "Releasing"
    case noUpdates = "No Auto-Updates"

    var id: Self { self }

    func includes(_ p: Project) -> Bool {
        switch self {
        case .all: true
        case .attention: !p.issues.isEmpty
        case .releasing: p.isReleaseRunning
        case .noUpdates: p.isGit && !p.hasUpdates
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var fleet: Fleet
    @State private var selection: Set<Project.ID> = []
    @State private var filter = Filter.all
    @State private var search = ""
    @State private var showInspector = true
    @State private var showLog = false
    @State private var committing: Project?
    @State private var pending: PendingRelease?

    private var rows: [Project] {
        fleet.projects.filter {
            filter.includes($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }
    }

    private var selected: Project? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return fleet.projects.first { $0.id == id }
    }

    private var summary: String {
        let attention = fleet.projects.filter { !$0.issues.isEmpty }.count
        let releasing = fleet.projects.filter(\.isReleaseRunning).count
        var parts = ["\(fleet.projects.count) apps"]
        if attention > 0 { parts.append("\(attention) need attention") }
        if releasing > 0 { parts.append("\(releasing) releasing") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        table
            .inspector(isPresented: $showInspector) {
                Group {
                    if let p = selected {
                        ProjectDetail(project: p, committing: $committing, pending: $pending, fleet: fleet)
                    } else {
                        ContentUnavailableView("Select an App", systemImage: "sidebar.right",
                                               description: Text("Its builds, commits and releases show here."))
                    }
                }
                .inspectorColumnWidth(min: 340, ideal: 400, max: 560)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let job = fleet.job { ActivityBar(job: job, showLog: $showLog, fleet: fleet) }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Find an app")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { fleet.isCreatingApp = true } label: {
                        Label("New App", systemImage: "plus")
                    }
                    .help("Scaffold a new app (⌘N)")
                }
                ToolbarItem {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .help("Which apps to show")
                }
                ToolbarItem {
                    if fleet.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await fleet.refresh() } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Read every app again (⌘R)")
                    }
                }
                ToolbarItem {
                    Button { showInspector.toggle() } label: {
                        Label("Details", systemImage: "sidebar.right")
                    }
                    .help("Show or hide the selected app's details")
                }
            }
            .navigationSubtitle(summary)
            .sheet(item: $committing) { CommitSheet(project: $0).environmentObject(fleet) }
            .sheet(isPresented: $fleet.isCreatingApp) { NewAppSheet().environmentObject(fleet) }
            .sheet(isPresented: $showLog) {
                if let job = fleet.job { ConsoleSheet(job: job) }
            }
            .confirmationDialog(
                pending.map { "Release \($0.project.name) v\($0.next.description)?" } ?? "",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                presenting: pending
            ) { r in
                Button("Commit and Push") { Task { await fleet.release(r.project, r.part) } }
            } message: { _ in
                Text("Commits VERSION and pushes main. GitHub Actions then builds, signs, notarizes and publishes the release.")
            }
            .alert("Couldn't finish", isPresented: Binding(get: { fleet.problem != nil }, set: { if !$0 { fleet.problem = nil } })) {
                Button("OK") {}
            } message: {
                Text(fleet.problem ?? "")
            }
            .onChange(of: fleet.focus) { _, id in
                guard let id else { return }
                filter = .all
                search = ""
                selection = [id]
                fleet.focus = nil
            }
            .frame(minWidth: 1000, minHeight: 480)
            .task { await fleet.refresh() }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("App") { p in
                HStack(spacing: 8) {
                    AppIcon(project: p, size: 22)
                    Text(p.name).fontWeight(.medium)
                    if let job = fleet.job, job.projectID == p.id, job.isRunning {
                        ProgressView().controlSize(.mini).help(job.title)
                    }
                }
            }
            .width(min: 130, ideal: 150)
            TableColumn("Version") { p in
                Text(p.version ?? "—").monospacedDigit()
            }
            .width(58)
            TableColumn("Released") { p in
                Text(p.released.map { "v\($0)" } ?? (p.releaseChecked ? "none" : "—"))
                    .monospacedDigit()
                    .foregroundStyle(p.isReleasePending ? .orange : .primary)
            }
            .width(64)
            TableColumn("Release") { p in
                RunLabel(run: p.releaseRun)
            }
            .width(86)
            TableColumn("Updates") { p in
                Check(on: p.hasUpdates, help: p.hasUpdates ? "Links Sparkle" : "Can't update itself")
            }
            .width(52)
            TableColumn("Site") { p in
                Check(on: p.isProduct, help: p.isProduct ? "On shafer.llc" : "Not in products.php")
            }
            .width(34)
            TableColumn("Needs Attention") { p in
                Text(p.issues.joined(separator: " · "))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(p.issues.joined(separator: "\n"))
            }
            TableColumn("") { p in
                RowActions(project: p, committing: $committing, pending: $pending, fleet: fleet)
            }
            .width(112)
        }
        .contextMenu(forSelectionType: Project.ID.self) { ids in
            if let id = ids.first, ids.count == 1, let p = fleet.projects.first(where: { $0.id == id }) {
                ProjectMenu(project: p, committing: $committing, pending: $pending, fleet: fleet)
            }
        } primaryAction: { ids in
            if let id = ids.first, let p = fleet.projects.first(where: { $0.id == id }) { Open.inAITerminal(p) }
        }
        .overlay {
            if rows.isEmpty && !fleet.isRefreshing {
                if fleet.projects.isEmpty {
                    ContentUnavailableView("No Apps Found", systemImage: "shippingbox",
                                           description: Text("No folder in the apps folder has a make-app.sh. Change it in Settings."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !fleet.hasGitHubCLI {
                Label("GitHub CLI not found — install it (brew install gh) to see releases and runs.",
                      systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.yellow.opacity(0.2))
            }
        }
    }
}

struct PendingRelease {
    let project: Project
    let part: Version.Part
    let next: Version
}

/// The fast path on every row: build, work on it, commit, release.
private struct RowActions: View {
    let project: Project
    @Binding var committing: Project?
    @Binding var pending: PendingRelease?
    @ObservedObject var fleet: Fleet

    var body: some View {
        HStack(spacing: 12) {
            Button { fleet.build(project) } label: { Image(systemName: "play.fill") }
                .help("Build & Run: install to /Applications and launch")
                .disabled(fleet.job?.isRunning == true)
            Button { Open.inAITerminal(project) } label: { Image(systemName: "sparkles") }
                .help("Work on it in Warp's agent")
            Button { committing = project } label: { Image(systemName: "checkmark.circle") }
                .help(project.changes > 0 ? "Commit \(project.changes) change(s)" : "Nothing to commit")
                .disabled(project.changes == 0)
            Menu {
                ReleaseItems(project: project, pending: $pending)
            } label: {
                Image(systemName: "shippingbox")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(project.bumpBlocker ?? "Release a new version")
        }
        .buttonStyle(.borderless)
    }
}

/// The three version bumps, or why none can go out yet.
struct ReleaseItems: View {
    let project: Project
    @Binding var pending: PendingRelease?

    var body: some View {
        if let blocker = project.bumpBlocker {
            Text(blocker)
        } else if let current = project.version.flatMap({ Version($0) }) {
            ForEach(Version.Part.allCases, id: \.self) { part in
                let next = current.bumped(part)
                Button("Release \(part.rawValue.capitalized) — v\(next.description)…") {
                    pending = PendingRelease(project: project, part: part, next: next)
                }
            }
        }
    }
}

/// Everything, for the right-click menu.
private struct ProjectMenu: View {
    let project: Project
    @Binding var committing: Project?
    @Binding var pending: PendingRelease?
    @ObservedObject var fleet: Fleet

    var body: some View {
        let p = project
        Button("Work on It in Warp") { Open.inAITerminal(p) }
        Button("Work on It with Claude Code") { Open.inClaudeCode(p) }
        Divider()
        Button("Build & Run") { fleet.build(p) }
        Button("Test") { fleet.test(p) }
        Button("Package for Release") { fleet.package(p) }
        if p.installedApp != nil {
            Button("Launch Installed Copy") { Open.installed(p) }
        }
        Divider()
        if p.changes > 0 {
            Button("Commit \(p.changes) Change\(p.changes == 1 ? "" : "s")…") { committing = p }
        }
        if let unpushed = p.unpushed, unpushed > 0 {
            Button("Push \(unpushed) Commit\(unpushed == 1 ? "" : "s")") { Task { await fleet.push(p) } }
        }
        if p.releaseRun == "failure" {
            Button("Re-run Failed Release") { Task { await fleet.rerunRelease(p) } }
        }
        ReleaseItems(project: p, pending: $pending)
        Divider()
        Button("Open in Xcode") { Open.inXcode(p) }
        Button("Open in Terminal") { Open.inTerminal(p) }
        Button("Show in Finder") { Open.inFinder(p) }
        if p.repo != nil {
            Divider()
            Button("Open on GitHub") { Open.onGitHub(p) }
            Button("Releases") { Open.onGitHub(p, "/releases") }
            Button("Release Runs") { Open.onGitHub(p, "/actions/workflows/release.yml") }
        }
    }
}

/// The running (or last) job across the bottom of the window.
private struct ActivityBar: View {
    @ObservedObject var job: Job
    @Binding var showLog: Bool
    @ObservedObject var fleet: Fleet

    var body: some View {
        HStack(spacing: 10) {
            if job.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: job.status == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(job.status == 0 ? .green : .red)
            }
            Text(job.title).fontWeight(.semibold)
            Text(job.lastLine)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button("Show Log") { showLog = true }
            if job.isRunning {
                Button("Stop", role: .destructive) { job.stop() }
            } else {
                Button { fleet.dismissJob() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct RunLabel: View {
    let run: String?

    var body: some View {
        switch run {
        case nil: Text("—").foregroundStyle(.secondary)
        case "success": Label("Passed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case "failure": Label("Failed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case "in_progress", "queued", "waiting", "pending": Label("Running", systemImage: "clock").foregroundStyle(.blue)
        case let other?: Text(other.replacingOccurrences(of: "_", with: " ").capitalized).foregroundStyle(.secondary)
        }
    }
}

private struct Check: View {
    let on: Bool
    let help: String

    var body: some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(on ? .green : .secondary)
            .help(help)
    }
}

struct AppIcon: View {
    let project: Project
    var size: CGFloat = 22

    var body: some View {
        Image(nsImage: Icons.image(for: project.iconURL))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
