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

enum SignFont: String, CaseIterable, Codable, Identifiable {
    case wide, regular, narrow
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var postScriptName: String {
        switch self {
        case .wide: "Cubao_Free_Wide"
        case .regular: "Cubao_Free_Regular"
        case .narrow: "Cubao_Free_Narrow"
        }
    }
}

enum PlacardBackground: String, Codable, Equatable {
    case black
    case yellowArch
}

struct TextLayer: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var font: SignFont
    var size: Double
    var x: Double
    var y: Double
    var isBold = false
    var curve: Double = 0
    var rotation: Double = 0
    var color: SignColor
    var gradientColor: SignColor
    var usesGradient = false
}

struct SignDraft: Codable, Equatable {
    var layers: [TextLayer]
    // Optional keeps placards saved by earlier builds compatible.
    var background: PlacardBackground? = .black
    var showsGrid = false
    var snapToGrid = true
    var savedAt: Date = .now

    static let fallback = SignDraft(layers: [
        TextLayer(text: "KAYA BA", font: .wide, size: 0.31, x: 0.5, y: 0.38, color: .lime, gradientColor: .lime),
        TextLayer(text: "TODAY?", font: .narrow, size: 0.22, x: 0.5, y: 0.67, color: .pink, gradientColor: .pink)
    ])
}

enum SignStore {
    private static let key = "current-sign"
    private static let defaults = UserDefaults.standard

    static func load() -> SignDraft {
        guard let data = defaults.data(forKey: key), let sign = try? JSONDecoder().decode(SignDraft.self, from: data) else {
            return .fallback
        }
        return sign
    }

    static func save(_ sign: SignDraft) {
        var copy = sign
        copy.savedAt = .now
        guard let data = try? JSONEncoder().encode(copy) else { return }
        defaults.set(data, forKey: key)
    }
}

struct Placard: Codable, Identifiable, Equatable {
    var id = UUID()
    var sign: SignDraft
    var createdAt: Date = .now

    var title: String { sign.layers.first?.text.isEmpty == false ? sign.layers[0].text.uppercased() : "UNTITLED" }
}

enum PlacardStore {
    private static let key = "placard-library"
    private static let defaults = UserDefaults.standard

    static func load() -> [Placard] {
        if let data = defaults.data(forKey: key), let placards = try? JSONDecoder().decode([Placard].self, from: data), !placards.isEmpty {
            return placards
        }
        return [Placard(sign: SignStore.load())]
    }

    static func save(_ placards: [Placard]) {
        guard let data = try? JSONEncoder().encode(placards) else { return }
        defaults.set(data, forKey: key)
    }
}
