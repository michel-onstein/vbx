import AppKit
import VBXAppCore
import VBXCore
import Foundation
import SwiftUI
import Testing

/// Renders SwiftUI views offscreen to PNG.
///
/// This needs no Screen Recording or Accessibility grant — `ImageRenderer`
/// draws through the process's own graphics context rather than capturing the
/// screen — so view rendering is verifiable in environments where screenshotting
/// the live app is not.
@MainActor
enum Snapshot {
    /// Where rendered images land, for a human to inspect after a run.
    static var outputDirectory: URL {
        let dir =
            ProcessInfo.processInfo.environment["VBX_SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vbx-snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Renders `view` and writes it as `<name>.png`.
    ///
    /// Uses a real `NSHostingView` inside an offscreen window rather than
    /// `ImageRenderer`. That matters: `ImageRenderer` does not lay out
    /// `ScrollView` content, so every scrolling view (Board, Insights, Labels,
    /// Inspector) renders completely blank through it. Hosting performs a
    /// genuine AppKit layout and draw, which is also closer to what the running
    /// app puts on screen.
    @discardableResult
    static func render<V: View>(
        _ view: V,
        name: String,
        size: CGSize,
        scale: CGFloat = 2
    ) throws -> RenderResult {
        let root =
            view
            .frame(width: size.width, height: size.height)
            // An explicit ground colour: without it the render is transparent
            // and every "is it blank?" check becomes meaningless.
            .background(Color(nsColor: .windowBackgroundColor))

        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(origin: .zero, size: size)

        // A window is required for SwiftUI to perform a full layout pass;
        // a detached view lays out only partially.
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.setFrame(host.frame, display: true)

        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle: lazy containers resolve their content on the
        // run loop, not synchronously inside layout.
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SnapshotError.renderProducedNoImage(name)
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        guard let cgImage = rep.cgImage else {
            throw SnapshotError.renderProducedNoImage(name)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodingFailed(name)
        }

        let url = outputDirectory.appendingPathComponent("\(name).png")
        try png.write(to: url)

        return RenderResult(
            name: name, url: url, image: cgImage, bytes: png.count,
            pointWidth: size.width, pointHeight: size.height)
    }

    enum SnapshotError: Error, CustomStringConvertible {
        case renderProducedNoImage(String)
        case encodingFailed(String)

        var description: String {
            switch self {
            case .renderProducedNoImage(let n): "ImageRenderer produced no image for \(n)"
            case .encodingFailed(let n): "PNG encoding failed for \(n)"
            }
        }
    }
}

/// A rendered snapshot, with enough introspection to assert it is not blank.
/// A mean colour, in 0…255 per channel.
struct RGB: Equatable {
    let r: Double
    let g: Double
    let b: Double

    /// Manhattan distance, which is enough to say "different" and "how much".
    func distance(to other: RGB) -> Double {
        abs(r - other.r) + abs(g - other.g) + abs(b - other.b)
    }
}

struct RenderResult {
    let name: String
    let url: URL
    let image: CGImage
    let bytes: Int

    var width: Int { image.width }
    var height: Int { image.height }

    /// The size the view was asked for, in points. Recorded so a region can be
    /// given in the same units the caller used.
    let pointWidth: CGFloat
    let pointHeight: CGFloat

    /// Fraction of pixels differing from the modal (background) colour.
    ///
    /// This is the substance check: a view that lays out but draws nothing
    /// still produces a valid PNG, so asserting on file size alone would pass
    /// for a blank canvas.
    func inkCoverage() -> Double {
        inkCoverage(in: nil)
    }

    /// Ink coverage within `region`, in **points** from the top-left, or the
    /// whole image when nil.
    ///
    /// Points rather than pixels so a caller can use the same numbers it passed
    /// to ``Snapshot/render(_:name:size:scale:)`` without knowing the scale.
    ///
    /// The whole-image figure cannot answer "did *this part* draw". For a view
    /// whose scrolling pane fills most of the frame, the pane's own text pushes
    /// coverage past any threshold on its own — so a header that vanished
    /// entirely would still pass.
    func inkCoverage(in region: CGRect?) -> Double {
        guard let data = image.dataProvider?.data,
            let ptr = CFDataGetBytePtr(data)
        else { return 0 }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        guard bytesPerPixel >= 3 else { return 0 }

        // The image is rendered at `scale`, so a region given in points has to
        // be multiplied up. Derived from the image rather than passed, so the
        // two cannot disagree.
        var minX = 0, minY = 0, maxX = width, maxY = height
        if let region {
            let scale = CGFloat(width) / CGFloat(pointWidth)
            minX = max(0, Int(region.minX * scale))
            minY = max(0, Int(region.minY * scale))
            maxX = min(width, Int(region.maxX * scale))
            maxY = min(height, Int(region.maxY * scale))
            guard minX < maxX, minY < maxY else { return 0 }
        }

        // Sample on a grid; a full scan of a 2x-scaled view is needless work.
        let step = max(1, min(maxX - minX, maxY - minY) / 120)
        var histogram: [UInt32: Int] = [:]
        var sampled = 0

        for y in stride(from: minY, to: maxY, by: step) {
            for x in stride(from: minX, to: maxX, by: step) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = UInt32(ptr[offset])
                let g = UInt32(ptr[offset + 1])
                let b = UInt32(ptr[offset + 2])
                // Quantise so antialiasing noise does not fragment the histogram.
                let key = (r / 16) << 16 | (g / 16) << 8 | (b / 16)
                histogram[key, default: 0] += 1
                sampled += 1
            }
        }
        guard sampled > 0, let background = histogram.values.max() else { return 0 }
        return Double(sampled - background) / Double(sampled)
    }

    /// Where the leftmost ink sits, as a fraction of the width — nil when the
    /// image is blank.
    ///
    /// For alignment, which a snapshot flatters: an image of centred content
    /// and an image of leading content both look like "a cell with something in
    /// it", and both pass an ink-coverage check. This is the number that tells
    /// them apart.
    func firstInkFraction() -> Double? { firstInkFraction(in: nil) }

    /// As above, within `region` (points from the top-left), and as a fraction
    /// of *that region's* width.
    ///
    /// Needed because a cell cannot be captured on its own: `cacheDisplay` on a
    /// view inside a table produces a blank image, so the whole hosting view is
    /// captured and the cell's rect is measured inside it.
    func firstInkFraction(in region: CGRect?) -> Double? {
        guard let data = image.dataProvider?.data,
            let ptr = CFDataGetBytePtr(data)
        else { return nil }
        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        guard bytesPerPixel >= 3, width > 0, height > 0 else { return nil }

        var minX = 0, minY = 0, maxX = width, maxY = height
        if let region {
            let scale = CGFloat(width) / CGFloat(pointWidth)
            minX = max(0, Int(region.minX * scale))
            minY = max(0, Int(region.minY * scale))
            maxX = min(width, Int(region.maxX * scale))
            maxY = min(height, Int(region.maxY * scale))
            guard minX < maxX, minY < maxY else { return nil }
        }

        // The background is the region's own top-left corner. Rows are striped
        // and cells draw over a row background rather than transparency, so a
        // fixed white is wrong.
        let corner = minY * bytesPerRow + minX * bytesPerPixel
        let bg = (Int(ptr[corner]), Int(ptr[corner + 1]), Int(ptr[corner + 2]))
        func differs(_ x: Int, _ y: Int) -> Bool {
            let offset = y * bytesPerRow + x * bytesPerPixel
            let delta =
                abs(Int(ptr[offset]) - bg.0) + abs(Int(ptr[offset + 1]) - bg.1)
                + abs(Int(ptr[offset + 2]) - bg.2)
            // A tolerance, because antialiasing puts near-background pixels
            // everywhere and they are not ink.
            return delta > 24
        }

        for x in minX..<maxX {
            for y in minY..<maxY where differs(x, y) {
                return Double(x - minX) / Double(maxX - minX)
            }
        }
        return nil
    }

    /// The mean colour, for comparing two renders of the same thing.
    ///
    /// Ink coverage cannot see a background tint — a plain row and a tinted row
    /// have identical coverage, because both are a flat fill. The average is
    /// what separates them, and it is also how "is the tint subtle?" becomes a
    /// number rather than an opinion.
    func averageColour() -> RGB {
        guard let data = image.dataProvider?.data,
            let ptr = CFDataGetBytePtr(data)
        else { return RGB(r: 0, g: 0, b: 0) }
        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        guard bytesPerPixel >= 3, width > 0, height > 0 else { return RGB(r: 0, g: 0, b: 0) }

        var r = 0, g = 0, b = 0, n = 0
        for y in stride(from: 0, to: height, by: max(1, height / 40)) {
            for x in stride(from: 0, to: width, by: max(1, width / 40)) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                r += Int(ptr[offset])
                g += Int(ptr[offset + 1])
                b += Int(ptr[offset + 2])
                n += 1
            }
        }
        guard n > 0 else { return RGB(r: 0, g: 0, b: 0) }
        return RGB(r: Double(r) / Double(n), g: Double(g) / Double(n), b: Double(b) / Double(n))
    }

