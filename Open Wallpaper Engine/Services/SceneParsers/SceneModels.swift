//
//  SceneModels.swift
//  Open Wallpaper Engine
//
//  Data models for Wallpaper Engine scene.json structure.
//  Decoded from scene.pkg → scene.json and referenced JSON files.
//

import Foundation

// MARK: - Top-level Scene

struct WEScene: Codable {
    var camera: WECamera
    var general: WESceneGeneral
    var objects: [WESceneObject]
    var version: Int?
}

struct WECamera: Codable {
    var center: String?
    var eye: String?
    var up: String?
}

struct WESceneGeneral: Codable {
    var clearcolor: String?
    var orthogonalprojection: WEOrthogonalProjection?
    var ambientcolor: String?
    var skylightcolor: String?

    // These fields can be Bool, Int, or an object {"user":..,"value":..} in different wallpapers.
    // We only need the String fields above for rendering, so skip strict decoding of the rest.

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Use try? because these fields can be plain strings OR {"user":..,"value":..} objects
        clearcolor = try? container.decodeIfPresent(String.self, forKey: .clearcolor)
        orthogonalprojection = try? container.decodeIfPresent(WEOrthogonalProjection.self, forKey: .orthogonalprojection)
        ambientcolor = try? container.decodeIfPresent(String.self, forKey: .ambientcolor)
        skylightcolor = try? container.decodeIfPresent(String.self, forKey: .skylightcolor)
    }

    enum CodingKeys: String, CodingKey {
        case clearcolor, orthogonalprojection, ambientcolor, skylightcolor
    }
}

struct WEOrthogonalProjection: Codable {
    var width: Int
    var height: Int
}

// MARK: - Scene Objects

/// Many WE scene fields can be either a plain value or a {"script":"..","value":..} object.
/// This wrapper decodes the plain value and silently ignores script objects.
private func decodeFlexible<T: Decodable>(_ type: T.Type, container: KeyedDecodingContainer<WESceneObject.CodingKeys>, key: WESceneObject.CodingKeys) -> T? {
    try? container.decodeIfPresent(T.self, forKey: key)
}

struct WESceneObject: Codable {
    // Common
    var id: Int?
    var name: String?
    var origin: String?
    var scale: String?
    var angles: String?
    var visible: Bool?
    var visibleValue: WEFlexibleBool?

    // Image objects
    var image: String?       // path to model JSON
    var alpha: Double?
    var brightness: Double?
    var color: String?
    var colorBlendMode: Int?
    var size: String?
    var alignment: String?
    var solid: Bool?
    var copybackground: Bool?
    var parallaxDepth: String?
    var perspective: Bool?
    var effects: [WESceneEffect]?
    var animationlayers: [WEAnimationLayer]?

    // Text objects
    var text: WETextValue?
    var font: String?
    var pointsize: Double?
    var backgroundcolor: String?
    var backgroundbrightness: Double?
    var opaquebackground: Bool?
    var padding: Double?
    var horizontalalign: String?
    var verticalalign: String?
    var anchor: String?
    var blockalign: Bool?
    var maxwidth: Double?
    var maxrows: Int?
    var limitwidth: Bool?
    var limitrows: Bool?

    // Particle objects
    var particle: String?    // path to particle JSON
    var instanceoverride: WEInstanceOverride?

    enum CodingKeys: String, CodingKey {
        case id, name, origin, scale, angles, visible
        case image, alpha, brightness, color, colorBlendMode, size, alignment
        case solid, copybackground, parallaxDepth, perspective, effects, animationlayers
        case text, font, pointsize, backgroundcolor, backgroundbrightness, opaquebackground
        case padding, horizontalalign, verticalalign, anchor, blockalign, maxwidth, maxrows
        case limitwidth, limitrows
        case particle, instanceoverride
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Fields that are always simple types
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        particle = try? c.decodeIfPresent(String.self, forKey: .particle)
        instanceoverride = try? c.decodeIfPresent(WEInstanceOverride.self, forKey: .instanceoverride)

