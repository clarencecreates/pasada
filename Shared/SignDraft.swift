import Foundation
import SwiftUI
import UIKit

struct SignColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    init(_ color: Color) {
        var red: CGFloat = 0; var green: CGFloat = 0; var blue: CGFloat = 0; var alpha: CGFloat = 1
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    static let lime = SignColor(red: 0.53, green: 1, blue: 0.07)
    static let pink = SignColor(red: 1, green: 0.14, blue: 0.68)
}

enum SignFontFamily: String, CaseIterable, Codable, Identifiable {
    case quiapo, cubao, kawit

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func postScriptName(for style: SignFont) -> String {
        switch (self, style) {
        case (.quiapo, _): "Quiapo_Free"
        case (.cubao, .wide): "Cubao_Free_Wide"
        case (.cubao, .regular): "Cubao_Free_Regular"
        case (.cubao, .narrow): "Cubao_Free_Narrow"
        case (.kawit, .wide): "KawitFreeExtItalic"
        case (.kawit, .regular): "KawitFreeItalic"
        case (.kawit, .narrow): "KawitFreeCndItalic"
        }
    }
}

enum SignFont: String, CaseIterable, Codable, Identifiable {
    case wide, regular, narrow
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// One font-size unit for the whole editor: Photoshop/Photopea pixels on the
/// 576px-wide placard artboard. The renderer maps it to the displayed canvas.
enum CanvasTypography {
    static let artboardWidth: CGFloat = 576

    static func pointSize(_ storedSize: Double, canvasWidth: CGFloat) -> CGFloat {
        max(8, CGFloat(storedSize * 100) * canvasWidth / artboardWidth)
    }

    /// The exact face for a layer. Measuring and drawing must both go through
    /// this, so the canvas, hit-testing and exports agree on glyph widths.
    static func uiFont(for layer: TextLayer, size: CGFloat) -> UIFont {
        guard let face = UIFont(name: layer.resolvedFontFamily.postScriptName(for: layer.font), size: size) else {
            return .systemFont(ofSize: size, weight: layer.isBold ? .black : .regular)
        }
        guard layer.isBold, let bold = face.fontDescriptor.withSymbolicTraits(.traitBold) else { return face }
        return UIFont(descriptor: bold, size: size)
    }

    /// SwiftUI font pinned to that face. Never follow it with `.fontWeight`:
    /// SwiftUI then re-resolves by family and weight and can silently swap a
    /// variant such as Cubao Wide for Cubao Regular.
    static func font(for layer: TextLayer, size: CGFloat) -> Font {
        Font(uiFont(for: layer, size: size) as CTFont)
    }
}

enum PlacardBackground: String, Codable, Equatable {
    case black
    case yellowArch
    case babyaLang
    case blackDriver
    case whiteBarya
    case yellowBayad
}

struct TextLayer: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var font: SignFont
    var fontFamily: SignFontFamily? = .cubao
    var size: Double
    var x: Double
    var y: Double
    var isBold = false
    var curve: Double = 0
    // Relative-to-font-size spacing keeps the result proportional as the user
    // changes the type size. Zero preserves existing placards exactly.
    var letterSpacing: Double = 0
    var lineSpacing: Double = 0
    var rotation: Double = 0
    var color: SignColor
    var gradientColor: SignColor
    var usesGradient = false
    // Optional keeps text created by earlier builds at its intrinsic width.
    var width: Double? = nil
    // A compound phrase can preserve an art-directed per-letter arrangement while
    // still behaving as one editable canvas object.
    var glyphOffsets: [GlyphOffset]? = nil
    // Horizontal stretch of the lettering (1 = none), applied after layout like
    // Photoshop's horizontal scale. Optional so older placards decode unchanged.
    var horizontalScale: Double? = nil
    // Imported Photoshop type uses its own artboard frame. Keeping that geometry
    // separate means templates do not get reflowed by the editor's normal text box.
    var psdLayout: PSDTextLayout? = nil
    // A full-artboard transparent export for untouched PSD type. It is cleared
    // for this layer alone as soon as the user makes an edit.
    var psdRasterAsset: String? = nil

    var resolvedFontFamily: SignFontFamily { fontFamily ?? .cubao }
    var resolvedHorizontalScale: Double { horizontalScale ?? 1 }
}

/// A normalized frame from a 576 by 288 Photoshop artboard. It is intentionally
/// optional so placards created before PSD templates continue decoding unchanged.
struct PSDTextLayout: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var horizontalScale: Double = 1
    // Captured just before the original raster layer is replaced. These values
    // retain Photoshop's visible scale as the editable layer takes over.
    var referenceText: String? = nil
    var referenceSize: Double = 0
}

