import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var fleet: Fleet
    @State private var selection: Set<Project.ID> = []
    @State private var needsAttentionOnly = false
    @State private var pending: PendingRelease?
    @State private var committing: Project?

    private var rows: [Project] {
        needsAttentionOnly ? fleet.projects.filter { !$0.issues.isEmpty } : fleet.projects
    }

    private var selected: Project? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return fleet.projects.first { $0.id == id }
    }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("App") { p in
                Text(p.name).fontWeight(.medium)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Version") { p in
                Text(p.version ?? "—").monospacedDigit()
            }
            .width(60)
            TableColumn("Released") { p in
                Text(p.released.map { "v\($0)" } ?? (p.releaseChecked ? "none" : "—"))
                    .monospacedDigit()
                    .foregroundStyle(p.isReleasePending ? .orange : .primary)
            }
            .width(70)
            TableColumn("Release Run") { p in
                RunLabel(run: p.releaseRun)
            }
            .width(90)
            TableColumn("Updates") { p in
                Check(on: p.hasUpdates, help: p.hasUpdates ? "Links Sparkle" : "Can't update itself")
            }
            .width(56)
            TableColumn("Site") { p in
                Check(on: p.isProduct, help: p.isProduct ? "On shafer.llc" : "Not in products.php")
            }
            .width(40)
            TableColumn("Needs Attention") { p in
                Text(p.issues.joined(separator: " · "))
                    .foregroundStyle(.orange)
            }
        }
        .contextMenu(forSelectionType: Project.ID.self) { ids in
            if let id = ids.first, ids.count == 1, let p = fleet.projects.first(where: { $0.id == id }) {
                actions(for: p)
            }
        } primaryAction: { ids in
            if let id = ids.first, let p = fleet.projects.first(where: { $0.id == id }) { Open.inAITerminal(p) }
        }
        .overlay {
            if fleet.projects.isEmpty && !fleet.isRefreshing {
                ContentUnavailableView("No Apps Found", systemImage: "shippingbox",
                                       description: Text("No folder in the apps folder has a make-app.sh. Change it in Settings."))
            }
        }
        .safeAreaInset(edge: .top) {
            if !fleet.hasGitHubCLI {
                Label("GitHub CLI not found — install it (brew install gh) to see releases and runs.",
                      systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.yellow.opacity(0.2))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { selected.map(Open.inAITerminal) } label: {
                    Label("Work on It", systemImage: "sparkles.rectangle.stack")
                }
                .help("Open the app's folder in Warp's agent (double-click a row)")
                .disabled(selected == nil)

                Button { committing = selected } label: {
                    Label("Commit", systemImage: "checkmark.seal")
                }
                .help("Commit the selected app's changes")
                .disabled((selected?.changes ?? 0) == 0)

                Menu {
                    if let p = selected { releaseButtons(for: p) }
                } label: {
                    Label("Release", systemImage: "shippingbox.and.arrow.backward")
                }
                .help(selected?.bumpBlocker ?? "Bump the version and cut a release")
                .disabled(selected == nil)
            }
            ToolbarItem {
                Toggle(isOn: $needsAttentionOnly) {
                    Label("Needs Attention", systemImage: "exclamationmark.circle")
                }
                .help("Show only apps that need attention")
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
        }
        .navigationSubtitle("\(fleet.projects.count) apps")
        .sheet(item: $committing) { p in
            CommitSheet(project: p).environmentObject(fleet)
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
        .frame(minWidth: 820, minHeight: 420)
        .task { await fleet.refresh() }
    }

    /// The three bumps, or why none can go out yet.
    @ViewBuilder
    private func releaseButtons(for p: Project) -> some View {
        if let blocker = p.bumpBlocker {
            Text(blocker)
        } else if let current = p.version.flatMap({ Version($0) }) {
            ForEach(Version.Part.allCases, id: \.self) { part in
                let next = current.bumped(part)
                Button("Release \(part.rawValue.capitalized) — v\(next.description)…") {
                    pending = PendingRelease(project: p, part: part, next: next)
                }
            }
        }
    }

    @ViewBuilder
    private func actions(for p: Project) -> some View {
        Button("Work on It in Warp") { Open.inAITerminal(p) }
        Button("Work on It with Claude Code") { Open.inClaudeCode(p) }
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
        releaseButtons(for: p)
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

struct PendingRelease {
    let project: Project
    let part: Version.Part
    let next: Version
}

/// Shows what `git add --all` will pick up before it's committed.
struct CommitSheet: View {
    let project: Project
    @EnvironmentObject private var fleet: Fleet
    @Environment(\.dismiss) private var dismiss
    @State private var files: [String] = []
    @State private var message = ""

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit \(project.name)").font(.headline)
            List(files, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
                .frame(minHeight: 160)
            TextField("Message", text: $message, axis: .vertical)
                .lineLimit(3...8)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Commit") { finish(push: false) }
                    .disabled(files.isEmpty || trimmed.isEmpty)
                Button("Commit and Push") { finish(push: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.isEmpty || trimmed.isEmpty || project.repo == nil)
            }
        }
        .padding()
        .frame(width: 560)
        .task {
            let url = project.url
            files = await Task.detached {
                (try? Shell.run(["git", "status", "--short"], in: url))?
                    .split(separator: "\n").map(String.init) ?? []
            }.value
        }
    }

    private func finish(push: Bool) {
        let text = trimmed
        dismiss()
        Task { await fleet.commit(project, message: text, push: push) }
    }
}

private struct RunLabel: View {
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

struct SettingsView: View {
    @AppStorage(Fleet.appsFolderKey) private var appsFolder = Fleet.defaultAppsFolder
    @AppStorage(Fleet.siteFolderKey) private var siteFolder = Fleet.defaultSiteFolder

    var body: some View {
        Form {
            TextField("Apps folder", text: $appsFolder)
            TextField("shafer.llc site", text: $siteFolder)
            Text("Every folder in the apps folder with a make-app.sh is listed. The site's config/products.php says which are on shafer.llc.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
