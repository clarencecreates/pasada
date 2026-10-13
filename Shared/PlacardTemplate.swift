import Foundation
import UIKit

/// A portable, app-authored placard layout. The app is the source of truth:
/// a template is whatever the editor canvas shows, written out in artboard
/// pixels on a 2:1 artboard. Nothing here is in device points, so a template
/// renders the same on every iPhone and in the widget.
///
/// `SignDraft` stays the storage model for saved placards; this type is only
/// the exchange format, so either side can evolve behind the conversion.
struct PlacardTemplate: Codable, Equatable {
    static let formatIdentifier = "com.cyrillepardinas.widyip.placard-template"
    static let currentVersion = 1

    var format: String
    var version: Int
    var name: String
    var exportedAt: Date?
    var generator: String?
    var artboard: Artboard
    /// A `PlacardBackground` raw value. Unknown values fall back to plain black.
    var background: String
    var layers: [Layer]

    struct Artboard: Codable, Equatable {
        var width: Double
        var height: Double

        static let standard = Artboard(
            width: Double(CanvasTypography.artboardWidth),
            height: Double(CanvasTypography.artboardWidth) / 2
        )
    }

    struct Point: Codable, Equatable {
        var x: Double
        var y: Double
    }

    struct Gradient: Codable, Equatable {
        var enabled: Bool
        /// The trailing colour of a leading-to-trailing gradient, `#RRGGBBAA`.
        var to: String
    }

    struct Layer: Codable, Equatable {
        var text: String
        var fontFamily: String
        var fontStyle: String
        var bold: Bool
        /// Artboard pixels.
        var fontSize: Double
        /// Centre of the text box, artboard pixels from the top-left corner.
        var center: Point
        /// Wrapping box width in artboard pixels; nil uses the renderer default.
        var width: Double?
        /// Degrees, clockwise.
        var rotation: Double
        /// Fill colour, sRGB `#RRGGBBAA`.
        var color: String
        var gradient: Gradient
        /// Fractions of the font size (em).
        var letterSpacing: Double
        var lineSpacing: Double
        var curve: Double
        /// Horizontal stretch of the lettering after layout (1 = none).
        var scaleX: Double
        /// Per-letter offsets in em, as stored by the editor.
        var glyphOffsets: [GlyphOffset]?

        // Only the essentials are required, so hand-edited or future files with
        // fewer keys still import. Every omitted styling value has a neutral default.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? SignFontFamily.cubao.rawValue
            fontStyle = try c.decodeIfPresent(String.self, forKey: .fontStyle) ?? SignFont.regular.rawValue
            bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
            fontSize = try c.decode(Double.self, forKey: .fontSize)
            center = try c.decode(Point.self, forKey: .center)
            width = try c.decodeIfPresent(Double.self, forKey: .width)
            rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
            color = try c.decode(String.self, forKey: .color)
            gradient = try c.decodeIfPresent(Gradient.self, forKey: .gradient) ?? Gradient(enabled: false, to: color)
            letterSpacing = try c.decodeIfPresent(Double.self, forKey: .letterSpacing) ?? 0
            lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 0
            curve = try c.decodeIfPresent(Double.self, forKey: .curve) ?? 0
            scaleX = try c.decodeIfPresent(Double.self, forKey: .scaleX) ?? 1
            glyphOffsets = try c.decodeIfPresent([GlyphOffset].self, forKey: .glyphOffsets)
        }

        init(layer: TextLayer, artboard: Artboard) {
            text = layer.text
            fontFamily = layer.resolvedFontFamily.rawValue
            fontStyle = layer.font.rawValue
            bold = layer.isBold
            // Rounded to a thousandth of an artboard pixel: far below anything
            // visible, and it keeps exported files clean and diffable.
            fontSize = Self.rounded(layer.size * 100 * artboard.width / Double(CanvasTypography.artboardWidth))
            center = Point(x: Self.rounded(layer.x * artboard.width), y: Self.rounded(layer.y * artboard.height))
            width = layer.width.map { Self.rounded($0 * artboard.width) }
            rotation = Self.rounded(layer.rotation)
            color = layer.color.hexString
            gradient = Gradient(enabled: layer.usesGradient, to: layer.gradientColor.hexString)
            letterSpacing = Self.rounded(layer.letterSpacing)
            lineSpacing = Self.rounded(layer.lineSpacing)
            curve = Self.rounded(layer.curve)
            scaleX = Self.rounded(layer.resolvedHorizontalScale)
            glyphOffsets = layer.glyphOffsets
        }

