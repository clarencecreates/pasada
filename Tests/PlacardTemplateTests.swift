import XCTest
@testable import Widyip

final class PlacardTemplateTests: XCTestCase {
    private func sampleSign() -> SignDraft {
        SignDraft(layers: [
            TextLayer(text: "BASTA", font: .wide, fontFamily: .cubao, size: 1.16, x: 0.5, y: 0.22,
                      curve: 0.4, letterSpacing: 0.05, lineSpacing: 0.1, rotation: -12.5,
                      color: .lime, gradientColor: .pink, usesGradient: true, width: 0.9,
                      horizontalScale: 0.8),
            TextLayer(text: "DRIVER", font: .narrow, fontFamily: .kawit, size: 0.5, x: 0.25, y: 0.75,
                      isBold: true, color: SignColor(red: 1, green: 0, blue: 0), gradientColor: .lime)
        ], background: .blackDriver)
    }

    // MARK: Round trip

    func testRoundTripPreservesLayout() throws {
        let original = sampleSign()
        let data = try PlacardTemplate(sign: original, name: "Test").encoded()
        let restored = try PlacardTemplate.decode(data).makeSign()

        XCTAssertEqual(restored.background, .blackDriver)
        XCTAssertEqual(restored.layers.count, 2)
        for (a, b) in zip(original.layers, restored.layers) {
            XCTAssertEqual(a.text, b.text)
            XCTAssertEqual(a.font, b.font)
            XCTAssertEqual(a.resolvedFontFamily, b.resolvedFontFamily)
            XCTAssertEqual(a.isBold, b.isBold)
            XCTAssertEqual(a.size, b.size, accuracy: 0.0001)
            XCTAssertEqual(a.x, b.x, accuracy: 0.0001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.0001)
            XCTAssertEqual(a.rotation, b.rotation, accuracy: 0.001)
            XCTAssertEqual(a.curve, b.curve, accuracy: 0.001)
            XCTAssertEqual(a.letterSpacing, b.letterSpacing, accuracy: 0.001)
            XCTAssertEqual(a.lineSpacing, b.lineSpacing, accuracy: 0.001)
            XCTAssertEqual(a.usesGradient, b.usesGradient)
            XCTAssertEqual(a.resolvedHorizontalScale, b.resolvedHorizontalScale, accuracy: 0.001)
            XCTAssertEqual(a.width ?? -1, b.width ?? -1, accuracy: 0.0001)
        }
    }

    func testExportUsesArtboardPixels() throws {
        let template = PlacardTemplate(sign: sampleSign(), name: "Test")
        XCTAssertEqual(template.artboard.width, 576)
        XCTAssertEqual(template.artboard.height, 288)
        // size 1.16 is 116 artboard pixels; x 0.5 is the horizontal centre.
        XCTAssertEqual(template.layers[0].fontSize, 116, accuracy: 0.001)
        XCTAssertEqual(template.layers[0].center.x, 288, accuracy: 0.001)
    }

    func testLargerArtboardScalesToSameLayout() throws {
        let json = """
        {"format":"\(PlacardTemplate.formatIdentifier)","version":1,"name":"Big",
         "artboard":{"width":1152,"height":576},"background":"black",
         "layers":[{"text":"HI","fontSize":232,"center":{"x":576,"y":144},"color":"#FFFFFF"}]}
        """
        let sign = try PlacardTemplate.decode(Data(json.utf8)).makeSign()
        XCTAssertEqual(sign.layers[0].size, 1.16, accuracy: 0.0001)
        XCTAssertEqual(sign.layers[0].x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(sign.layers[0].y, 0.25, accuracy: 0.0001)
    }

    func testMinimalLayerUsesDefaults() throws {
        let json = """
        {"format":"\(PlacardTemplate.formatIdentifier)","version":1,"name":"Min",
         "artboard":{"width":576,"height":288},"background":"nonexistent",
         "layers":[{"text":"HI","fontSize":50,"center":{"x":10,"y":10},"color":"#112233"}]}
        """
        let sign = try PlacardTemplate.decode(Data(json.utf8)).makeSign()
        XCTAssertEqual(sign.background, .black, "Unknown backgrounds fall back to black")
        XCTAssertEqual(sign.layers[0].rotation, 0)
        XCTAssertEqual(sign.layers[0].curve, 0)
        XCTAssertFalse(sign.layers[0].usesGradient)
    }

    // MARK: Rejection

    func testRejectsNonTemplates() {
        XCTAssertThrowsError(try PlacardTemplate.decode(Data("{}".utf8))) {
            XCTAssertEqual($0 as? PlacardTemplate.TemplateError, .notATemplate)
        }
        XCTAssertThrowsError(try PlacardTemplate.decode(Data("not json".utf8))) {
            XCTAssertEqual($0 as? PlacardTemplate.TemplateError, .notATemplate)
        }
    }

    func testRejectsNewerVersion() {
        let json = #"{"format":"\#(PlacardTemplate.formatIdentifier)","version":99}"#
        XCTAssertThrowsError(try PlacardTemplate.decode(Data(json.utf8))) {
            XCTAssertEqual($0 as? PlacardTemplate.TemplateError, .newerVersion(99))
        }
    }

    func testRejectsInvalidValues() {
        let cases = [
            ##""artboard":{"width":0,"height":288},"layers":[{"text":"A","fontSize":10,"center":{"x":1,"y":1},"color":"#FFFFFF"}]"##,
            ##""artboard":{"width":576,"height":288},"layers":[]"##,
            ##""artboard":{"width":576,"height":288},"layers":[{"text":"A","fontSize":-5,"center":{"x":1,"y":1},"color":"#FFFFFF"}]"##,
            ##""artboard":{"width":576,"height":288},"layers":[{"text":"A","fontSize":10,"center":{"x":1,"y":1},"color":"red"}]"##,
            ##""artboard":{"width":576,"height":288},"layers":[{"fontSize":10,"center":{"x":1,"y":1},"color":"#FFFFFF"}]"##
        ]
        for body in cases {
            let json = ##"{"format":"\##(PlacardTemplate.formatIdentifier)","version":1,"name":"Bad","background":"black",\##(body)}"##
            XCTAssertThrowsError(try PlacardTemplate.decode(Data(json.utf8)), body)
        }
    }

    // MARK: Bundled templates

    func testBundledTemplatesDecode() throws {
        let url = try XCTUnwrap(Bundle(for: WidyipAppMarker.self).url(forResource: "BayadMuna", withExtension: "json")
            ?? Bundle.main.url(forResource: "BayadMuna", withExtension: "json"))
        let template = try PlacardTemplate.decode(Data(contentsOf: url))
        XCTAssertEqual(template.name, "Bayad Muna")
        XCTAssertEqual(template.layers.count, 6)
    }
}

/// Anchors `Bundle(for:)` lookups in the test bundle.
private final class WidyipAppMarker {}
