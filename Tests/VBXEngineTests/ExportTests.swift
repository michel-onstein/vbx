import VBXCore
import Foundation
import Testing

@testable import VBXEngine

private var fixturePath: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo")
        .path
}

@Test("A report defaults to bv's Markdown, Mermaid graph included")
func exportReportDefault() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)
    defer { Task { await engine.close() } }

    let report = try await engine.exportReport(ReportRequest(title: "Test Report"))

    #expect(report.format == "markdown")
    #expect(report.includeGraph)
    #expect(report.content.hasPrefix("# Test Report"))
    #expect(report.bytes == report.content.utf8.count)
    // Nothing was written, because no path was given.
    #expect(report.path.isEmpty)

    // The diagram is the reason this goes through the engine rather than being
    // reimplemented in Swift.
    #expect(report.content.contains("```mermaid"))
    #expect(report.content.contains("## Dependency Graph"))
    #expect(report.content.contains("## Summary"))

    // Every bead should appear in the report.
    #expect(report.issueCount == 18)
    for id in ["vbx-1", "vbx-3", "vbx-18"] {
        #expect(report.content.contains(id), "report omits \(id)")
    }

    await engine.close()
}

@Test("Each of bv's four formats renders", arguments: ReportFormat.allCases)
func exportReportFormats(format: ReportFormat) async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)

    let report = try await engine.exportReport(
        ReportRequest(format: format, includeGraph: format.fixedGraph))

    #expect(report.format == format.rawValue)
    #expect(!report.content.isEmpty)
    switch format {
    case .markdown: #expect(report.content.hasPrefix("# Beads Export"))
    case .json:
        let object = try JSONSerialization.jsonObject(with: Data(report.content.utf8))
        #expect((object as? [String: Any])?["issues"] != nil)
    case .csv: #expect(report.content.hasPrefix("id,title,status,priority"))
    case .mermaid: #expect(report.content.hasPrefix("graph TD"))
    }

    await engine.close()
}

@Test("A graph-less Markdown report has no diagram")
func exportReportWithoutGraph() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)

    let report = try await engine.exportReport(ReportRequest(includeGraph: false))
    #expect(!report.includeGraph)
    #expect(!report.content.contains("```mermaid"))

    await engine.close()
}

@Test("A template renders the Markdown report")
func exportReportTemplate() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)

    let template = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-template-\(UUID()).md")
    defer { try? FileManager.default.removeItem(at: template) }
    try "{{.Title}}: {{len .Issues}}\n".write(to: template, atomically: true, encoding: .utf8)

    let report = try await engine.exportReport(ReportRequest(template: template.path))
    #expect(report.content == "Beads Export: 18\n")
    #expect(report.template == template.path)

    await engine.close()
}

@Test("A combination bv rejects is an error, not an empty report")
func exportReportRejected() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)

    await #expect(throws: (any Error).self) {
        _ = try await engine.exportReport(ReportRequest(format: .mermaid, includeGraph: false))
    }
    await #expect(throws: (any Error).self) {
        _ = try await engine.exportReport(ReportRequest(format: .csv, includeGraph: true))
    }
    await engine.close()
}

@Test("A report writes to disk when given a path")
func exportReportToFile() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)

    let out = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vbx-report-\(UUID()).md")
    defer { try? FileManager.default.removeItem(at: out) }

    let report = try await engine.exportReport(ReportRequest(title: "Written"), path: out.path)
    #expect(report.path == out.path)

    let onDisk = try String(contentsOf: out, encoding: .utf8)
    #expect(onDisk == report.content, "the file must match what was returned")
    #expect(onDisk.contains("# Written"))

    await engine.close()
}

@Test("Exporting to an unwritable path reports an error")
func exportReportBadPath() async throws {
    let engine = BeadsEngine()
    _ = try await engine.open(path: fixturePath)

    await #expect(throws: (any Error).self) {
        _ = try await engine.exportReport(
            ReportRequest(title: "Nope"), path: "/definitely/not/a/directory/report.md")
    }
    await engine.close()
}