/// A photo or cutout placed on the placard. Geometry is normalized to the
/// artboard like text: the centre as fractions of width/height, the width as a
/// fraction of artboard width, and height derived from the image's aspect ratio.
struct ImageLayer: Codable, Identifiable, Equatable {
    var id = UUID()
    /// File name in `PlacardImageStore`.
    var assetID: String
    var x: Double = 0.5
    var y: Double = 0.5
    var width: Double
    /// Image height divided by width.
    var aspectRatio: Double
    var rotation: Double = 0
}

struct GlyphOffset: Codable, Equatable {
    var x: Double
    var y: Double
    var rotation: Double = 0
}

struct SignDraft: Codable, Equatable {
    var layers: [TextLayer]
    // Optional keeps placards saved by earlier builds compatible.
    var background: PlacardBackground? = .black
    // An untouched imported template can use its PSD composite exactly as authored.
    // Editing any text removes this reference and leaves the live editable layers.
    var psdReferenceAsset: String? = nil
    // Tracks the migration from canvas-normalized font sizes to Photoshop point
    // sizes for the bundled imported templates.
    var psdPointSizeVersion: Int? = nil
    var showsGrid = false
    // Drawn above the background and beneath the text. Optional so placards
    // saved before image layers existed decode unchanged.
    var images: [ImageLayer]? = nil
    var snapToGrid = true
    var savedAt: Date = .now

    var imageLayers: [ImageLayer] {
        get { images ?? [] }
        set { images = newValue.isEmpty ? nil : newValue }
    }

    static let fallback = SignDraft(layers: [
        TextLayer(text: "KAYA BA", font: .wide, size: 0.31, x: 0.5, y: 0.38, color: .lime, gradientColor: .lime),
        TextLayer(text: "TODAY?", font: .narrow, size: 0.22, x: 0.5, y: 0.67, color: .pink, gradientColor: .pink)
    ])

    /// Older copies of the three bundled PSD templates were saved before their
    /// source frames were retained. Upgrade only those untouched template layouts.
    func applyingImportedPSDLayout() -> SignDraft {
        var copy = self

        let layouts: [PSDTextLayout]
        let rasterAssets: [String]
        let sourceSizes: [Double]
        switch copy.background {
        case .blackDriver:
            layouts = [
                PSDTextLayout(x: 28.0 / 576.0, y: 26.0 / 288.0, width: 521.0 / 576.0, height: 74.0 / 288.0, horizontalScale: 1.5),
                PSDTextLayout(x: 29.0 / 576.0, y: 116.0 / 288.0, width: 520.0 / 576.0, height: 51.0 / 288.0, horizontalScale: 1.45),
                PSDTextLayout(x: 27.0 / 576.0, y: 187.0 / 288.0, width: 520.0 / 576.0, height: 75.0 / 288.0, horizontalScale: 1.33)
            ]
            rasterAssets = ["BlackDriverBasta", "BlackDriverSweetLover", "BlackDriverDriver"]
            sourceSizes = [1.16, 0.78, 1.16]
        case .whiteBarya:
            layouts = [
                PSDTextLayout(x: 4.0 / 576.0, y: 57.0 / 288.0, width: 133.0 / 576.0, height: 196.0 / 288.0),
                PSDTextLayout(x: 128.0 / 576.0, y: 100.0 / 288.0, width: 314.0 / 576.0, height: 64.0 / 288.0),
                PSDTextLayout(x: 427.0 / 576.0, y: 57.0 / 288.0, width: 143.0 / 576.0, height: 197.0 / 288.0),
                PSDTextLayout(x: 144.0 / 576.0, y: 172.0 / 288.0, width: 284.0 / 576.0, height: 43.0 / 288.0)
            ]
            rasterAssets = ["WhiteBaryaB", "WhiteBaryaAryaLan", "WhiteBaryaG", "WhiteBaryaPoSaUmaga"]
            sourceSizes = [2.88, 0.92, 2.88, 0.66]
        case .yellowBayad:
            layouts = [
                PSDTextLayout(x: 6.0 / 576.0, y: 70.0 / 288.0, width: 76.0 / 576.0, height: 133.0 / 288.0),
                PSDTextLayout(x: 82.0 / 576.0, y: 42.0 / 288.0, width: 201.0 / 576.0, height: 136.0 / 288.0),
                PSDTextLayout(x: 309.0 / 576.0, y: 43.0 / 288.0, width: 193.0 / 576.0, height: 124.0 / 288.0),
                PSDTextLayout(x: 462.0 / 576.0, y: 68.0 / 288.0, width: 97.0 / 576.0, height: 124.0 / 288.0),
                PSDTextLayout(x: 124.0 / 576.0, y: 183.0 / 288.0, width: 158.0 / 576.0, height: 96.0 / 288.0),
                PSDTextLayout(x: 300.0 / 576.0, y: 184.0 / 288.0, width: 152.0 / 576.0, height: 93.0 / 288.0)
            ]
            rasterAssets = ["YellowBayadB", "YellowBayadAyad", "YellowBayadMun", "YellowBayadA", "YellowBayadBago", "YellowBayadBaba"]
            sourceSizes = [1.70, 1.17, 1.17, 1.70, 0.90, 0.90]
        default:
            return copy
        }

        guard copy.layers.count == layouts.count else { return copy }
        // A previous build may have already stored the direct PSD layout. It is
        // safe to add raster layers only if the placard is still an untouched
        // imported template (signalled by its reference asset).
        let needsLayout = copy.layers.allSatisfy { $0.psdLayout == nil }
        // The first PSD implementation stored frames without raster layer names.
        // Upgrade that all-missing state too; any newer edited placard keeps at
        // least one remaining raster layer and is therefore left alone.
        let hasAnyRaster = copy.layers.contains { $0.psdRasterAsset != nil }
        let shouldAddRasters = needsLayout || copy.psdReferenceAsset != nil || !hasAnyRaster
        // Version 2 also repairs templates saved by the first PSD editor build:
        // those drafts were marked migrated while their type was still stored as
        // a canvas fraction (for example 78 / 288) rather than 78pt / 100.
        // This is intentionally limited to the exact imported template layouts.
        let needsPointSizeMigration = (copy.psdPointSizeVersion ?? 0) < 2
        guard needsLayout || shouldAddRasters || needsPointSizeMigration else { return copy }

        for index in copy.layers.indices {
            if needsLayout {
                copy.layers[index].psdLayout = layouts[index]
            }
            if shouldAddRasters || needsPointSizeMigration {
                copy.layers[index].size = sourceSizes[index]
            }
            if needsPointSizeMigration, var layout = copy.layers[index].psdLayout {
                layout.referenceSize = sourceSizes[index]
                copy.layers[index].psdLayout = layout
            }
            if shouldAddRasters && copy.layers[index].psdRasterAsset == nil {
                copy.layers[index].psdRasterAsset = rasterAssets[index]
            }
        }
        if needsPointSizeMigration {
            copy.psdPointSizeVersion = 2
        }
        copy.psdReferenceAsset = nil
        return copy
    }
}