        private static func rounded(_ value: Double) -> Double {
            (value * 1000).rounded() / 1000
        }
    }

    enum TemplateError: LocalizedError, Equatable {
        case notATemplate
        case newerVersion(Int)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .notATemplate: "This file isn't a Widyip template."
            case .newerVersion(let version): "This template needs a newer version of Widyip (format v\(version))."
            case .invalid(let reason): "This template is damaged: \(reason)."
            }
        }
    }

    // MARK: - Conversion

    init(sign: SignDraft, name: String, exportedAt: Date = .now) {
        let artboard = Artboard.standard
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.name = name
        self.exportedAt = exportedAt
        generator = Self.generatorString
        self.artboard = artboard
        background = (sign.background ?? .black).rawValue
        layers = sign.bakingImportedPSDType().layers.map { Layer(layer: $0, artboard: artboard) }
    }

    /// Rebuilds an editable placard in the app's own units. Artboards of any
    /// size are scaled by width, so a future higher-resolution artboard still
    /// lands on the same normalized layout.
    func makeSign() -> SignDraft {
        let fontScale = Double(CanvasTypography.artboardWidth) / artboard.width
        let layers = layers.map { layer in
            let color = SignColor(hex: layer.color) ?? .lime
            return TextLayer(
                text: layer.text,
                font: SignFont(rawValue: layer.fontStyle) ?? .regular,
                fontFamily: SignFontFamily(rawValue: layer.fontFamily) ?? .cubao,
                size: layer.fontSize * fontScale / 100,
                x: layer.center.x / artboard.width,
                y: layer.center.y / artboard.height,
                isBold: layer.bold,
                curve: layer.curve,
                letterSpacing: layer.letterSpacing,
                lineSpacing: layer.lineSpacing,
                rotation: layer.rotation,
                color: color,
                gradientColor: SignColor(hex: layer.gradient.to) ?? color,
                usesGradient: layer.gradient.enabled,
                width: layer.width.map { $0 / artboard.width },
                glyphOffsets: layer.glyphOffsets,
                horizontalScale: layer.scaleX == 1 ? nil : layer.scaleX
            )
        }
        return SignDraft(layers: layers, background: PlacardBackground(rawValue: background) ?? .black)
    }

    // MARK: - Coding

    static func decode(_ data: Data) throws -> PlacardTemplate {
        // Read the envelope first so an old app gives a clear "update Widyip"
        // message instead of a generic decoding failure on a newer file.
        struct Envelope: Decodable { var format: String?; var version: Int? }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == formatIdentifier,
              let version = envelope.version else {
            throw TemplateError.notATemplate
        }
        guard version <= currentVersion else { throw TemplateError.newerVersion(version) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let template: PlacardTemplate
        do {
            template = try decoder.decode(PlacardTemplate.self, from: data)
        } catch {
            throw TemplateError.invalid("missing or malformed fields")
        }
        // Future format versions migrate here, one step at a time, before validation.
        try template.validate()
        return template
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    private func validate() throws {
        guard artboard.width.isFinite, artboard.height.isFinite, artboard.width > 0, artboard.height > 0 else {
            throw TemplateError.invalid("artboard size")
        }
        guard !layers.isEmpty, layers.count <= 64 else { throw TemplateError.invalid("layer count") }
        for layer in layers {
            let numbers = [layer.fontSize, layer.center.x, layer.center.y, layer.rotation,
                           layer.letterSpacing, layer.lineSpacing, layer.curve, layer.scaleX, layer.width ?? 1]
            guard numbers.allSatisfy(\.isFinite) else { throw TemplateError.invalid("non-numeric value") }
            guard layer.fontSize > 0, layer.scaleX > 0, (layer.width ?? 1) > 0 else { throw TemplateError.invalid("text size") }
            guard layer.text.count <= 500 else { throw TemplateError.invalid("text too long") }
            guard SignColor(hex: layer.color) != nil else { throw TemplateError.invalid("colour \(layer.color)") }
        }
    }

    private static var generatorString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Widyip iOS \(version) (\(build))"
    }
}

// MARK: - PSD retirement

extension SignDraft {
    /// Turns imported Photopea layers into ordinary editor layers, drawn by the
    /// same renderer as every other line. Afterwards what the canvas shows is
    /// exactly what is stored and exported; there is no raster stand-in that
    /// can differ from the live text.
    func bakingImportedPSDType() -> SignDraft {
        let hasPSDContent = psdReferenceAsset != nil ||
            layers.contains { $0.psdLayout != nil || $0.psdRasterAsset != nil }
        guard hasPSDContent else { return self }

        var copy = self
        copy.psdReferenceAsset = nil
        copy.psdPointSizeVersion = nil
        for index in copy.layers.indices {
            var layer = copy.layers[index]
            if let psd = layer.psdLayout {
                // PSD lines are single lines. Size the box to the text's natural
                // width so it never wraps, then fit it to the visible width
                // Photopea recorded when the PSD stretched it, or when the real
                // face is wider than that frame. Photopea's own stretch factor
                // was measured against its font metrics, so it is not reused.
                let intrinsic = Self.intrinsicWidthFraction(of: layer)
                layer.width = intrinsic
                if layer.horizontalScale == nil, intrinsic > 0,
                   psd.horizontalScale != 1 || intrinsic > psd.width {
                    layer.horizontalScale = psd.width / intrinsic
                }
            }
            layer.psdLayout = nil
            layer.psdRasterAsset = nil
            copy.layers[index] = layer
        }
        return copy
    }

    private static func intrinsicWidthFraction(of layer: TextLayer) -> Double {
        let artboardWidth = CanvasTypography.artboardWidth
        let fontSize = CanvasTypography.pointSize(layer.size, canvasWidth: artboardWidth)
        let font = CanvasTypography.uiFont(for: layer, size: fontSize)
        let width = (layer.text.uppercased() as NSString).size(withAttributes: [
            .font: font,
            .kern: fontSize * layer.letterSpacing
        ]).width
        // A couple of artboard pixels of slack stops rounding from wrapping the
        // line. Not capped at the artboard: a long line can be wider than the
        // placard and then fitted back inside by its horizontal scale.
        return Double((width + 2) / artboardWidth)
    }
}

// MARK: - Colour hex

extension SignColor {
    /// sRGB `#RRGGBBAA`.
    var hexString: String {
        func byte(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(red), byte(green), byte(blue), byte(alpha))
    }

    /// Accepts `#RRGGBB` or `#RRGGBBAA`, with or without the leading `#`.
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1
        )
    }
}

// MARK: - Bundled templates

enum TemplateCatalog {
    /// Templates exported from the app and dropped into `Resources/Templates`.
    static func bundled() -> [PlacardTemplate] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? PlacardTemplate.decode($0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