    /// Number of visually distinct colours, quantised. A view rendering only
    /// its background scores 1.
    func distinctColors() -> Int {
        guard let data = image.dataProvider?.data,
            let ptr = CFDataGetBytePtr(data)
        else { return 0 }
        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        guard bytesPerPixel >= 3 else { return 0 }

        let step = max(1, min(width, height) / 120)
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = UInt32(ptr[offset]) / 16
                let g = UInt32(ptr[offset + 1]) / 16
                let b = UInt32(ptr[offset + 2]) / 16
                seen.insert(r << 16 | g << 8 | b)
            }
        }
        return seen.count
    }
}

/// Captures an `NSView` hierarchy that already exists, rather than building one.
///
/// `Snapshot.render` hosts a SwiftUI view of its own, which is no use for asking
/// where content sits inside a cell the *table* built.
///
/// Capture the **root** hosting view and measure a sub-rect of the result.
/// Capturing a cell on its own does not work: `cacheDisplay` on a view inside a
/// table returns a uniform, empty image, so every measurement taken from it is
/// nil no matter what is on screen.
@MainActor
enum ViewCapture {
    static func image(of view: NSView) throws -> RenderResult {
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
            let rep = view.bitmapImageRepForCachingDisplay(in: bounds)
        else { throw Snapshot.SnapshotError.renderProducedNoImage("captured view") }
        view.cacheDisplay(in: bounds, to: rep)
        guard let cgImage = rep.cgImage else {
            throw Snapshot.SnapshotError.renderProducedNoImage("captured view")
        }
        return RenderResult(
            name: "captured", url: URL(fileURLWithPath: "/dev/null"), image: cgImage,
            bytes: 0, pointWidth: bounds.width, pointHeight: bounds.height)
    }
}

