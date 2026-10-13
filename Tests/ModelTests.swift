import XCTest
@testable import Widyip

final class SignColorHexTests: XCTestCase {
    func testRoundTrip() {
        let color = SignColor(red: 1, green: 0.4, blue: 0.2, alpha: 0.5)
        let parsed = SignColor(hex: color.hexString)
        XCTAssertEqual(color.hexString, "#FF663380")
        XCTAssertEqual(parsed?.red ?? -1, 1, accuracy: 0.003)
        XCTAssertEqual(parsed?.green ?? -1, 0.4, accuracy: 0.003)
        XCTAssertEqual(parsed?.alpha ?? -1, 0.5, accuracy: 0.003)
    }

    func testAcceptedForms() {
        XCTAssertEqual(SignColor(hex: "#000000")?.alpha, 1)
        XCTAssertNotNil(SignColor(hex: "ff66c5"))
        XCTAssertNotNil(SignColor(hex: " #FF66C5FF "))
    }

    func testRejectsMalformed() {
        for bad in ["", "#FFF", "#GGGGGG", "red", "#1234567"] {
            XCTAssertNil(SignColor(hex: bad), bad)
        }
    }

    func testClampsOutOfRangeComponents() {
        XCTAssertEqual(SignColor(red: 2, green: -1, blue: 0.5).hexString, "#FF0080FF")
    }
}

final class PSDConversionTests: XCTestCase {
    func testBakingRemovesAllPSDArtifacts() {
        let sign = PlaceholderTemplate.blackDriver.makeSign().applyingImportedPSDLayout()
        XCTAssertTrue(sign.layers.contains { $0.psdRasterAsset != nil }, "Precondition: raw template uses rasters")

        let baked = sign.bakingImportedPSDType()
        XCTAssertNil(baked.psdReferenceAsset)
        XCTAssertNil(baked.psdPointSizeVersion)
        for layer in baked.layers {
            XCTAssertNil(layer.psdLayout)
            XCTAssertNil(layer.psdRasterAsset)
            XCTAssertNotNil(layer.width, "PSD lines get a pinned box so they don't wrap")
        }
    }

    func testBakingIsIdempotent() {
        let once = PlaceholderTemplate.whiteBarya.makeSign().applyingImportedPSDLayout().bakingImportedPSDType()
        XCTAssertEqual(once, once.bakingImportedPSDType())
    }

    func testStretchedLinesFitRecordedWidth() {
        let raw = PlaceholderTemplate.blackDriver.makeSign().applyingImportedPSDLayout()
        let baked = raw.bakingImportedPSDType()
        for (before, after) in zip(raw.layers, baked.layers) {
            guard let psd = before.psdLayout, psd.horizontalScale != 1, let width = after.width else { continue }
            XCTAssertEqual(width * after.resolvedHorizontalScale, psd.width, accuracy: 0.001)
        }
    }

    func testPlainSignsAreUntouched() {
        XCTAssertEqual(SignDraft.fallback.bakingImportedPSDType(), SignDraft.fallback)
    }
}

final class PlacardStoreTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    private var original: UserDefaults!

    override func setUp() {
        suiteName = "widyip-tests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        original = PlacardStore.defaults
        PlacardStore.defaults = suite
    }

    override func tearDown() {
        PlacardStore.defaults = original
        suite.removePersistentDomain(forName: suiteName)
    }

    func testSaveAndLoad() {
        let placards = [Placard(sign: .fallback), Placard(sign: .fallback)]
        PlacardStore.save(placards)
        XCTAssertEqual(PlacardStore.load().map(\.id), placards.map(\.id))
    }

    func testEmptyStoreLoadsEmpty() {
        XCTAssertTrue(PlacardStore.load().isEmpty)
    }

    func testCorruptLibraryIsBackedUpNotLost() {
        let garbage = Data("definitely not placards".utf8)
        suite.set(garbage, forKey: PlacardStore.key)

        XCTAssertTrue(PlacardStore.load().isEmpty)
        XCTAssertEqual(suite.data(forKey: PlacardStore.key + "-unreadable-backup"), garbage)
    }

    func testOldPSDPlacardsMigrateOnLoad() {
        let legacy = Placard(sign: PlaceholderTemplate.yellowBayad.makeSign())
        PlacardStore.save([legacy])
        let loaded = PlacardStore.load()
        XCTAssertTrue(loaded[0].sign.layers.allSatisfy { $0.psdRasterAsset == nil && $0.psdLayout == nil })
    }
}

final class CurvedTextLayoutTests: XCTestCase {
    private func layer(_ text: String, curve: Double) -> TextLayer {
        TextLayer(text: text, font: .wide, fontFamily: .cubao, size: 0.5, x: 0.5, y: 0.5,
                  curve: curve, color: .lime, gradientColor: .lime)
    }

    func testOneGlyphPerCharacter() {
        XCTAssertEqual(CurvedTextLayout(layer: layer("HELLO", curve: 0.5), fontSize: 40).glyphs.count, 5)
    }

    func testArchIsSymmetricAndCentred() {
        // Identical letters, so the arc must mirror exactly about the middle one.
        let glyphs = CurvedTextLayout(layer: layer("OOOOO", curve: 0.6), fontSize: 40).glyphs
        XCTAssertEqual(glyphs[0].center.x, -glyphs[4].center.x, accuracy: 1)
        XCTAssertEqual(glyphs[0].angle, -glyphs[4].angle, accuracy: 0.001)
        XCTAssertEqual(glyphs[2].angle, 0, accuracy: 0.001)
    }

    func testDirectionFollowsSign() {
        let up = CurvedTextLayout(layer: layer("ABCDE", curve: 0.6), fontSize: 40).glyphs
        let down = CurvedTextLayout(layer: layer("ABCDE", curve: -0.6), fontSize: 40).glyphs
        // Arching up (∩): end letters sit lower than the middle one.
        XCTAssertGreaterThan(up[0].center.y, up[2].center.y)
        XCTAssertLessThan(down[0].center.y, down[2].center.y)
    }

    func testStrongerCurveIsTaller() {
        let gentle = CurvedTextLayout(layer: layer("ABCDEFG", curve: 0.2), fontSize: 40).size
        let strong = CurvedTextLayout(layer: layer("ABCDEFG", curve: 0.9), fontSize: 40).size
        XCTAssertGreaterThan(strong.height, gentle.height)
        XCTAssertLessThan(strong.width, gentle.width)
    }

    func testEmptyTextDoesNotCrash() {
        XCTAssertTrue(CurvedTextLayout(layer: layer("", curve: 0.5), fontSize: 40).glyphs.isEmpty)
    }
}
