import VBXAppCore
import VBXCore
import SwiftUI

/// The static site export wizard.
///
/// A native multi-step sheet in place of bv's `huh` TUI flow. The steps are
/// linear because the work is: you cannot preview a bundle you have not built,
/// or deploy one you have not previewed.
public struct ExportWizard: View {
    public init() {}

    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .configure
    @State private var title = ""
    @State private var directory: URL?
    @State private var interactiveGraph = true
    @State private var githubWorkflow = true

    @State private var repo = ""
    @State private var isPrivate = false
    @State private var target: Target = .gitHub
    @State private var cloudflare: DeployInstructions = .empty

    enum Step: Int, CaseIterable {
        case configure, build, deploy

        var displayName: String {
            switch self {
            case .configure: "Configure"
            case .build: "Build"
            case .deploy: "Publish"
            }
        }
    }

    enum Target: String, CaseIterable, Identifiable {
        case gitHub, cloudflare, none

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .gitHub: "GitHub Pages"
            case .cloudflare: "Cloudflare Pages"
            case .none: "Keep it local"
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch step {
                    case .configure: configureStep
                    case .build: buildStep
                    case .deploy: deployStep
                    }

                    if let error = store.siteError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .onAppear {
            if title.isEmpty { title = store.info?.displayName ?? "Beads" }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ForEach(Step.allCases, id: \.rawValue) { candidate in
                HStack(spacing: 5) {
                    Image(
                        systemName: candidate.rawValue < step.rawValue
                            ? "checkmark.circle.fill" : "\(candidate.rawValue + 1).circle"
                    )
                    .foregroundStyle(candidate == step ? Color.accentColor : .secondary)
                    Text(candidate.displayName)
                        .font(.caption)
                        .foregroundStyle(candidate == step ? .primary : .secondary)
                }
                if candidate != Step.allCases.last {
                    Rectangle().fill(.quaternary).frame(height: 1)
                }
            }
        }
        .padding(14)
    }

    // MARK: - Steps

    private var configureStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A self-contained site: a SQLite payload the page queries in the browser.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                TextField("Site title", text: $title)
                Toggle("Include the interactive graph", isOn: $interactiveGraph)
                Toggle("Add a GitHub Actions workflow", isOn: $githubWorkflow)
            }
            .formStyle(.grouped)

            HStack {
                Button("Choose Folder…") {
                    directory = store.chooseBundleDirectory()
                }
                if let directory {
                    Text(directory.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    // The folder is chosen through a panel because that grant
                    // is what authorises writing outside the container.
                    Text("No folder chosen yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    private var buildStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.siteBusy {
                ProgressView("Building the bundle…")
            } else if store.siteBundle.isBuilt {
                Label(
                    "\(store.siteBundle.issueCount) beads · \(store.siteBundle.formattedSize)",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)

                // The largest files, because a host's size limit is what a
                // deploy actually fails on.
                VStack(alignment: .leading, spacing: 3) {
                    Text("Largest files").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(store.siteBundle.largestFiles) { file in
                        HStack {
                            Text(file.path).font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            Text(file.formattedSize)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(store.siteBundle.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Preview Locally") { Task { await store.previewSite() } }
                        .disabled(store.siteBusy)
                    if store.sitePreview.isRunning {
                        Link(store.sitePreview.url, destination: URL(string: store.sitePreview.url)!)
                            .font(.caption)
                    }
                    Spacer()
                }
            } else {
                Text("Ready to build into \(directory?.path ?? "…").")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var deployStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Publish to", selection: $target) {
                ForEach(Target.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch target {
            case .gitHub: gitHubForm
            case .cloudflare: cloudflareForm
            case .none:
                Text("The bundle is on disk at \(store.siteBundle.outputDir).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gitHubForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                TextField("Repository (owner/name, or just a name)", text: $repo)
                Toggle("Private repository", isOn: $isPrivate)
            }
            .formStyle(.grouped)

            if !Keychain.has(.githubToken) {
                // The token lives in the Keychain rather than an environment
                // variable — where it would also be in every child process
                // and every crash log.
                Label(
                    "No GitHub token stored. Add one in Settings before publishing.",
                    systemImage: "key"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if store.siteDeployment.isDeployed {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Published to \(store.siteDeployment.repo)", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                    if let url = URL(string: store.siteDeployment.pagesURL),
                        !store.siteDeployment.pagesURL.isEmpty
                    {
                        Link(store.siteDeployment.pagesURL, destination: url).font(.caption)
                    }
                    if !store.siteDeployment.verifyHint.isEmpty {
                        Text(store.siteDeployment.verifyHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.siteDeployment.warnings, id: \.self) { warning in
                        Text(warning).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
        .onAppear {
            if repo.isEmpty { repo = store.siteBundle.suggestedRepo }
        }
    }

    private var cloudflareForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reason = store.unavailableReason(.cloudflareInstructions) {
                UnavailableReportLabel(report: .cloudflareInstructions, reason: reason) {
                    cloudflare = await store.cloudflareInstructions(
                        project: store.siteBundle.suggestedProject)
                }
            }
            // Said plainly rather than half-implemented: wrangler's upload
            // protocol cannot be driven from a sandboxed app.
            Label(cloudflare.reason, systemImage: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !cloudflare.command.isEmpty {
                Text(cloudflare.command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cloudflare.command, forType: .string)
                }
            }
        }
        .task {
            cloudflare = await store.cloudflareInstructions(
                project: store.siteBundle.suggestedProject)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Close") {
                store.resetSiteExport()
                dismiss()
            }
            Spacer()
            if step != .configure {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .configure }
            }
            Button(primaryTitle) { Task { await advance() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
        }
        .padding(14)
    }

    private var primaryTitle: String {
        switch step {
        case .configure: "Build"
        case .build: "Continue"
        case .deploy: target == .gitHub ? "Publish" : "Done"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .configure:
            return directory != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty
                && !store.siteBusy
        case .build:
            return store.siteBundle.isBuilt && !store.siteBusy
        case .deploy:
            guard target == .gitHub else { return true }
            return !repo.trimmingCharacters(in: .whitespaces).isEmpty
                && Keychain.has(.githubToken) && !store.siteBusy
        }
    }

    private func advance() async {
        switch step {
        case .configure:
            guard let directory else { return }
            step = .build
            await store.buildSite(
                into: directory, title: title,
                interactiveGraph: interactiveGraph, githubWorkflow: githubWorkflow)
        case .build:
            step = .deploy
        case .deploy:
            if target == .gitHub {
                await store.deploySite(repo: repo, isPrivate: isPrivate)
            } else {
                store.resetSiteExport()
                dismiss()
            }
        }
    }
}

/// Keychain-backed credential fields for Settings.
public struct DeployCredentialsSettings: View {
    public init() {}

    @State private var gitHubToken = ""
    @State private var saved = false

    public var body: some View {
        Section("Deployment") {
            SecureField("GitHub token", text: $gitHubToken)
            HStack {
                Button("Save to Keychain") {
                    saved = Keychain.write(.githubToken, value: gitHubToken)
                    // The field is cleared immediately: there is no reason for
                    // the secret to stay in a view's memory once stored.
                    gitHubToken = ""
                }
                .disabled(gitHubToken.isEmpty)

                if Keychain.has(.githubToken) {
                    Label("Stored", systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Button("Remove") { Keychain.delete(.githubToken) }
                        .font(.caption)
                }
                Spacer()
            }
            Text(
                "Kept in the Keychain rather than an environment variable, where it would "
                    + "also be in every child process and every crash log."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