/// The App Group the app and widget share for the equipped placard and images.
enum AppGroup {
    static let identifier = "group.com.cyrillepardinas.widyip"
}

enum SignStore {
    private static let key = "current-sign"
    private static let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard

    static func load() -> SignDraft {
        guard let data = defaults.data(forKey: key), let sign = try? JSONDecoder().decode(SignDraft.self, from: data) else {
            return .fallback
        }
        // Same conversion as the library, so the widget never draws a PSD raster
        // while the app shows live text for the same placard.
        return sign.applyingImportedPSDLayout().bakingImportedPSDType()
    }

    static func save(_ sign: SignDraft) {
        var copy = sign
        copy.savedAt = .now
        let data: Data
        do {
            data = try JSONEncoder().encode(copy)
        } catch {
            Log.storage.fault("Equipped sign failed to encode: \(String(describing: error), privacy: .public)")
            return
        }
        defaults.set(data, forKey: key)
        // WidgetKit may reload immediately after a placard is chosen. Flush the
        // shared suite first so the extension reads this exact draft, not its cache.
        defaults.synchronize()
    }
}

struct Placard: Codable, Identifiable, Equatable {
    var id = UUID()
    var sign: SignDraft
    var createdAt: Date = .now

    var title: String { sign.layers.first?.text.isEmpty == false ? sign.layers[0].text.uppercased() : "UNTITLED" }
}

enum PlacardStore {
    static let key = "placard-library"
    /// Replaceable so tests can use an isolated suite.
    static var defaults = UserDefaults.standard

    static func load() -> [Placard] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoded: [Placard]
        do {
            decoded = try JSONDecoder().decode([Placard].self, from: data)
        } catch {
            // Never let an unreadable library look empty: the next save would
            // overwrite it. Keep the raw bytes aside so they can be recovered.
            Log.storage.fault("Placard library failed to decode: \(String(describing: error), privacy: .public)")
            defaults.set(data, forKey: key + "-unreadable-backup")
            return []
        }
        let placards = decoded
        if !placards.isEmpty {
            let upgraded = placards.map { placard in
                var copy = placard
                // PSD placards become ordinary live text once, here, so the
                // library, editor and widget all draw the same thing.
                copy.sign = placard.sign.applyingImportedPSDLayout().bakingImportedPSDType()
                return copy
            }
            if upgraded != placards {
                save(upgraded)
            }
            return upgraded
        }
        return []
    }

    static func save(_ placards: [Placard]) {
        let data: Data
        do {
            data = try JSONEncoder().encode(placards)
        } catch {
            Log.storage.fault("Placard library failed to encode: \(String(describing: error), privacy: .public)")
            return
        }
        defaults.set(data, forKey: key)
    }
}
