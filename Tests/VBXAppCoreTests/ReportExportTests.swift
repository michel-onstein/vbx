import VBXCore
import Foundation
import Testing

@testable import VBXAppCore

/// File ▸ Export Report: the store's half, which the sheet calls. The save
/// panel itself cannot run headlessly, so rendering and saving are separate
/// steps and each is exercised here.
private var fixturePath: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
}

@MainActor
private func loadedStore() async -> ProjectStore {
    let store = ProjectStore()
    store.skipPhase2 = true
    await store.open(path: fixturePath)
    return store
}

@MainActor
@Test("The app can export each of bv's four formats", arguments: ReportFormat.allCases)
func appExportsEachFormat(format: ReportFormat) async throws {
    let store = await loadedStore()
    let report = try #require(
        await store.renderReport(ReportRequest(format: format, includeGraph: format.fixedGraph)))
    #expect(report.format == format.rawValue)
    #expect(store.reportError == nil)

    let out = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-app-report-\(UUID()).\(format.fileExtension)")
    defer { try? FileManager.default.removeItem(at: out) }
    #expect(store.saveReport(report, to: out))
    #expect(try String(contentsOf: out, encoding: .utf8) == report.content)
    #expect(store.lastExportPath == out.path)

    await store.close()
}

@MainActor
@Test("The app titles a report after its workspace unless told otherwise")
func appReportTitle() async throws {
    let store = await loadedStore()
    let report = try #require(await store.renderReport(ReportRequest()))
    #expect(report.content.hasPrefix("# demo — Bead Report\n"))

    let named = try #require(await store.renderReport(ReportRequest(title: "Mine")))
    #expect(named.content.hasPrefix("# Mine\n"))
    await store.close()
}

@MainActor
@Test("A template chosen in the app renders the report")
func appReportTemplate() async throws {
    let store = await loadedStore()
    let template = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-app-template-\(UUID()).md")
    defer { try? FileManager.default.removeItem(at: template) }
    try "{{.Title}} has {{len .Issues}} beads\n".write(to: template, atomically: true, encoding: .utf8)

    let report = try #require(await store.renderReport(ReportRequest(template: template.path)))
    #expect(report.content == "demo — Bead Report has 18 beads\n")
    await store.close()
}

@MainActor
@Test("A rejected export is reported in the sheet, not as a load error")
func appReportError() async throws {
    let store = await loadedStore()
    let report = await store.renderReport(ReportRequest(format: .mermaid, includeGraph: false))
    #expect(report == nil)
    #expect(store.reportError?.contains("Mermaid export requires include_graph=true") == true)
    #expect(store.loadError == nil)

    // The next good render clears it.
    _ = await store.renderReport(ReportRequest())
    #expect(store.reportError == nil)
    await store.close()
}
