import AppKit
import SwiftUI

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
            HStack(spacing: 10) {
                AppIcon(project: project, size: 32)
                Text("Commit \(project.name)").font(.headline)
            }
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

/// new-mac-app from a form: name, one sentence, and optionally what to build.
struct NewAppSheet: View {
    @EnvironmentObject private var fleet: Fleet
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var about = ""
    @State private var brief = ""

    private var slug: String { name.lowercased() }

    private var nameProblem: String? {
        guard !name.isEmpty else { return nil }
        if !Project.isValidName(name) { return "One capitalized word, like Swab or Wheelhouse." }
        if FileManager.default.fileExists(atPath: Fleet.appsFolder.appending(path: slug).path) {
            return "There's already a \(slug) folder."
        }
        return nil
    }

    private var canCreate: Bool {
        !name.isEmpty && nameProblem == nil && !about.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New App").font(.title3.bold())
                    Text("A Shafer LLC Mac app from new-mac-app: registration, CI and the signed release, built and tested.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Name", text: $name, prompt: Text("Swab"))
                if let nameProblem {
                    Text(nameProblem).font(.caption).foregroundStyle(.red)
                }
                TextField("One sentence", text: $about, prompt: Text("What it does, for the README and GitHub."))
                TextField("What should it do?", text: $brief,
                          prompt: Text("Optional. Claude Code builds it from this."), axis: .vertical)
                    .lineLimit(3...6)
            }
            Text("Local only: no GitHub repo or shafer.llc entry until you publish it with new-mac-app --publish.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    fleet.createApp(name: name,
                                    about: about.trimmingCharacters(in: .whitespaces),
                                    brief: brief.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

struct ConsoleSheet: View {
    @ObservedObject var job: Job
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(job.title).font(.headline)
                Spacer()
                if job.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop", role: .destructive) { job.stop() }
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.output, forType: .string)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ConsoleView(job: job)
        }
        .frame(width: 760, height: 520)
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
