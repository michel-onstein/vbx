import VBXAppCore
import VBXCore
import SwiftUI
import Testing

@testable import VBXUI

/// File ▸ Export Report's sheet.
@MainActor
@Suite("Report export sheet")
struct ReportExportSheetTests {

    private let template = URL(fileURLWithPath: "/tmp/report.tmpl")

    @Test("Markdown sends the graph choice and the template")
    func markdownRequest() {
        let sheet = ReportExportSheet(format: .markdown, includeGraph: false, template: template)
        #expect(sheet.request == ReportRequest(
            format: .markdown, includeGraph: false, template: template.path))
    }

    @Test("A format with no graph choice sends the one it forces, and no template")
    func forcedGraph() {
        let csv = ReportExportSheet(format: .csv, includeGraph: true, template: template)
        #expect(csv.request == ReportRequest(format: .csv, includeGraph: false))

        let mermaid = ReportExportSheet(format: .mermaid, includeGraph: false, template: template)
        #expect(mermaid.request == ReportRequest(format: .mermaid, includeGraph: true))

        let json = ReportExportSheet(format: .json, includeGraph: false, template: template)
        #expect(json.request == ReportRequest(format: .json, includeGraph: false))
    }

    @Test("Every request the sheet can send renders", arguments: ReportFormat.allCases)
    func everyRequestRenders(format: ReportFormat) async throws {
        let store = await Fixture.loadedStore()
        for includeGraph in [true, false] {
            let sheet = ReportExportSheet(format: format, includeGraph: includeGraph)
            let report = await store.renderReport(sheet.request)
            #expect(report?.format == format.rawValue, "\(store.reportError ?? "")")
        }
        await store.close()
    }

    @Test("The sheet renders")
    func rendersSheet() async throws {
        let store = await Fixture.loadedStore()
        let result = try Snapshot.render(
            ReportExportSheet(format: .markdown, template: template).environmentObject(store),
            name: "report-export-sheet",
            size: CGSize(width: 480, height: 320)
        )
        #expect(result.inkCoverage() > 0.01, "sheet drew nothing")
        await store.close()
    }
}