        // Fields that may be simple values or {"script":..,"value":..} objects
        origin = try? c.decodeIfPresent(String.self, forKey: .origin)
        scale = try? c.decodeIfPresent(String.self, forKey: .scale)
        angles = try? c.decodeIfPresent(String.self, forKey: .angles)
        visible = try? c.decodeIfPresent(Bool.self, forKey: .visible)
        visibleValue = try? c.decodeIfPresent(WEFlexibleBool.self, forKey: .visible)
        alpha = try? c.decodeIfPresent(Double.self, forKey: .alpha)
        brightness = try? c.decodeIfPresent(Double.self, forKey: .brightness)
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        colorBlendMode = try? c.decodeIfPresent(Int.self, forKey: .colorBlendMode)
        size = try? c.decodeIfPresent(String.self, forKey: .size)
        alignment = try? c.decodeIfPresent(String.self, forKey: .alignment)
        solid = try? c.decodeIfPresent(Bool.self, forKey: .solid)
        copybackground = try? c.decodeIfPresent(Bool.self, forKey: .copybackground)
        parallaxDepth = try? c.decodeIfPresent(String.self, forKey: .parallaxDepth)
        perspective = try? c.decodeIfPresent(Bool.self, forKey: .perspective)
        effects = try? c.decodeIfPresent([WESceneEffect].self, forKey: .effects)
        animationlayers = try? c.decodeIfPresent([WEAnimationLayer].self, forKey: .animationlayers)
        text = try? c.decodeIfPresent(WETextValue.self, forKey: .text)
        font = try? c.decodeIfPresent(String.self, forKey: .font)
        pointsize = try? c.decodeIfPresent(Double.self, forKey: .pointsize)
        backgroundcolor = try? c.decodeIfPresent(String.self, forKey: .backgroundcolor)
        backgroundbrightness = try? c.decodeIfPresent(Double.self, forKey: .backgroundbrightness)
        opaquebackground = try? c.decodeIfPresent(Bool.self, forKey: .opaquebackground)
        padding = try? c.decodeIfPresent(Double.self, forKey: .padding)
        horizontalalign = try? c.decodeIfPresent(String.self, forKey: .horizontalalign)
        verticalalign = try? c.decodeIfPresent(String.self, forKey: .verticalalign)
        anchor = try? c.decodeIfPresent(String.self, forKey: .anchor)
        blockalign = try? c.decodeIfPresent(Bool.self, forKey: .blockalign)
        maxwidth = try? c.decodeIfPresent(Double.self, forKey: .maxwidth)
        maxrows = try? c.decodeIfPresent(Int.self, forKey: .maxrows)
        limitwidth = try? c.decodeIfPresent(Bool.self, forKey: .limitwidth)
        limitrows = try? c.decodeIfPresent(Bool.self, forKey: .limitrows)
    }

    var isVisible: Bool {
        visible ?? visibleValue?.value ?? true
    }
}

struct WEFlexibleBool: Codable {
    var user: String?
    var value: Bool?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let bool = try? container.decode(Bool.self) {
            self.user = nil
            self.value = bool
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.user = try container.decodeIfPresent(String.self, forKey: .user)
            self.value = try container.decodeIfPresent(Bool.self, forKey: .value)
        }
    }

    enum CodingKeys: String, CodingKey {
        case user, value
    }
}

struct WETextValue: Codable {
    var value: String?
    var scriptproperties: WETextScriptProperties?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let text = try? container.decode(String.self) {
            self.value = text
            self.scriptproperties = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.value = try container.decodeIfPresent(String.self, forKey: .value)
            self.scriptproperties = try container.decodeIfPresent(WETextScriptProperties.self, forKey: .scriptproperties)
        }
    }

    enum CodingKeys: String, CodingKey {
        case value, scriptproperties
    }
}

struct WETextScriptProperties: Codable {
    var delimiter: String?
    var showSeconds: WEFlexibleBool?
    var use24hFormat: WEFlexibleBool?
    var addDelimiter: String?
    var alignVertical: Bool?
    var dayFormat: String?
    var monthFormat: String?
    var showDay: Bool?
    var useDelimiter: Bool?
}

struct WESceneEffect: Codable {
    var file: String?
    var visible: WEFlexibleBool?
    var passes: [WESceneEffectPass]?
}

struct WESceneEffectPass: Codable {
    var combos: [String: Int]?
    var constantshadervalues: [String: WEEffectValue]?
    var textures: [String?]?
}

struct WEAnimationLayer: Codable {
    var id: Int?
    var name: String?
    var animation: Int?
    var additive: Bool?
    var blend: Double?
    var rate: WEScriptValue?
    var visible: WEFlexibleBool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        animation = try? c.decodeIfPresent(Int.self, forKey: .animation)
        additive = try? c.decodeIfPresent(Bool.self, forKey: .additive)
        blend = try? c.decodeIfPresent(Double.self, forKey: .blend)
        rate = try? c.decodeIfPresent(WEScriptValue.self, forKey: .rate)
        visible = try? c.decodeIfPresent(WEFlexibleBool.self, forKey: .visible)
    }

    var isVisible: Bool {
        visible?.value ?? true
    }

    enum CodingKeys: String, CodingKey {
        case id, name, animation, additive, blend, rate, visible
    }
}

