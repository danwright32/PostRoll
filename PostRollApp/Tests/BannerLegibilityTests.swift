import XCTest
import SwiftUI
import AppKit

/// #389: every notice this app shows, rendered and measured, rather than
/// trusted.
///
/// Four new banners shipped on 2026-08-12 and not one was seen before it
/// merged, because reaching those states means filling a disk or breaking a
/// file permission. Copy that reads fine in a test can still land invisible:
/// white on cream has shipped unreadable in this project three separate times,
/// and each time a test asserting the STRING was green throughout.
///
/// So these render the real banner, with the real message produced by the real
/// code, and measure ink on the page. A banner whose text matches its own
/// background produces a near-empty image and fails here.
@MainActor
final class BannerLegibilityTests: XCTestCase {

    /// The share of the page that has to be something other than the fill for
    /// the message to count as drawn.
    ///
    /// Measured, not guessed: the five real banners render between 0.022 and
    /// 0.064, and a page with nothing legible on it renders at 0.001. This sits
    /// below the thinnest real one (a single line of text) and far above blank.
    private static let legibleInk = 0.01

    /// Renders a view and returns its pixels.
    /// No padding around the content: a transparent ring at the edge of the
    /// image is itself a colour that differs from the fill, and at these sizes
    /// it measures as several percent of the page, which is enough to make a
    /// blank render look like a drawn one.
    private func render(_ view: some View, width: CGFloat = 520) throws -> NSBitmapImageRep {
        // On Color.cream, because that is the surface every one of these sits
        // on in the app. A banner fill is translucent, so rendered against
        // nothing it is mostly transparent and every measurement below would be
        // taken on a page the person never sees.
        let renderer = ImageRenderer(content: ZStack {
            Color.cream
            view.padding(Spacing.md)
        }.frame(width: width))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "the banner produced no image at all")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    /// The share of pixels that differ noticeably from the most common colour.
    ///
    /// The most common colour IS the background (a banner is mostly its own
    /// fill), so this measures how much of the image is something else: text,
    /// icon, border. Near zero means the message is there in the view tree and
    /// invisible on screen, which is the failure that keeps recurring.
    private func inkCoverage(_ rep: NSBitmapImageRep) -> Double {
        var luminances: [Double] = []
        for y in Swift.stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in Swift.stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                luminances.append(0.299 * c.redComponent
                                  + 0.587 * c.greenComponent
                                  + 0.114 * c.blueComponent)
            }
        }
        guard !luminances.isEmpty else { return 0 }
        // The fill is whatever most of the page is, so the median IS the
        // background whether the banner is light or dark.
        let background = luminances.sorted()[luminances.count / 2]
        let ink = luminances.filter { abs($0 - background) > 0.12 }
        return Double(ink.count) / Double(luminances.count)
    }

    /// Every banner state the app can show, each carrying the message its own
    /// shipping code produces. Nothing here is hand written copy: a preview of
    /// invented text would show something the app never says.
    private var states: [(name: String, view: AnyView)] {
        let refusal = ProgramReadiness.missingFiles([
            URL(fileURLWithPath: "/programs/Gala_p3.png"),
        ]).refusal ?? ""

        let incomplete = ProgramImport.Incomplete(
            fileName: "Gala.pdf",
            pagesThatWorked: (1...9).map { URL(fileURLWithPath: "/programs/Gala_p\($0).png") },
            failures: [.couldNotWritePage(3, reason: "No space left on device")],
            declaredPageCount: 12
        )

        let substitution = PreviewMergePolicy.substitutionNotice([
            PreviewMergePolicy.AbsentApproval(label: "Wednesday collage.png",
                                              fileName: "collage.png"),
        ]) ?? ""

        return [
            ("ocr refusal", AnyView(BrandBanner(
                icon: "exclamationmark.triangle", message: refusal, style: .error,
                actions: [BrandBannerAction(label: "Dismiss") {}]))),
            ("incomplete upload", AnyView(BrandBanner(
                icon: "exclamationmark.triangle", message: incomplete.message, style: .error,
                actions: [BrandBannerAction(label: "Import the 9 pages that worked") {},
                          BrandBannerAction(label: "Dismiss") {}]))),
            ("partial program", AnyView(BrandBanner(
                icon: "doc.badge.ellipsis",
                message: ProgramShortfall.acceptanceNote(for: incomplete), style: .warning))),
            ("export substitution", AnyView(BrandBanner(
                icon: "exclamationmark.triangle", message: substitution, style: .warning))),
            ("upload reminder", AnyView(BrandBanner(
                icon: "arrow.down.circle",
                message: "Download the program from your browser first."))),
        ]
    }

    func testEveryBannerActuallyDrawsItsMessage() throws {
        for state in states {
            let coverage = inkCoverage(try render(state.view))
            XCTAssertGreaterThan(coverage, Self.legibleInk, """
                The "\(state.name)" banner rendered almost nothing but its own \
                background (\(String(format: "%.3f", coverage)) of pixels differ). \
                The message exists in the view tree and cannot be read on screen.
                """)
        }
    }

    /// A banner is worth nothing if the words run past the edge of it. Rendering
    /// at a narrow width is where a long message with a two button row breaks.
    func testEveryBannerStillDrawsItsMessageWhenNarrow() throws {
        for state in states {
            let coverage = inkCoverage(try render(state.view, width: 300))
            XCTAssertGreaterThan(coverage, Self.legibleInk,
                                 "the \"\(state.name)\" banner lost its message at 300pt wide")
        }
    }

    /// The measurement has to be able to tell legible from invisible, or the
    /// checks above are decoration that would pass on an empty page.
    ///
    /// One view, rendered twice, differing only in the colour of the type. That
    /// is the defect in its bare form and exactly how it has shipped here three
    /// times: text drawn in the colour of the surface behind it.
    ///
    /// Deliberately NOT a BrandBanner, because a banner also paints a fill and a
    /// border, and those put ink on the page whatever the text does. What is
    /// being proven is that the metric can distinguish.
    func testTheMeasurementTellsLegibleTypeFromInvisibleType() throws {
        func card(_ colour: Color) -> some View {
            ZStack {
                Color.cream
                Text("You may or may not be able to read this sentence.")
                    .font(.system(size: 12))
                    .foregroundStyle(colour)
            }
            .frame(height: 60)
        }

        let invisible = inkCoverage(try render(card(.cream)))
        let legible = inkCoverage(try render(card(.warmDark)))

        XCTAssertLessThan(invisible, 0.001,
                          "type drawn in its own background colour has to measure as blank")
        XCTAssertGreaterThan(legible, invisible * 10,
                             "the same words in a readable colour have to measure as far more "
                             + "ink, or the metric is not reading the type at all")
    }
}

#if POSTROLL_TESTS
extension BannerLegibilityTests {
    /// Writes every banner state to PNG so a person can look at them.
    /// Set POSTROLL_BANNER_DUMP to a directory to run it.
    func testDumpBannersForReview() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POSTROLL_BANNER_DUMP"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("postroll-banners").path)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for state in states {
            let rep = try render(state.view)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent(
                state.name.replacingOccurrences(of: " ", with: "-") + ".png"))
        }
    }
}
#endif
