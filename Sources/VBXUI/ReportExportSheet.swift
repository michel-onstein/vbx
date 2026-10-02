import VBXAppCore
import VBXCore
import SwiftUI

/// File ▸ Export Report: bv 0.25's `--export`, as a sheet.
///
/// The four formats, whether to include the dependency graph, and — for
/// Markdown — a custom template. The engine renders and validates; this only
/// collects the options, and greys out the graph choice where the format
/// leaves none (CSV never carries a graph, Mermaid is nothing else).
public struct ReportExportSheet: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var format: ReportFormat
    @State private var includeGraph: Bool
    @State private var template: URL?
    @State private var busy = false

    public init(
        format: ReportFormat = .markdown, includeGraph: Bool = true, template: URL? = nil
    ) {
        _format = State(initialValue: format)
        _includeGraph = State(initialValue: includeGraph)
        _template = State(initialValue: template)
    }

    /// The request the current controls describe. The graph setting is sent
    /// only where the format allows a choice, and the template only for
    /// Markdown, so a hidden control can never make an export fail.
    var request: ReportRequest {
        ReportRequest(
            format: format,
            includeGraph: format.fixedGraph ?? includeGraph,
            template: format.acceptsTemplate ? template?.path : nil)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export Report")
                .font(.headline)
                .padding(16)
            Divider()

            Form {
                Picker("Format", selection: $format) {
                    ForEach(ReportFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(
                    "Include dependency graph",
                    isOn: Binding(
                        get: { format.fixedGraph ?? includeGraph },
                        set: { includeGraph = $0 })
                )
                .disabled(format.fixedGraph != nil)
                .help(graphHelp)

                LabeledContent("Template") {
                    HStack {
                        Text(template?.lastPathComponent ?? "Built-in layout")
                            .foregroundStyle(template == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            if let url = store.chooseReportTemplate() { template = url }
                        }
                        Button("Clear") { template = nil }
                            .disabled(template == nil)
                    }
                }
                .disabled(!format.acceptsTemplate)
                .help("A Go text/template file; Markdown only")

                if let error = store.reportError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    busy = true
                    Task {
                        let saved = await store.exportReport(request)
                        busy = false
                        if saved { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || !store.isLoaded)
            }
            .padding(16)
        }
        .frame(width: 480)
    }

    private var graphHelp: String {
        switch format.fixedGraph {
        case false?: "A CSV report has no room for a graph"
        case true?: "A Mermaid report is the graph"
        case nil: "Adds the selected beads' dependency context"
        }
    }
}