/// A ProjectStore loaded from the demo fixture, for hosting real views.
@MainActor
enum Fixture {
    static var path: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/demo")
            .path
    }

    /// Fully loaded store, including Phase-2 metrics, so metric-dependent views
    /// render their real content rather than placeholders.
    static func loadedStore() async -> ProjectStore {
        let store = ProjectStore()
        await store.open(path: path)
        await store.computePhase2()
        return store
    }

    /// A store over a private copy of the fixture.
    ///
    /// For anything that writes into the workspace — a baseline, a recipe.
    /// Swift Testing runs tests in parallel, so two of them writing to the
    /// shared fixture interfere: one test removing `<project>/.bv` takes
    /// another's file with it, and the failure surfaces in whichever test
    /// happened to lose the race. A private copy makes that impossible, and
    /// leaves the checkout untouched besides.
    ///
    /// A store over a private copy of the fixture that is a **git repository**,
    /// with everything committed.
    ///
    /// `writableStore()` gives a copy with no history, which is no use for
    /// anything comparing against `HEAD`: with no commit there is nothing to
    /// diff and the state is correctly "unknown" rather than clean. This
    /// commits the fixture first, so the workspace starts genuinely clean and a
    /// write makes exactly one bead dirty.
    ///
    /// Returns the store and the directory, which the caller removes when done.
    static func committedStore() async throws -> (store: ProjectStore, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vbx-git-\(UUID().uuidString)")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: path), to: directory)

        // An identity in the environment rather than in config: it must not
        // depend on whatever the machine running the tests has set, and it must
        // not write into the user's global config either.
        let environment = [
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        ].merging(ProcessInfo.processInfo.environment) { mine, _ in mine }

        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = directory
            process.environment = environment
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }
        try git(["init", "-q"])
        try git(["add", "-A"])
        try git(["commit", "-qm", "fixture"])

        let store = ProjectStore()
        await store.open(path: directory.path)
        return (store, directory)
    }

    /// Returns the store and the directory, which the caller removes when done.
    static func writableStore() async throws -> (store: ProjectStore, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vbx-fixture-\(UUID().uuidString)")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: path), to: directory)

        let store = ProjectStore()
        await store.open(path: directory.path)
        await store.computePhase2()
        return (store, directory)
    }
}