enum WEEffectValue: Codable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case userNumber(user: String?, value: Double)
    case userBool(user: String?, value: Bool)

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let number = try? single.decode(Double.self) {
            self = .number(number)
            return
        }
        if let string = try? single.decode(String.self) {
            self = .string(string)
            return
        }
        if let bool = try? single.decode(Bool.self) {
            self = .bool(bool)
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        let user = try keyed.decodeIfPresent(String.self, forKey: .user)
        if let value = try? keyed.decode(Double.self, forKey: .value) {
            self = .userNumber(user: user, value: value)
            return
        }
        if let value = try? keyed.decode(Bool.self, forKey: .value) {
            self = .userBool(user: user, value: value)
            return
        }
        self = .number(0)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .userNumber(let user, let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(user, forKey: .user)
            try container.encode(value, forKey: .value)
        case .userBool(let user, let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(user, forKey: .user)
            try container.encode(value, forKey: .value)
        }
    }

    enum CodingKeys: String, CodingKey {
        case user, value
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value), .userNumber(_, let value): return value
        case .string(let value): return Double(value)
        case .bool(let value), .userBool(_, let value): return value ? 1 : 0
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value), .userNumber(_, let value): return String(value)
        case .bool(let value), .userBool(_, let value): return value ? "true" : "false"
        }
    }
}

struct WEInstanceOverride: Codable {
    var id: Int?
    var colorn: String?
    var rate: WEScriptValue?
    var size: Double?
}

struct WEScriptValue: Codable {
    var script: String?
    var value: Double?

    init(from decoder: Decoder) throws {
        // Can be just a number or an object with script+value
        if let container = try? decoder.singleValueContainer(),
           let num = try? container.decode(Double.self) {
            self.value = num
            self.script = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.script = try container.decodeIfPresent(String.self, forKey: .script)
            self.value = try container.decodeIfPresent(Double.self, forKey: .value)
        }
    }

    enum CodingKeys: String, CodingKey {
        case script, value
    }
}

// MARK: - Model / Material

struct WEModel: Codable {
    var autosize: Bool?
    var material: String?    // path to material JSON
    var puppet: String?      // path to MDLV puppet mesh
}

struct WEMaterial: Codable {
    var passes: [WEMaterialPass]?
}

struct WEMaterialPass: Codable {
    var blending: String?    // "translucent", "additive"
    var shader: String?
    var textures: [String]?
    var cullmode: String?
    var depthtest: String?
    var depthwrite: String?
}

// MARK: - Particle System

struct WEParticleSystem: Codable {
    var emitter: [WEParticleEmitter]?
    var initializer: [WEParticleInitializer]?
    var `operator`: [WEParticleOperator]?
    var renderer: [WEParticleRenderer]?
    var material: String?
    var maxcount: Int?
    var flags: Int?
    var starttime: Double?
    var animationmode: String?
    var sequencemultiplier: Double?
}

struct WEParticleEmitter: Codable {
    var id: Int?
    var name: String?
    var rate: Double?
    var origin: String?
    var directions: String?
    var distancemax: Double?
    var distancemin: Double?
    var speedmax: Double?
    var speedmin: Double?
}

struct WEParticleInitializer: Codable {
    var id: Int?
    var name: String?
    var min: WEFlexValue?
    var max: WEFlexValue?
}

/// A value that can be either a number or a string (e.g. "0 -3000 0")
enum WEFlexValue: Codable {
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let num = try? container.decode(Double.self) {
            self = .number(num)
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else {
            self = .number(0)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        }
    }

    var doubleValue: Double {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s) ?? 0
        }
    }

    var vectorValue: (Double, Double, Double) {
        switch self {
        case .number(let n): return (n, n, n)
        case .string(let s): return s.parseVector3()
        }
    }
}

struct WEParticleOperator: Codable {
    var id: Int?
    var name: String?
    var gravity: String?
    var drag: Double?
    var fadeintime: Double?
    var fadeouttime: Double?
}

struct WEParticleRenderer: Codable {
    var id: Int?
    var name: String?       // "sprite", "spritetrail"
    var length: Double?
    var maxlength: Double?
}

// MARK: - String Parsing Helpers

extension String {
    /// Parse "x y z" space-separated vector string
    func parseVector3() -> (Double, Double, Double) {
        let parts = self.split(separator: " ").compactMap { Double($0) }
        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0,
            parts.count > 2 ? parts[2] : 0
        )
    }

    /// Parse "x y" space-separated 2D vector
    func parseVector2() -> (Double, Double) {
        let parts = self.split(separator: " ").compactMap { Double($0) }
        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0
        )
    }

    /// Parse "r g b" color string (0-1 range) to NSColor
    func parseColor() -> (r: Double, g: Double, b: Double) {
        let v = self.parseVector3()
        return (r: v.0, g: v.1, b: v.2)
    }
}
