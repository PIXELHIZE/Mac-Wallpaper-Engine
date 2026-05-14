//
//  SceneWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Loads and renders Wallpaper Engine scene wallpapers using SpriteKit.
//  Follows the same ViewModel pattern as VideoWallpaperViewModel.
//

import CoreAudio
import CoreText
import QuartzCore
import SceneKit
import SpriteKit
import SwiftUI

class SceneWallpaperViewModel: ObservableObject {
    static func log(_ msg: String) {
        let line = "[SceneVM] \(msg)"
        NSLog("%@", line)
    }

    var currentWallpaper: WEWallpaper {
        willSet {
            loadScene(from: newValue)
        }
    }

    @Published var skScene: SKScene?

    private var pkgParser: PKGParser?
    private var registeredFontNames: [String: String] = [:]
    private let puppetAnimationQueue = DispatchQueue(label: "com.winddog.wallpaper-engine.puppet-animation", qos: .utility)
    private var sceneGeneration = UUID()

    private var enablesSceneKitPuppetRenderer: Bool {
        true
    }

    init(wallpaper: WEWallpaper) {
        self.currentWallpaper = wallpaper
        Self.log("init: wallpaper=\(wallpaper.project.title ?? "?") dir=\(wallpaper.wallpaperDirectory.path)")
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification, object: nil)
        loadScene(from: wallpaper)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Scene Loading

    func loadScene(from wallpaper: WEWallpaper) {
        let generation = UUID()
        sceneGeneration = generation
        let dir = wallpaper.wallpaperDirectory
        let sceneFile = wallpaper.project.file  // e.g. "scene.json" or "gifscene.json"

        // Derive PKG name from scene file: "scene.json" → "scene.pkg", "gifscene.json" → "gifscene.pkg"
        let pkgName = (sceneFile as NSString).deletingPathExtension + ".pkg"
        let pkgURL = dir.appending(path: pkgName)
        let looseSceneURL = dir.appending(path: sceneFile)

        var scene: WEScene?

        if FileManager.default.fileExists(atPath: pkgURL.path(percentEncoded: false)) {
            do {
                let parser = try PKGParser(url: pkgURL)
                self.pkgParser = parser
                scene = try parser.extractJSON(named: sceneFile, as: WEScene.self)
            } catch {
                Self.log("Failed to parse PKG: \(error)")
            }
        } else if FileManager.default.fileExists(atPath: looseSceneURL.path(percentEncoded: false)) {
            // Loose files (no .pkg)
            self.pkgParser = nil
            do {
                let data = try Data(contentsOf: looseSceneURL)
                scene = try JSONDecoder().decode(WEScene.self, from: data)
            } catch {
                Self.log("Failed to parse loose \(sceneFile): \(error)")
            }
        }

        guard let scene = scene else {
            print("[SceneVM] No scene data found")
            NSLog("[SceneVM] No scene data found")
            return
        }

        Self.log("Scene loaded: \(scene.objects.count) objects from \(sceneFile)")
        let skScene = buildSKScene(from: scene, wallpaperDir: dir, generation: generation)
        Self.log("SKScene built: \(skScene.children.count) children")
        DispatchQueue.main.async {
            guard self.sceneGeneration == generation else { return }
            self.skScene = skScene
        }
    }

    // MARK: - SpriteKit Scene Building

    private func buildSKScene(from scene: WEScene, wallpaperDir: URL, generation: UUID) -> SKScene {
        let projection = scene.general.orthogonalprojection ?? WEOrthogonalProjection(width: 1920, height: 1080)
        let skScene = SKScene(size: CGSize(width: projection.width, height: projection.height))
        skScene.scaleMode = .aspectFill

        // Background color from clearcolor
        if let colorStr = scene.general.clearcolor {
            let c = colorStr.parseColor()
            skScene.backgroundColor = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1.0)
        }

        // Show base image layers, text layers, and the subset of effects we can emulate.
        var hasImage = false
        for (index, obj) in scene.objects.enumerated() {
            guard obj.isVisible else { continue }
            if obj.image != nil, let built = buildImageNode(obj, wallpaperDir: wallpaperDir, generation: generation) {
                if built.blendMode == .add { continue }
                built.node.zPosition = CGFloat(index)
                skScene.addChild(built.node)
                hasImage = true
            } else if obj.text != nil, let node = buildTextNode(obj, wallpaperDir: wallpaperDir) {
                node.zPosition = CGFloat(index)
                skScene.addChild(node)
            }
        }

        // Fallback: use preview image
        if !hasImage {
            let previewImage = loadPreviewImage(wallpaperDir: wallpaperDir)
            if let img = previewImage {
                let node = SKSpriteNode(texture: SKTexture(image: img))
                node.size = skScene.size
                node.position = CGPoint(x: skScene.size.width / 2, y: skScene.size.height / 2)
                skScene.addChild(node)
            }
        }

        return skScene
    }

    private func loadPreviewImage(wallpaperDir: URL) -> NSImage? {
        for name in ["preview.jpg", "preview.png", "preview.gif"] {
            let url = wallpaperDir.appending(path: name)
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    // MARK: - Image Objects

    private struct BuiltImageNode {
        let node: SKNode
        let blendMode: SKBlendMode
    }

    private func buildImageNode(_ obj: WESceneObject, wallpaperDir: URL, generation: UUID) -> BuiltImageNode? {
        guard let imagePath = obj.image else { return nil }

        // Load model JSON → material JSON → texture
        let model: WEModel? = loadJSON(path: imagePath, wallpaperDir: wallpaperDir)
        Self.log("Model '\(imagePath)': material=\(model?.material ?? "nil") puppet=\(model?.puppet ?? "nil")")
        guard let materialPath = model?.material else {
            print("[SceneVM] No material for image object '\(obj.name ?? "")' (model path: \(imagePath))")
            return nil
        }

        let material: WEMaterial? = loadJSON(path: materialPath, wallpaperDir: wallpaperDir)
        guard let textureName = material?.passes?.first?.textures?.first else {
            print("[SceneVM] No texture in material '\(materialPath)' (material decoded: \(material != nil))")
            return nil
        }
        let renderEffects = sceneRenderEffects(for: obj, wallpaperDir: wallpaperDir, materialPath: materialPath)

        // Load texture: try .tex file first, then common image formats
        Self.log("Loading texture '\(textureName)' for '\(obj.name ?? "")'")
        var image = loadTexture(
            named: textureName,
            materialDir: materialPath,
            wallpaperDir: wallpaperDir,
            cropVisibleBounds: model?.puppet == nil
        )
        let materialBlendMode = blendMode(for: material)
        var pendingPuppetAnimation: (
            path: String,
            data: Data,
            texture: NSImage,
            targetSize: CGSize?,
            targetFPS: Double,
            animationRate: CGFloat,
            textureResolution: GSTextureResolutionQuality,
            cacheKey: String
        )?
        if let puppetPath = model?.puppet,
           let texture = image,
           let puppetData = loadData(path: puppetPath, wallpaperDir: wallpaperDir) {
            Self.log("Puppet mesh found: '\(puppetPath)' bytes=\(puppetData.count)")
            let targetSize: CGSize?
            if let sizeStr = obj.size {
                let (w, h) = sizeStr.parseVector2()
                targetSize = CGSize(width: w, height: h)
            } else {
                targetSize = nil
            }
            let settings = AppDelegate.shared.globalSettingsViewModel.settings
            let animationRate = puppetAnimationRate(for: obj)
            if enablesSceneKitPuppetRenderer {
                if let puppetNode = WEPuppetModelRenderer.makeSceneKitNode(
                    mdlData: puppetData,
                    texture: texture,
                    targetSize: targetSize,
                    effects: renderEffects,
                    targetFPS: settings.fps,
                    animationRate: animationRate,
                    textureResolution: settings.textureResolution
                ) {
                    applyCommonTransform(to: puppetNode, from: obj)
                    let displayScale = NSScreen.main?.backingScaleFactor ?? 1
                    puppetNode.xScale *= displayScale
                    puppetNode.yScale *= displayScale
                    puppetNode.alpha = CGFloat(obj.alpha ?? 1.0)
                    let audioBarSize = CGSize(
                        width: puppetNode.viewportSize.width / max(displayScale, 1),
                        height: puppetNode.viewportSize.height / max(displayScale, 1)
                    )
                    if let audioBars = buildAudioBarsNode(for: obj, layerSize: audioBarSize) {
                        puppetNode.addChild(audioBars)
                    }
                    Self.log("Puppet mesh using SceneKit geometry renderer: '\(puppetPath)' viewport=\(puppetNode.viewportSize)")
                    return BuiltImageNode(node: puppetNode, blendMode: materialBlendMode)
                }
            }

            if let puppetImage = WEPuppetModelRenderer.render(
                mdlData: puppetData,
                texture: texture,
                targetSize: targetSize,
                maxTextureDimension: WEPuppetModelRenderer.staticTextureDimension(
                    for: settings.textureResolution
                )
            ) {
                Self.log("Puppet mesh rendered: '\(puppetPath)' size=\(puppetImage.size)")
                image = puppetImage
                pendingPuppetAnimation = (
                    path: puppetPath,
                    data: puppetData,
                    texture: texture,
                    targetSize: targetSize,
                    targetFPS: settings.fps,
                    animationRate: animationRate,
                    textureResolution: settings.textureResolution,
                    cacheKey: WEPuppetModelRenderer.cacheKey(
                        wallpaperDir: wallpaperDir,
                        puppetPath: puppetPath,
                        texturePath: textureName,
                        mdlData: puppetData,
                        targetSize: targetSize,
                        targetFPS: settings.fps,
                        animationRate: animationRate,
                        textureResolution: settings.textureResolution
                    )
                )
            } else {
                Self.log("Puppet mesh render FAILED: '\(puppetPath)'")
            }
        }
        guard let image = image else {
            Self.log("FAILED to load texture '\(textureName)' from material dir '\(materialPath)'")
            return nil
        }
        Self.log("Texture loaded: \(image.size)")

        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        texture.usesMipmaps = true
        let node = SKSpriteNode(texture: texture)

        // Size from object, or use pixel dimensions (not point size, which is halved on Retina)
        if let sizeStr = obj.size {
            let (w, h) = sizeStr.parseVector2()
            node.size = CGSize(width: w, height: h)
        } else {
            let pixelW = image.representations.first?.pixelsWide ?? Int(image.size.width)
            let pixelH = image.representations.first?.pixelsHigh ?? Int(image.size.height)
            node.size = CGSize(width: pixelW, height: pixelH)
        }

        // Position: WE uses top-left origin with Y-down, SpriteKit uses bottom-left with Y-up
        if let originStr = obj.origin {
            let (x, y, _) = originStr.parseVector3()
            node.position = CGPoint(x: x, y: y)
        }

        if let scaleStr = obj.scale {
            let (sx, sy, _) = scaleStr.parseVector3()
            node.xScale = CGFloat(sx)
            node.yScale = CGFloat(sy)
        }

        if let anglesStr = obj.angles {
            let (_, _, z) = anglesStr.parseVector3()
            node.zRotation = CGFloat(z)
        }

        // Alpha
        node.alpha = CGFloat(obj.alpha ?? 1.0)

        // Color tint
        if let colorStr = obj.color {
            let c = colorStr.parseColor()
            node.color = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1.0)
            node.colorBlendFactor = (obj.colorBlendMode ?? 0) > 0 ? 1.0 : 0.0
        }

        node.blendMode = materialBlendMode
        applySpriteEffects(to: node, from: obj)

        if let pendingPuppetAnimation {
            schedulePuppetAnimation(
                pendingPuppetAnimation,
                on: node,
                generation: generation
            )
        }

        if let audioBars = buildAudioBarsNode(for: obj, layerSize: node.size) {
            node.addChild(audioBars)
        }

        return BuiltImageNode(node: node, blendMode: node.blendMode)
    }

    private func blendMode(for material: WEMaterial?) -> SKBlendMode {
        switch material?.passes?.first?.blending {
        case "additive": return .add
        case "translucent": return .alpha
        default: return .alpha
        }
    }

    private func puppetAnimationRate(for obj: WESceneObject) -> CGFloat {
        guard let layer = obj.animationlayers?.first(where: { $0.isVisible }),
              let value = layer.rate?.value,
              value.isFinite,
              value > 0 else {
            return 1
        }
        return CGFloat(value)
    }

    private func schedulePuppetAnimation(
        _ pending: (
            path: String,
            data: Data,
            texture: NSImage,
            targetSize: CGSize?,
            targetFPS: Double,
            animationRate: CGFloat,
            textureResolution: GSTextureResolutionQuality,
            cacheKey: String
        ),
        on node: SKSpriteNode,
        generation: UUID
    ) {
        let fullCacheKey = pending.cacheKey + "|full"
        if let cached = WEPuppetAnimationCache.shared.animation(for: fullCacheKey) {
            applyPuppetAnimation(cached, to: node, generation: generation, phase: "cache")
            return
        }

        puppetAnimationQueue.async { [weak self, weak node] in
            guard let self else { return }

            if let cached = WEPuppetAnimationCache.shared.animation(for: fullCacheKey) {
                self.applyPuppetAnimation(cached, to: node, generation: generation, phase: "cache")
                return
            }

            let fullOptions = WEPuppetModelRenderer.fullRenderOptions(
                targetFPS: pending.targetFPS,
                textureResolution: pending.textureResolution
            )
            guard let fullAnimation = WEPuppetModelRenderer.renderAnimation(
                mdlData: pending.data,
                texture: pending.texture,
                targetSize: pending.targetSize,
                targetFPS: pending.targetFPS,
                animationRate: pending.animationRate,
                options: fullOptions
            ) else {
                Self.log("Puppet full animation skipped: '\(pending.path)'")
                return
            }

            WEPuppetAnimationCache.shared.store(fullAnimation, for: fullCacheKey)
            self.applyPuppetAnimation(fullAnimation, to: node, generation: generation, phase: "full")
        }
    }

    private func applyPuppetAnimation(
        _ animation: WEPuppetRenderedAnimation,
        to node: SKSpriteNode?,
        generation: UUID,
        phase: String
    ) {
        DispatchQueue.main.async { [weak self, weak node] in
            guard let self,
                  self.sceneGeneration == generation,
                  let node,
                  node.parent != nil,
                  animation.textures.count > 1 else {
                return
            }

            let textures = animation.textures
            SKTexture.preload(textures) { [weak self, weak node] in
                DispatchQueue.main.async { [weak self, weak node] in
                    guard let self,
                          self.sceneGeneration == generation,
                          let node,
                          node.parent != nil else {
                        return
                    }

                    let action = SKAction.animate(
                        with: textures,
                        timePerFrame: animation.timePerFrame,
                        resize: false,
                        restore: false
                    )
                    node.texture = textures.first
                    node.removeAction(forKey: "we-puppet-animation")
                    node.run(.repeatForever(action), withKey: "we-puppet-animation")
                    Self.log("Puppet animation applied (\(phase)): frames=\(animation.textures.count) timePerFrame=\(animation.timePerFrame) cost=\(animation.estimatedByteCost)")
                }
            }
        }
    }

    // MARK: - Text Objects

    private func buildTextNode(_ obj: WESceneObject, wallpaperDir: URL) -> SKNode? {
        guard obj.text != nil else { return nil }

        let label = WEDynamicTextNode(
            kind: textKind(for: obj),
            scriptProperties: obj.text?.scriptproperties
        )
        label.text = dynamicText(for: obj)
        label.fontName = fontName(for: obj.font, wallpaperDir: wallpaperDir) ?? "Impact"
        label.fontSize = resolvedFontSize(for: obj)
        label.fontColor = color(from: obj.color, alpha: CGFloat(obj.alpha ?? 1.0))
        label.horizontalAlignmentMode = horizontalAlignment(from: obj.horizontalalign)
        label.verticalAlignmentMode = verticalAlignment(from: obj.verticalalign)
        label.numberOfLines = obj.maxrows ?? 1
        label.preferredMaxLayoutWidth = CGFloat(obj.maxwidth ?? 0)
        label.start()

        let node = SKNode()
        node.addChild(label)
        applyCommonTransform(to: node, from: obj)
        node.alpha = CGFloat(obj.alpha ?? 1.0)
        return node
    }

    private func textKind(for obj: WESceneObject) -> WEDynamicTextNode.Kind {
        switch obj.name?.lowercased() {
        case "clock": return .clock
        case "date": return .date
        default: return .literal(obj.text?.value ?? "")
        }
    }

    private func dynamicText(for obj: WESceneObject) -> String {
        switch textKind(for: obj) {
        case .clock:
            return WEDynamicTextNode.clockText(scriptProperties: obj.text?.scriptproperties)
        case .date:
            return WEDynamicTextNode.dateText(scriptProperties: obj.text?.scriptproperties)
        case .literal(let text):
            return text
        }
    }

    private func resolvedFontSize(for obj: WESceneObject) -> CGFloat {
        if let sizeStr = obj.size {
            let (_, h) = sizeStr.parseVector2()
            return max(8, CGFloat(h) * 0.65)
        }
        return max(8, CGFloat(obj.pointsize ?? 10) * 6)
    }

    private func fontName(for path: String?, wallpaperDir: URL) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if let cached = registeredFontNames[path] { return cached }
        guard let data = loadData(path: path, wallpaperDir: wallpaperDir),
              let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider),
              let postScriptName = font.postScriptName as String? else {
            return nil
        }

        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterGraphicsFont(font, &error)
        registeredFontNames[path] = postScriptName
        return postScriptName
    }

    private func horizontalAlignment(from value: String?) -> SKLabelHorizontalAlignmentMode {
        switch value?.lowercased() {
        case "left": return .left
        case "right": return .right
        default: return .center
        }
    }

    private func verticalAlignment(from value: String?) -> SKLabelVerticalAlignmentMode {
        switch value?.lowercased() {
        case "top": return .top
        case "bottom": return .bottom
        default: return .center
        }
    }

    private func color(from string: String?, alpha: CGFloat = 1) -> NSColor {
        let c = (string ?? "1 1 1").parseColor()
        return NSColor(red: c.r, green: c.g, blue: c.b, alpha: alpha)
    }

    // MARK: - Emulated Scene Effects

    private func buildAudioBarsNode(for obj: WESceneObject, layerSize: CGSize) -> WEAudioBarsNode? {
        guard let effect = obj.effects?.first(where: { ($0.file ?? "").contains("Simple_Audio_Bars") }),
              effect.visible?.value ?? true,
              let constants = effect.passes?.first?.constantshadervalues else {
            return nil
        }

        let barCount = Int(constants["Bar Count"]?.doubleValue ?? 32)
        let spacing = CGFloat(constants["Bar Spacing"]?.doubleValue ?? 0.1)
        let opacity = CGFloat(constants["ui_editor_properties_opacity"]?.doubleValue ?? 1)
        let barColor = color(from: constants["Bar Color"]?.stringValue, alpha: min(opacity, 1) * 0.55)
        let bounds = constants["Lower/Upper Bar Bounds"]?.stringValue?.parseVector2() ?? (0, 0.62)
        let targetFPS = AppDelegate.shared.globalSettingsViewModel.settings.fps
        Self.log("Audio bars effect: object='\(obj.name ?? "")' count=\(barCount) bounds=\(bounds.0),\(bounds.1) fps=\(targetFPS)")

        return WEAudioBarsNode(
            size: layerSize,
            barCount: max(1, min(barCount, 200)),
            barBounds: (CGFloat(bounds.0), CGFloat(bounds.1)),
            spacing: max(0, min(spacing, 0.95)),
            color: barColor,
            targetFPS: targetFPS
        )
    }

    private func applySpriteEffects(to node: SKSpriteNode, from obj: WESceneObject) {
        guard let scroll = scrollEffect(for: obj) else { return }
        node.shader = WESpriteEffectShaders.scrollShader(for: scroll)
    }

    private func scrollEffect(for obj: WESceneObject) -> WEScrollEffect? {
        guard let effect = obj.effects?.first(where: { effect in
            (effect.file ?? "").contains("effects/scroll") && (effect.visible?.value ?? true)
        }),
        let constants = effect.passes?.first?.constantshadervalues else {
            return nil
        }

        let repeatVector = constants["repeat"]?.stringValue?.parseVector2() ?? (1, 1)
        return WEScrollEffect(
            speedX: CGFloat(constants["speedx"]?.doubleValue ?? 0),
            speedY: CGFloat(constants["speedy"]?.doubleValue ?? 0),
            repeatX: CGFloat(repeatVector.0),
            repeatY: CGFloat(repeatVector.1)
        )
    }

    private func sceneRenderEffects(for obj: WESceneObject, wallpaperDir: URL, materialPath: String) -> WESceneRenderEffects {
        var pulses: [WEPulseEffect] = []
        var waterWaves: [WEWaterWavesEffect] = []

        for effect in obj.effects ?? [] {
            guard effect.visible?.value ?? true,
                  let pass = effect.passes?.first,
                  let constants = pass.constantshadervalues else {
                continue
            }

            let file = effect.file ?? ""
            if file.contains("effects/pulse") {
                let bounds = constants["bounds"]?.stringValue?.parseVector2() ?? (0, 1)
                let audioBounds = constants["audiobounds"]?.stringValue?.parseVector2() ?? (0.5, 1)
                let maskTextureName = pass.textures?
                    .dropFirst(2)
                    .compactMap { $0 }
                    .first
                let maskImage = maskTextureName
                    .flatMap {
                        loadTexture(
                            named: $0,
                            materialDir: materialPath,
                            wallpaperDir: wallpaperDir,
                            cropVisibleBounds: false
                        )
                    }
                pulses.append(WEPulseEffect(
                    audioProcessing: pass.combos?["AUDIOPROCESSING"] ?? 0,
                    frequencyMin: Int(constants["frequencymin"]?.doubleValue ?? 0),
                    frequencyMax: Int(constants["frequencymax"]?.doubleValue ?? 1),
                    audioPower: CGFloat(constants["audioexponent"]?.doubleValue ?? 1),
                    audioBounds: (CGFloat(audioBounds.0), CGFloat(audioBounds.1)),
                    audioMultiply: CGFloat(constants["audioamount"]?.doubleValue ?? 1),
                    speed: CGFloat(constants["speed"]?.doubleValue ?? 3),
                    phase: CGFloat(constants["phase"]?.doubleValue ?? 0),
                    amount: CGFloat(constants["amount"]?.doubleValue ?? 1),
                    thresholds: (CGFloat(bounds.0), CGFloat(bounds.1)),
                    power: CGFloat(constants["power"]?.doubleValue ?? 1),
                    tintLow: colorTuple(from: constants["tintlow"]?.stringValue, default: (1, 1, 1)),
                    tintHigh: colorTuple(from: constants["tinthigh"]?.stringValue, default: (1, 1, 1)),
                    isMasked: maskTextureName != nil,
                    maskImage: maskImage
                ))
            } else if file.contains("effects/waterwaves") {
                let maskTextureName = pass.textures?
                    .dropFirst()
                    .compactMap { $0 }
                    .first
                let mask = maskTextureName
                    .flatMap {
                        loadTexture(
                            named: $0,
                            materialDir: materialPath,
                            wallpaperDir: wallpaperDir,
                            cropVisibleBounds: false
                        )
                    }
                    .flatMap(WETextureMask.init(image:))
                waterWaves.append(WEWaterWavesEffect(
                    direction: CGFloat(constants["direction"]?.doubleValue ?? 0),
                    speed: CGFloat(constants["speed"]?.doubleValue ?? 5),
                    scale: CGFloat(constants["scale"]?.doubleValue ?? 200),
                    exponent: CGFloat(constants["exponent"]?.doubleValue ?? 1),
                    strength: CGFloat(constants["strength"]?.doubleValue ?? 0.1),
                    isMasked: maskTextureName != nil,
                    mask: mask
                ))
            }
        }

        return WESceneRenderEffects(pulseEffects: pulses, waterWavesEffects: waterWaves)
    }

    private func colorTuple(
        from string: String?,
        default defaultColor: (CGFloat, CGFloat, CGFloat)
    ) -> (CGFloat, CGFloat, CGFloat) {
        guard let string else { return defaultColor }
        let color = string.parseColor()
        return (CGFloat(color.r), CGFloat(color.g), CGFloat(color.b))
    }

    private func applyCommonTransform(to node: SKNode, from obj: WESceneObject) {
        if let originStr = obj.origin {
            let (x, y, _) = originStr.parseVector3()
            node.position = CGPoint(x: x, y: y)
        }

        if let scaleStr = obj.scale {
            let (sx, sy, _) = scaleStr.parseVector3()
            node.xScale = CGFloat(sx)
            node.yScale = CGFloat(sy)
        }

        if let anglesStr = obj.angles {
            let (_, _, z) = anglesStr.parseVector3()
            node.zRotation = CGFloat(z)
        }
    }

    // MARK: - Particle Objects

    private func buildParticleNode(_ obj: WESceneObject, wallpaperDir: URL, sceneSize: CGSize) -> SKNode? {
        guard let particlePath = obj.particle else { return nil }

        let particleSystem: WEParticleSystem? = loadJSON(path: particlePath, wallpaperDir: wallpaperDir)
        guard let ps = particleSystem else {
            print("[SceneVM] Failed to load particle system '\(particlePath)'")
            return nil
        }

        let emitter = SKEmitterNode()

        // Particle texture from material
        if let materialPath = ps.material {
            let material: WEMaterial? = loadJSON(path: materialPath, wallpaperDir: wallpaperDir)
            if let texName = material?.passes?.first?.textures?.first {
                let texImage = loadTexture(named: texName, materialDir: materialPath, wallpaperDir: wallpaperDir)
                    ?? generateProceduralTexture(named: texName)
                if let img = texImage {
                    emitter.particleTexture = SKTexture(image: img)
                }
            }

            // Blend mode
            if let blending = material?.passes?.first?.blending {
                emitter.particleBlendMode = blending == "additive" ? .add : .alpha
            }
        }

        // Emitter properties
        if let em = ps.emitter?.first {
            emitter.particleBirthRate = CGFloat(em.rate ?? 100)

            // Apply instance override rate
            if let overrideRate = obj.instanceoverride?.rate?.value {
                emitter.particleBirthRate *= CGFloat(overrideRate)
            }

            // Emission area from distancemax (sphererandom emitter)
            if em.name == "sphererandom" {
                let dist = CGFloat(em.distancemax ?? 100)
                emitter.particlePositionRange = CGVector(dx: dist * 2, dy: dist * 2)
            }
        }

        // Initializers
        for ini in ps.initializer ?? [] {
            switch ini.name {
            case "lifetimerandom":
                let minLife = ini.min?.doubleValue ?? 1
                let maxLife = ini.max?.doubleValue ?? 1
                emitter.particleLifetime = CGFloat((minLife + maxLife) / 2)
                emitter.particleLifetimeRange = CGFloat(maxLife - minLife)

            case "sizerandom":
                let minSize = ini.min?.doubleValue ?? 1
                let maxSize = ini.max?.doubleValue ?? 1
                let avgSize = (minSize + maxSize) / 2
                // Apply instance override size
                let sizeMultiplier = obj.instanceoverride?.size ?? 1.0
                emitter.particleSize = CGSize(width: avgSize * sizeMultiplier, height: avgSize * sizeMultiplier)
                emitter.particleScaleRange = CGFloat((maxSize - minSize) / avgSize) * CGFloat(sizeMultiplier)

            case "velocityrandom":
                let minV = ini.min?.vectorValue ?? (0, 0, 0)
                let maxV = ini.max?.vectorValue ?? (0, 0, 0)
                // Use Y component for speed (primary direction in most WE particles)
                let avgSpeedY = (minV.1 + maxV.1) / 2
                let avgSpeedX = (minV.0 + maxV.0) / 2
                let speed = sqrt(avgSpeedX * avgSpeedX + avgSpeedY * avgSpeedY)
                emitter.particleSpeed = CGFloat(speed)
                emitter.particleSpeedRange = CGFloat(abs(maxV.1 - minV.1) / 2)
                // Emission angle: atan2 of velocity direction
                if speed > 0 {
                    // SpriteKit Y is up, WE Y is down for velocity
                    emitter.emissionAngle = CGFloat(atan2(-avgSpeedY, avgSpeedX))
                    emitter.emissionAngleRange = 0.1
                }

            case "alpharandom":
                let minA = ini.min?.doubleValue ?? 1
                let maxA = ini.max?.doubleValue ?? 1
                emitter.particleAlpha = CGFloat((minA + maxA) / 2)
                emitter.particleAlphaRange = CGFloat(maxA - minA)

            case "colorrandom":
                if let maxColor = ini.max?.vectorValue {
                    // Colors in WE particles are 0-255
                    emitter.particleColor = NSColor(
                        red: maxColor.0 / 255.0,
                        green: maxColor.1 / 255.0,
                        blue: maxColor.2 / 255.0,
                        alpha: 1.0)
                }

            default:
                break
            }
        }

        // Operators
        for op in ps.operator ?? [] {
            switch op.name {
            case "movement":
                if let gravityStr = op.gravity {
                    let (gx, gy, gz) = gravityStr.parseVector3()
                    // WE Z-axis maps to SpriteKit Y acceleration (WE uses Z for depth/vertical)
                    emitter.xAcceleration = CGFloat(gx)
                    // In WE, positive Z gravity pulls "forward", map to Y-down in SK
                    emitter.yAcceleration = CGFloat(-gz)
                    if gy != 0 && gz == 0 {
                        emitter.yAcceleration = CGFloat(-gy)
                    }
                }

            case "alphafade":
                // Fade in/out over lifetime
                let fadeIn = op.fadeintime ?? 0
                let fadeOut = op.fadeouttime ?? 1
                // SpriteKit particleAlphaSpeed: rate of alpha change per second
                // Approximate: particles fade in quickly and fade out over remaining lifetime
                if fadeOut < 1.0 {
                    emitter.particleAlphaSpeed = CGFloat(-1.0 / max(emitter.particleLifetime * CGFloat(1 - fadeOut), 0.1))
                }
                _ = fadeIn // Used implicitly through initial alpha ramp

            default:
                break
            }
        }

        // Renderer: spritetrail gets elongated aspect ratio
        if let renderer = ps.renderer?.first, renderer.name == "spritetrail" {
            let trailLength = CGFloat(renderer.maxlength ?? 50)
            emitter.particleSize = CGSize(width: 2, height: trailLength)
            // Align particles to movement direction
            emitter.particleRotation = emitter.emissionAngle
        }

        // Position from object origin
        if let originStr = obj.origin {
            let (x, y, _) = originStr.parseVector3()
            emitter.position = CGPoint(x: x, y: y)
        }

        // Scale from object
        if let scaleStr = obj.scale {
            let (sx, sy, _) = scaleStr.parseVector3()
            emitter.xScale = CGFloat(sx)
            emitter.yScale = CGFloat(sy)
        }

        // Max particles
        emitter.numParticlesToEmit = 0 // infinite

        return emitter
    }

    // MARK: - Asset Loading

    private func loadJSON<T: Decodable>(path: String, wallpaperDir: URL) -> T? {
        // Try PKG first
        if let parser = pkgParser, let data = parser.extractFile(named: path) {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        // Fall back to loose file
        let url = wallpaperDir.appending(path: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func loadData(path: String, wallpaperDir: URL) -> Data? {
        if let parser = pkgParser, let data = parser.extractFile(named: path) {
            return Data(data)
        }
        return try? Data(contentsOf: wallpaperDir.appending(path: path))
    }

    private func loadTexture(
        named name: String,
        materialDir: String,
        wallpaperDir: URL,
        cropVisibleBounds: Bool = true
    ) -> NSImage? {
        // Build candidate .tex paths: relative to material dir, then relative to materials/ root
        let materialDirPath = (materialDir as NSString).deletingLastPathComponent
        var texPaths = [String]()
        if !materialDirPath.isEmpty {
            texPaths.append("\(materialDirPath)/\(name).tex")
        }
        // Also try materials/{name}.tex for textures with embedded paths (e.g. "workshop/xxx/foo")
        let materialsRoot = materialDirPath.split(separator: "/").first.map(String.init) ?? "materials"
        let rootPath = "\(materialsRoot)/\(name).tex"
        if !texPaths.contains(rootPath) {
            texPaths.append(rootPath)
        }
        texPaths.append("\(name).tex")

        for texPath in texPaths {
            // Try .tex from PKG
            if let parser = pkgParser, let texData = parser.extractFile(named: texPath) {
                Self.log("  TEX from PKG '\(texPath)' size=\(texData.count)")
                let texParser = TEXParser(data: Data(texData))  // Copy to reset indices
                if let image = texParser.extractImage(cropVisibleBounds: cropVisibleBounds) {
                    return image
                }
                Self.log("  TEXParser.extractImage() returned nil for '\(texPath)'")
            }

            // Try .tex from loose file
            let texURL = wallpaperDir.appending(path: texPath)
            if let texData = try? Data(contentsOf: texURL) {
                let texParser = TEXParser(data: texData)
                if let image = texParser.extractImage(cropVisibleBounds: cropVisibleBounds) {
                    return image
                }
            }
        }

        // Try common image formats directly
        for ext in ["png", "jpg", "jpeg", "gif"] {
            let imgPath = materialDirPath.isEmpty ? "\(name).\(ext)" : "\(materialDirPath)/\(name).\(ext)"
            if let parser = pkgParser, let imgData = parser.extractFile(named: imgPath) {
                if let image = NSImage(data: imgData) { return image }
            }
            let imgURL = wallpaperDir.appending(path: imgPath)
            if let image = NSImage(contentsOf: imgURL) { return image }
        }

        Self.log("  No texture found for '\(name)'")
        return nil
    }

    /// Generate simple procedural textures for built-in particle names
    private func generateProceduralTexture(named name: String) -> NSImage? {
        let size: CGFloat = 32

        switch name {
        case "particle/drop":
            // Elongated raindrop: bright center, soft edges
            return generateRadialGradient(size: CGSize(width: 4, height: 16), color: .white)

        case _ where name.contains("halo"):
            // Soft circular glow
            return generateRadialGradient(size: CGSize(width: size, height: size), color: .white)

        default:
            // Generic soft circle
            return generateRadialGradient(size: CGSize(width: size, height: size), color: .white)
        }
    }

    private func generateRadialGradient(size: CGSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let ctx = NSGraphicsContext.current!.cgContext
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Convert to RGB color space to guarantee 4 components (r, g, b, a)
        let rgbColor = color.usingColorSpace(.deviceRGB) ?? color
        let r = rgbColor.redComponent
        let g = rgbColor.greenComponent
        let b = rgbColor.blueComponent
        let a = rgbColor.alphaComponent
        let colors = [
            CGColor(colorSpace: colorSpace, components: [r, g, b, a])!,
            CGColor(colorSpace: colorSpace, components: [r, g, b, 0])!
        ] as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])

        image.unlockFocus()
        return image
    }

    // MARK: - System Events

    @objc func systemWillSleep(_ notification: Notification) {
        print("[SceneVM] System is going to sleep")
        skScene?.isPaused = true
    }

    @objc func systemDidWake(_ notification: Notification) {
        print("[SceneVM] System woke up")
        skScene?.isPaused = AppDelegate.shared.wallpaperViewModel.effectivePlayRate == 0
    }
}

private final class WEDynamicTextNode: SKLabelNode {
    enum Kind {
        case clock
        case date
        case literal(String)
    }

    private let kind: Kind
    private let scriptProperties: WETextScriptProperties?

    init(kind: Kind, scriptProperties: WETextScriptProperties?) {
        self.kind = kind
        self.scriptProperties = scriptProperties
        super.init()
    }

    required init?(coder aDecoder: NSCoder) {
        self.kind = .literal("")
        self.scriptProperties = nil
        super.init(coder: aDecoder)
    }

    func start() {
        updateText()
        let interval: TimeInterval
        switch kind {
        case .clock:
            interval = scriptProperties?.showSeconds?.value == true ? 1 : 5
        case .date:
            interval = 60
        case .literal:
            return
        }

        run(.repeatForever(.sequence([
            .run { [weak self] in self?.updateText() },
            .wait(forDuration: interval)
        ])), withKey: "we-dynamic-text")
    }

    private func updateText() {
        switch kind {
        case .clock:
            text = Self.clockText(scriptProperties: scriptProperties)
        case .date:
            text = Self.dateText(scriptProperties: scriptProperties)
        case .literal(let value):
            text = value
        }
    }

    static func clockText(scriptProperties: WETextScriptProperties?) -> String {
        let date = Date()
        let calendar = Calendar.current
        var hour = calendar.component(.hour, from: date)
        if scriptProperties?.use24hFormat?.value == false {
            hour %= 12
            if hour == 0 { hour = 12 }
        }
        let minute = calendar.component(.minute, from: date)
        let delimiter = scriptProperties?.delimiter ?? ":"
        var value = String(format: "%02d%@%02d", hour, delimiter, minute)
        if scriptProperties?.showSeconds?.value == true {
            value += String(format: "%@%02d", delimiter, calendar.component(.second, from: date))
        }
        return value
    }

    static func dateText(scriptProperties: WETextScriptProperties?) -> String {
        let date = Date()
        let calendar = Calendar.current
        let month = calendar.component(.month, from: date)
        let dayOfMonth = calendar.component(.day, from: date)
        let year = calendar.component(.year, from: date)
        let weekday = calendar.component(.weekday, from: date) - 1

        let monthsNumeric = (1...12).map(String.init)
        let monthsShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let monthsFull = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let weekdaysShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let weekdaysFull = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

        let monthText: String
        switch scriptProperties?.monthFormat {
        case "2": monthText = monthsShort[month - 1]
        case "3": monthText = monthsFull[month - 1]
        default: monthText = monthsNumeric[month - 1]
        }

        let weekdayText = scriptProperties?.dayFormat == "1"
            ? weekdaysShort[weekday]
            : weekdaysFull[weekday]
        let delimiter = scriptProperties?.useDelimiter == true ? (scriptProperties?.addDelimiter ?? "/") : " "
        let newline = scriptProperties?.alignVertical == true ? "\n" : ""
        let datePart = "\(dayOfMonth)\(delimiter)\(monthText)\(delimiter)\(year)"
        if scriptProperties?.showDay == true {
            return "\(weekdayText)\(newline) \(datePart)"
        }
        return datePart
    }
}

private struct WEScrollEffect {
    let speedX: CGFloat
    let speedY: CGFloat
    let repeatX: CGFloat
    let repeatY: CGFloat
}

private struct WEPulseEffect {
    let audioProcessing: Int
    let frequencyMin: Int
    let frequencyMax: Int
    let audioPower: CGFloat
    let audioBounds: (min: CGFloat, max: CGFloat)
    let audioMultiply: CGFloat
    let speed: CGFloat
    let phase: CGFloat
    let amount: CGFloat
    let thresholds: (min: CGFloat, max: CGFloat)
    let power: CGFloat
    let tintLow: (r: CGFloat, g: CGFloat, b: CGFloat)
    let tintHigh: (r: CGFloat, g: CGFloat, b: CGFloat)
    let isMasked: Bool
    let maskImage: NSImage?

    var usesAudio: Bool {
        audioProcessing != 0
    }

    func value(at time: CGFloat) -> CGFloat {
        if usesAudio {
            let responseBounds = !isMasked
                ? audioBounds
                : (
                    min: max(0, audioBounds.min * 0.55),
                    max: max(audioBounds.min * 0.55 + 0.1, audioBounds.max * 0.92)
                )
            return WEAudioSpectrum.shared.audioResponse(
                resolution: 16,
                frequencyMin: frequencyMin,
                frequencyMax: frequencyMax,
                channelMode: audioProcessing,
                bounds: responseBounds,
                power: audioPower,
                amount: !isMasked ? audioMultiply : audioMultiply * 1.15
            )
        }

        let wave = sin(time * speed + (phase - 0.25) * CGFloat.pi * 2) * 0.5 + 0.5
        let stepped = smoothStep(edge0: thresholds.min, edge1: thresholds.max, x: wave) * amount
        return min(1, max(0, pow(max(0, stepped), max(0.001, power))))
    }
}

private struct WEWaterWavesEffect {
    let direction: CGFloat
    let speed: CGFloat
    let scale: CGFloat
    let exponent: CGFloat
    let strength: CGFloat
    let isMasked: Bool
    let mask: WETextureMask?

    var affectsGeometry: Bool {
        !isMasked || mask != nil
    }
}

private struct WETextureMask {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(image: NSImage) {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var pixels = Array(repeating: UInt8(0), count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let didDraw = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }

            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func sample(u: CGFloat, v: CGFloat) -> CGFloat {
        guard width > 0, height > 0 else { return 0 }
        let clampedU = min(1, max(0, u))
        let clampedV = min(1, max(0, v))
        let x = min(width - 1, max(0, Int(clampedU * CGFloat(width - 1))))
        let y = min(height - 1, max(0, Int(clampedV * CGFloat(height - 1))))
        return CGFloat(pixels[y * width + x]) / 255
    }
}

private struct WESceneRenderEffects {
    let pulseEffects: [WEPulseEffect]
    let waterWavesEffects: [WEWaterWavesEffect]

    static let empty = WESceneRenderEffects(pulseEffects: [], waterWavesEffects: [])

    var usesAudio: Bool {
        pulseEffects.contains { $0.usesAudio }
    }

    var hasTimeVaryingGeometry: Bool {
        waterWavesEffects.contains { $0.affectsGeometry }
    }

    var hasDynamicMaterial: Bool {
        !pulseEffects.isEmpty
    }
}

private struct WEPulseOverlay {
    let pulse: WEPulseEffect
    let node: SCNNode
    let material: SCNMaterial
    let geometries: [SCNGeometry]
}

private enum WESpriteEffectShaders {
    private static let scrollSource = """
    void main() {
        vec2 speed = vec2(u_scrollX, u_scrollY);
        vec2 signedSpeed = sign(speed) * pow(abs(speed), vec2(2.0));
        vec2 coord = fract((v_tex_coord + signedSpeed * u_time) * vec2(u_repeatX, u_repeatY));
        gl_FragColor = texture2D(u_texture, coord);
    }
    """

    static func scrollShader(for effect: WEScrollEffect) -> SKShader {
        let shader = SKShader(source: scrollSource)
        shader.uniforms = [
            SKUniform(name: "u_scrollX", float: Float(effect.speedX)),
            SKUniform(name: "u_scrollY", float: Float(effect.speedY)),
            SKUniform(name: "u_repeatX", float: Float(effect.repeatX)),
            SKUniform(name: "u_repeatY", float: Float(effect.repeatY))
        ]
        return shader
    }
}

private func smoothStep(edge0: CGFloat, edge1: CGFloat, x: CGFloat) -> CGFloat {
    guard edge0 != edge1 else { return x < edge0 ? 0 : 1 }
    let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

private final class WEAudioBarsNode: SKNode {
    private let size: CGSize
    private let barBounds: (min: CGFloat, max: CGFloat)
    private let bars: [SKShapeNode]
    private let barGains: [CGFloat]
    private var smoothedLevels: [CGFloat]
    private var peakLevels: [CGFloat]

    init(size: CGSize, barCount: Int, barBounds: (CGFloat, CGFloat), spacing: CGFloat, color: NSColor, targetFPS: Double) {
        let safeSize = CGSize(width: max(1, size.width), height: max(1, size.height))
        let count = max(1, barCount)
        let lowerBound = max(0, min(1, min(barBounds.0, barBounds.1)))
        let upperBound = max(lowerBound, min(1, max(barBounds.0, barBounds.1)))

        self.size = safeSize
        self.barBounds = (lowerBound, upperBound)
        self.barGains = (0..<count).map { index in
            let phase = CGFloat(index) * 1.618_033_988_75
            return 0.90 + 0.22 * (0.5 + 0.5 * sin(phase))
        }
        self.smoothedLevels = Array(repeating: 0, count: count)
        self.peakLevels = Array(repeating: 0, count: count)

        let slotWidth = safeSize.width / CGFloat(count)
        let barWidth = max(1, slotWidth * (1 - spacing))
        var createdBars: [SKShapeNode] = []
        createdBars.reserveCapacity(count)

        for index in 0..<count {
            let rect = CGRect(x: -barWidth / 2, y: -0.5, width: barWidth, height: 1)
            let bar = SKShapeNode(rect: rect, cornerRadius: 0)
            bar.fillColor = color
            bar.strokeColor = .clear
            bar.blendMode = .alpha
            bar.alpha = min(1, max(0.25, color.alphaComponent * 1.35))
            let centeredX = -safeSize.width / 2 + slotWidth * (CGFloat(index) + 0.5)
            bar.position.x = min(
                safeSize.width / 2 - barWidth / 2,
                max(-safeSize.width / 2 + barWidth / 2, centeredX)
            )
            createdBars.append(bar)
        }

        self.bars = createdBars
        super.init()
        zPosition = 0.25

        for bar in bars {
            bar.zPosition = 0
            bar.alpha = 0
            addChild(bar)
        }

        WEAudioSpectrum.shared.startMonitoringIfNeeded()
        let interval = 1 / max(10, min(targetFPS, 120))
        run(.repeatForever(.sequence([
            .run { [weak self] in self?.updateBars() },
            .wait(forDuration: interval)
        ])), withKey: "we-audio-bars")
    }

    required init?(coder aDecoder: NSCoder) {
        self.size = .zero
        self.barBounds = (0, 1)
        self.bars = []
        self.barGains = []
        self.smoothedLevels = []
        self.peakLevels = []
        super.init(coder: aDecoder)
    }

    private func updateBars() {
        let stereo = WEAudioSpectrum.shared.stereoSpectrum(count: bars.count)
        var levels = bars.indices.map { index in
            let left = max(0, min(CGFloat(stereo.left[index]), 1))
            let right = max(0, min(CGFloat(stereo.right[index]), 1))
            let position = CGFloat(index) / CGFloat(max(bars.count - 1, 1))
            let positional = left * (1 - position) + right * position
            let mono = (left + right) * 0.5
            let lowBandLift = 1 + (1 - position) * 0.30
            return max(0, min((mono * 0.62 + positional * 0.38) * lowBandLift, 1))
        }
        guard levels.count == bars.count else { return }

        if levels.count > 2 {
            var blended = levels
            for index in levels.indices {
                let previous = levels[max(0, index - 1)]
                let next = levels[min(levels.count - 1, index + 1)]
                blended[index] = previous * 0.05 + levels[index] * 0.90 + next * 0.05
            }
            levels = blended
        }

        let average = levels.reduce(CGFloat(0), +) / CGFloat(max(levels.count, 1))
        for index in levels.indices {
            let contrasted = average + (levels[index] - average) * 1.62
            levels[index] = max(0, min(contrasted * barGains[index], 1))
        }

        let bottom = -size.height / 2
        let maxHeight = size.height * barBounds.max
        let minHeight = size.height * barBounds.min
        for index in bars.indices {
            let rawLevel = pow(min(1, levels[index] * 2.05), 0.46)
            let transient = max(0, rawLevel - smoothedLevels[index])
            let level = min(1, rawLevel + transient * 0.42)
            let attackBase: CGFloat = level > smoothedLevels[index] ? 0.78 : 0.40
            let attack = max(0.18, min(0.82, attackBase + (barGains[index] - 1) * 0.28))
            smoothedLevels[index] += (level - smoothedLevels[index]) * attack
            peakLevels[index] = level > peakLevels[index]
                ? level
                : peakLevels[index] * 0.68
            let animatedLevel = min(1, max(0, smoothedLevels[index] * 0.74 + peakLevels[index] * 0.26))
            let height = minHeight + (maxHeight - minHeight) * animatedLevel
            let targetAlpha: CGFloat = animatedLevel > 0.01
                ? max(0.14, min(1, 0.18 + animatedLevel * 0.82))
                : 0
            bars[index].yScale = max(1, height)
            bars[index].position.y = bottom + height / 2
            bars[index].alpha += (targetAlpha - bars[index].alpha) * 0.30
        }
    }
}

final class WEAudioSpectrum {
    static let shared = WEAudioSpectrum()
    private static let analysisBandCount = 64
    private static let analysisWindowSize = 2048
    private static let activationHoldDuration: TimeInterval = 0.35
    private static let silenceHoldDuration: TimeInterval = 3.0
    private static let silenceThresholdDB: Float = -55
    private static let gatePollInterval: TimeInterval = 0.5

    private let stateLock = NSLock()
    private let startLock = NSLock()
    private let processingLock = NSLock()
    private let monitorQueue = DispatchQueue(label: "com.winddog.wallpaper-engine.audio-monitor", qos: .utility)
    private let audioQueue = DispatchQueue(label: "com.winddog.wallpaper-engine.audio-tap")
    private var monitorTimer: DispatchSourceTimer?
    private var wantsMonitoring = false
    private var isSuspended = false
    private var isStartingTap = false
    private var isTapRunning = false
    private var playbackCandidateSince: TimeInterval?
    private var silenceCooldownUntil: TimeInterval = 0
    private var latestLevels = Array(repeating: Float(0), count: analysisBandCount)
    private var latestLeftLevels = Array(repeating: Float(0), count: analysisBandCount)
    private var latestRightLevels = Array(repeating: Float(0), count: analysisBandCount)
    private var scratchLeftLevels = Array(repeating: Float(0), count: analysisBandCount)
    private var scratchRightLevels = Array(repeating: Float(0), count: analysisBandCount)
    private var scratchLeftSamples = Array(repeating: Float(0), count: analysisWindowSize)
    private var scratchRightSamples = Array(repeating: Float(0), count: analysisWindowSize)
    private var adaptiveLeftPeaks = Array(repeating: Float(0.0015), count: analysisBandCount)
    private var adaptiveRightPeaks = Array(repeating: Float(0.0015), count: analysisBandCount)
    private var adaptiveLeftFloors = Array(repeating: Float(0), count: analysisBandCount)
    private var adaptiveRightFloors = Array(repeating: Float(0), count: analysisBandCount)
    private var lastAudioTime: TimeInterval = 0
    private var lastLoudAudioTime: TimeInterval = 0
    private var sampleRate: Double = 48_000
    private var bytesPerSample = MemoryLayout<Float>.size
    private var channelCount = 2
    private var isInterleaved = false
    private var isFloatSample = true
    private var isSignedIntegerSample = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    deinit {
        stopMonitoring()
        if #available(macOS 14.2, *) {
            stopCoreAudioTap()
        }
    }

    func startMonitoringIfNeeded() {
        startLock.lock()
        wantsMonitoring = true
        if isSuspended || monitorTimer != nil {
            startLock.unlock()
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        monitorTimer = timer
        startLock.unlock()

        timer.schedule(
            deadline: .now(),
            repeating: Self.gatePollInterval,
            leeway: .milliseconds(150)
        )
        timer.setEventHandler { [weak self] in
            self?.pollPlaybackGate()
        }
        timer.resume()

        if #available(macOS 14.2, *) {
            monitorQueue.async { [weak self] in
                self?.requestTapStart()
            }
        }
    }

    func setSuspended(_ suspended: Bool) {
        startLock.lock()
        guard isSuspended != suspended else {
            startLock.unlock()
            return
        }
        isSuspended = suspended
        let shouldResume = !suspended && wantsMonitoring && monitorTimer == nil
        startLock.unlock()

        if suspended {
            stopMonitoring()
            if #available(macOS 14.2, *) {
                stopCoreAudioTap()
            }
            resetLevels()
        } else if shouldResume {
            startMonitoringIfNeeded()
        }
    }

    private func stopMonitoring() {
        startLock.lock()
        let timer = monitorTimer
        monitorTimer = nil
        startLock.unlock()
        timer?.cancel()
    }

    private func pollPlaybackGate() {
        guard #available(macOS 14.2, *) else {
            SceneWallpaperViewModel.log("Audio bars: Core Audio process taps require macOS 14.2 or newer")
            return
        }

        let now = CACurrentMediaTime()
        startLock.lock()
        let suspended = isSuspended
        startLock.unlock()
        guard !suspended else { return }

        let playbackIsStableCandidate = isPlaybackGateActive()
        var shouldStartTap = false

        startLock.lock()
        if now < silenceCooldownUntil {
            playbackCandidateSince = nil
            startLock.unlock()
            return
        }

        if playbackIsStableCandidate {
            if playbackCandidateSince == nil {
                playbackCandidateSince = now
            }
            let heldLongEnough = now - (playbackCandidateSince ?? now) >= Self.activationHoldDuration
            if heldLongEnough && !isTapRunning && !isStartingTap {
                isStartingTap = true
                shouldStartTap = true
            }
        } else {
            playbackCandidateSince = nil
        }
        startLock.unlock()

        if shouldStartTap {
            startCoreAudioTap()
        }
    }

    @available(macOS 14.2, *)
    private func requestTapStart() {
        startLock.lock()
        let shouldStart = !isSuspended && !isTapRunning && !isStartingTap
        if shouldStart {
            isStartingTap = true
        }
        startLock.unlock()

        if shouldStart {
            startCoreAudioTap()
        }
    }

    func spectrum(count: Int) -> [Float] {
        guard count > 0 else { return [] }

        stateLock.lock()
        let levels = latestLevels
        let isStale = CACurrentMediaTime() - lastAudioTime > 0.6
        stateLock.unlock()

        guard !isStale, !levels.isEmpty else {
            return Array(repeating: 0, count: count)
        }
        return resample(levels, to: count)
    }

    func stereoSpectrum(count: Int) -> (left: [Float], right: [Float]) {
        guard count > 0 else { return ([], []) }

        stateLock.lock()
        let left = latestLeftLevels
        let right = latestRightLevels
        let isStale = CACurrentMediaTime() - lastAudioTime > 0.6
        stateLock.unlock()

        guard !isStale, !left.isEmpty, !right.isEmpty else {
            let empty = Array(repeating: Float(0), count: count)
            return (empty, empty)
        }
        return (resample(left, to: count), resample(right, to: count))
    }

    func audioResponse(
        resolution: Int,
        frequencyMin: Int,
        frequencyMax: Int,
        channelMode: Int,
        bounds: (min: CGFloat, max: CGFloat),
        power: CGFloat,
        amount: CGFloat
    ) -> CGFloat {
        let count = max(1, resolution)
        let stereo = stereoSpectrum(count: count)
        let lower = max(0, min(frequencyMin, frequencyMax, count - 1))
        let upper = max(0, min(max(frequencyMin, frequencyMax), count - 1))
        guard lower <= upper else { return 0 }

        var total: Float = 0
        var samples = 0
        for index in lower...upper {
            switch channelMode {
            case 1:
                total += stereo.left[index]
                samples += 1
            case 2:
                total += stereo.right[index]
                samples += 1
            default:
                total += (stereo.left[index] + stereo.right[index]) * 0.5
                samples += 1
            }
        }

        let average = CGFloat(total / Float(max(samples, 1)))
        let bounded = smoothStep(edge0: bounds.min, edge1: bounds.max, x: average)
        return min(1, max(0, pow(max(0, bounded), max(0.001, power)) * amount))
    }

    private func isPlaybackGateActive() -> Bool {
        mediaProcessIsRunningOutput() || defaultOutputDeviceIsRunningSomewhere()
    }

    private func mediaProcessIsRunningOutput() -> Bool {
        for processID in readAudioObjectIDList(
            kAudioHardwarePropertyProcessObjectList,
            from: AudioObjectID(kAudioObjectSystemObject)
        ) {
            guard let bundleID = processBundleID(for: processID),
                  isKnownMediaBundleID(bundleID),
                  readUInt32Property(kAudioProcessPropertyIsRunningOutput, from: processID) != 0 else {
                continue
            }
            return true
        }
        return false
    }

    private func defaultOutputDeviceIsRunningSomewhere() -> Bool {
        let defaultDevice = readAudioObjectIDProperty(
            kAudioHardwarePropertyDefaultOutputDevice,
            from: AudioObjectID(kAudioObjectSystemObject)
        )
        guard defaultDevice != AudioObjectID(kAudioObjectUnknown) else { return false }
        return readUInt32Property(kAudioDevicePropertyDeviceIsRunningSomewhere, from: defaultDevice) != 0
    }

    private func processBundleID(for processID: AudioObjectID) -> String? {
        if let bundleID = readStringProperty(kAudioProcessPropertyBundleID, from: processID) {
            return bundleID
        }

        guard let pid = readPIDProperty(processID),
              let app = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }
        return app.bundleIdentifier
    }

    private func isKnownMediaBundleID(_ bundleID: String) -> Bool {
        let normalized = bundleID.lowercased()
        return normalized == "com.apple.music"
            || normalized == "com.spotify.client"
            || normalized.hasPrefix("com.google.chrome")
            || normalized.hasPrefix("com.apple.safari")
            || normalized.hasPrefix("com.apple.webkit")
    }

    @available(macOS 14.2, *)
    private func startCoreAudioTap() {
        startLock.lock()
        let suspended = isSuspended
        startLock.unlock()
        guard !suspended else {
            finishTapStart(running: false)
            return
        }

        resetLevels()
        stateLock.lock()
        lastLoudAudioTime = CACurrentMediaTime()
        stateLock.unlock()

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "Open Wallpaper Engine Audio Bars"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard status == noErr else {
            SceneWallpaperViewModel.log("Audio bars: failed to create process tap \(describe(status))")
            finishTapStart(running: false)
            return
        }
        tapID = newTapID

        if let format = readTapFormat(tapID) {
            configureInputFormat(format)
        }

        guard let tapUID = readStringProperty(kAudioTapPropertyUID, from: tapID) else {
            SceneWallpaperViewModel.log("Audio bars: failed to read process tap UID")
            stopCoreAudioTap()
            finishTapStart(running: false)
            return
        }

        let aggregateUID = "com.winddog.wallpaper-engine.audio-tap.\(UUID().uuidString)"
        let tapConfig: [String: Any] = [
            kAudioSubTapUIDKey as String: tapUID,
            kAudioSubTapDriftCompensationKey as String: true
        ]
        let aggregateConfig: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Open Wallpaper Engine Audio Tap",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [tapConfig],
            kAudioAggregateDeviceTapAutoStartKey as String: true
        ]

        var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateConfig as CFDictionary, &newAggregateDeviceID)
        guard status == noErr else {
            SceneWallpaperViewModel.log("Audio bars: failed to create aggregate tap device \(describe(status))")
            stopCoreAudioTap()
            finishTapStart(running: false)
            return
        }
        aggregateDeviceID = newAggregateDeviceID

        var newIOProcID: AudioDeviceIOProcID?
        let block: AudioDeviceIOBlock = { [weak self] _, inputData, _, _, _ in
            self?.processAudioBufferList(inputData)
        }
        status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, audioQueue, block)
        guard status == noErr, let newIOProcID else {
            SceneWallpaperViewModel.log("Audio bars: failed to create audio IOProc \(describe(status))")
            stopCoreAudioTap()
            finishTapStart(running: false)
            return
        }
        ioProcID = newIOProcID

        status = AudioDeviceStart(aggregateDeviceID, newIOProcID)
        guard status == noErr else {
            SceneWallpaperViewModel.log("Audio bars: failed to start aggregate tap device \(describe(status))")
            stopCoreAudioTap()
            finishTapStart(running: false)
            return
        }

        finishTapStart(running: true)
        SceneWallpaperViewModel.log("Audio bars: Core Audio process tap started sampleRate=\(sampleRate) bytesPerSample=\(bytesPerSample)")
    }

    @available(macOS 14.2, *)
    private func stopCoreAudioTap() {
        if let ioProcID, aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        startLock.lock()
        isTapRunning = false
        isStartingTap = false
        playbackCandidateSince = nil
        startLock.unlock()
        resetLevels()
    }

    private func processAudioBufferList(_ audioBufferList: UnsafePointer<AudioBufferList>) {
        processingLock.lock()
        defer { processingLock.unlock() }

        for index in 0..<Self.analysisBandCount {
            scratchLeftLevels[index] = 0
            scratchRightLevels[index] = 0
        }
        for index in 0..<Self.analysisWindowSize {
            scratchLeftSamples[index] = 0
            scratchRightSamples[index] = 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        var peak = Float(0)
        var leftSampleCount = 0
        var rightSampleCount = 0

        if isInterleaved, let buffer = buffers.first, let data = buffer.mData {
            let frames = min(
                Self.analysisWindowSize,
                Int(buffer.mDataByteSize) / max(bytesPerSample * max(channelCount, 1), 1)
            )
            for frame in 0..<frames {
                let left = sampleValue(from: data, sampleIndex: frame * channelCount)
                let right = channelCount > 1
                    ? sampleValue(from: data, sampleIndex: frame * channelCount + 1)
                    : left
                scratchLeftSamples[frame] = left
                scratchRightSamples[frame] = right
                peak = max(peak, max(abs(left), abs(right)))
            }
            leftSampleCount = frames
            rightSampleCount = frames
        } else {
            for (bufferIndex, buffer) in buffers.enumerated() where bufferIndex < 2 {
                guard let data = buffer.mData else { continue }
                let frames = min(Self.analysisWindowSize, Int(buffer.mDataByteSize) / max(bytesPerSample, 1))
                guard frames > 0 else { continue }

                for frame in 0..<frames {
                    let sample = sampleValue(from: data, sampleIndex: frame)
                    peak = max(peak, abs(sample))
                    if bufferIndex == 0 {
                        scratchLeftSamples[frame] = sample
                    } else {
                        scratchRightSamples[frame] = sample
                    }
                }

                if bufferIndex == 0 {
                    leftSampleCount = frames
                } else {
                    rightSampleCount = frames
                }
            }

            if rightSampleCount == 0, leftSampleCount > 0 {
                for index in 0..<leftSampleCount {
                    scratchRightSamples[index] = scratchLeftSamples[index]
                }
                rightSampleCount = leftSampleCount
            }
        }

        let now = CACurrentMediaTime()
        let peakDB = 20 * log10(max(peak, Float.leastNonzeroMagnitude))
        if peakDB > Self.silenceThresholdDB {
            stateLock.lock()
            lastLoudAudioTime = now
            stateLock.unlock()
        }

        analyzeFrequencyBands(
            samples: scratchLeftSamples,
            sampleCount: leftSampleCount,
            output: &scratchLeftLevels
        )
        analyzeFrequencyBands(
            samples: scratchRightSamples,
            sampleCount: rightSampleCount,
            output: &scratchRightLevels
        )

        let signalScale = Self.smoothStepFloat(edge0: Self.silenceThresholdDB, edge1: -28, x: peakDB)

        stateLock.lock()
        for index in 0..<Self.analysisBandCount {
            let leftLevel = normalizedBandLevel(
                raw: scratchLeftLevels[index],
                peak: &adaptiveLeftPeaks[index],
                floor: &adaptiveLeftFloors[index]
            ) * signalScale
            let rightLevel = normalizedBandLevel(
                raw: scratchRightLevels[index],
                peak: &adaptiveRightPeaks[index],
                floor: &adaptiveRightFloors[index]
            ) * signalScale
            latestLeftLevels[index] = smoothedLevel(previous: latestLeftLevels[index], current: leftLevel)
            latestRightLevels[index] = smoothedLevel(previous: latestRightLevels[index], current: rightLevel)
            let current = (latestLeftLevels[index] + latestRightLevels[index]) * 0.5
            let previous = latestLevels[index]
            latestLevels[index] = current > previous
                ? previous * 0.42 + current * 0.58
                : previous * 0.72 + current * 0.28
        }
        lastAudioTime = now
        stateLock.unlock()

        if peakDB <= Self.silenceThresholdDB {
            monitorQueue.async { [weak self] in
                self?.stopTapIfSilenceHeld()
            }
        }
    }

    private func analyzeFrequencyBands(
        samples: [Float],
        sampleCount: Int,
        output: inout [Float]
    ) {
        guard sampleCount >= 32 else {
            for index in output.indices { output[index] = 0 }
            return
        }

        let nyquist = max(80, Float(sampleRate * 0.5))
        let minFrequency: Float = 40
        let maxFrequency = min(16_000, nyquist * 0.92)
        let logRange = log(maxFrequency / minFrequency)

        for index in 0..<Self.analysisBandCount {
            let position = Float(index) / Float(max(Self.analysisBandCount - 1, 1))
            let frequency = minFrequency * exp(logRange * position)
            let omega = 2 * Float.pi * frequency / max(Float(sampleRate), 1)
            let coefficient = 2 * cos(omega)
            var q0 = Float(0)
            var q1 = Float(0)
            var q2 = Float(0)

            for sampleIndex in 0..<sampleCount {
                let window = 0.5 - 0.5 * cos(2 * Float.pi * Float(sampleIndex) / Float(max(sampleCount - 1, 1)))
                let sample = (samples[sampleIndex].isFinite ? samples[sampleIndex] : 0) * window
                q0 = coefficient * q1 - q2 + sample
                q2 = q1
                q1 = q0
            }

            let magnitude = sqrt(max(0, q1 * q1 + q2 * q2 - coefficient * q1 * q2)) / Float(sampleCount)
            let equalized = magnitude * (20 + pow(position, 0.85) * 24)
            output[index] = equalized.isFinite ? max(0, equalized) : 0
        }
    }

    private func sampleValue(from data: UnsafeMutableRawPointer, sampleIndex: Int) -> Float {
        if isFloatSample, bytesPerSample == MemoryLayout<Float>.size {
            let value = data.assumingMemoryBound(to: Float.self)[sampleIndex]
            return value.isFinite ? value : 0
        }
        if isSignedIntegerSample, bytesPerSample == MemoryLayout<Int16>.size {
            return Float(data.assumingMemoryBound(to: Int16.self)[sampleIndex]) / Float(Int16.max)
        }
        if isSignedIntegerSample, bytesPerSample == MemoryLayout<Int32>.size {
            return Float(data.assumingMemoryBound(to: Int32.self)[sampleIndex]) / Float(Int32.max)
        }
        return 0
    }

    private func smoothedLevel(previous: Float, current: Float) -> Float {
        current > previous
            ? previous * 0.22 + current * 0.78
            : previous * 0.64 + current * 0.36
    }

    private func normalizedBandLevel(raw: Float, peak: inout Float, floor: inout Float) -> Float {
        let value = raw.isFinite ? max(0, raw) : 0
        if value <= 0.000_001 {
            peak = max(0.0008, peak * 0.994)
            floor *= 0.995
            return 0
        }

        if value > peak {
            peak = peak * 0.58 + value * 0.42
        } else {
            peak = max(0.0008, peak * 0.992)
        }

        if value < floor {
            floor = floor * 0.94 + value * 0.06
        } else {
            floor = floor * 0.998 + min(value, peak * 0.45) * 0.002
        }

        let clippedFloor = min(floor, peak * 0.65)
        let headroomPeak = max(peak * 1.12, clippedFloor + 0.00035)
        let range = max(headroomPeak - clippedFloor, 0.00035)
        let normalized = max(0, min(1, (value - clippedFloor) / range))
        let gated = Self.smoothStepFloat(edge0: 0.015, edge1: 0.09, x: normalized)
        return min(1, pow(normalized, 0.62) * gated)
    }

    private static func smoothStepFloat(edge0: Float, edge1: Float, x: Float) -> Float {
        guard edge0 != edge1 else { return x < edge0 ? 0 : 1 }
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    private func stopTapIfSilenceHeld() {
        guard #available(macOS 14.2, *) else { return }

        stateLock.lock()
        let silentDuration = CACurrentMediaTime() - lastLoudAudioTime
        stateLock.unlock()

        guard silentDuration >= Self.silenceHoldDuration else { return }
        SceneWallpaperViewModel.log("Audio bars: stopping tap after \(String(format: "%.1f", silentDuration))s below \(Self.silenceThresholdDB)dB")
        startLock.lock()
        silenceCooldownUntil = CACurrentMediaTime() + Self.activationHoldDuration
        startLock.unlock()
        stopCoreAudioTap()
    }

    private func finishTapStart(running: Bool) {
        startLock.lock()
        isStartingTap = false
        isTapRunning = running
        if running {
            playbackCandidateSince = nil
            silenceCooldownUntil = 0
        }
        startLock.unlock()
    }

    private func resetLevels() {
        stateLock.lock()
        for index in 0..<latestLevels.count {
            latestLevels[index] = 0
            latestLeftLevels[index] = 0
            latestRightLevels[index] = 0
            adaptiveLeftPeaks[index] = 0.0015
            adaptiveRightPeaks[index] = 0.0015
            adaptiveLeftFloors[index] = 0
            adaptiveRightFloors[index] = 0
        }
        lastAudioTime = 0
        lastLoudAudioTime = CACurrentMediaTime()
        stateLock.unlock()
    }

    private func resample(_ levels: [Float], to count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard levels.count != count, levels.count > 1 else {
            return levels.count == count ? levels : Array(repeating: levels.first ?? 0, count: count)
        }

        return (0..<count).map { index in
            let sourceIndex = Double(index) * Double(levels.count - 1) / Double(max(count - 1, 1))
            let lower = Int(floor(sourceIndex))
            let upper = min(levels.count - 1, lower + 1)
            let blend = Float(sourceIndex - Double(lower))
            return levels[lower] * (1 - blend) + levels[upper] * blend
        }
    }

    private func configureInputFormat(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : sampleRate
        let declaredBytes = Int(format.mBitsPerChannel / 8)
        bytesPerSample = declaredBytes > 0 ? declaredBytes : Int(format.mBytesPerFrame)
        channelCount = max(1, Int(format.mChannelsPerFrame))
        isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 && channelCount > 1
        let flags = format.mFormatFlags
        isFloatSample = format.mFormatID == kAudioFormatLinearPCM && (flags & kAudioFormatFlagIsFloat) != 0
        isSignedIntegerSample = format.mFormatID == kAudioFormatLinearPCM && (flags & kAudioFormatFlagIsSignedInteger) != 0
        if !isFloatSample && !isSignedIntegerSample {
            bytesPerSample = MemoryLayout<Float>.size
            isFloatSample = true
        }
    }

    private func readAudioObjectIDList(
        _ selector: AudioObjectPropertySelector,
        from objectID: AudioObjectID
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var values = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        return status == noErr ? values.filter { $0 != AudioObjectID(kAudioObjectUnknown) } : []
    }

    private func readAudioObjectIDProperty(
        _ selector: AudioObjectPropertySelector,
        from objectID: AudioObjectID
    ) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var value = AudioObjectID(kAudioObjectUnknown)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : AudioObjectID(kAudioObjectUnknown)
    }

    private func readUInt32Property(
        _ selector: AudioObjectPropertySelector,
        from objectID: AudioObjectID
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }

    private func readPIDProperty(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<pid_t>.size)
        var value = pid_t(0)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func readTapFormat(_ objectID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var format = AudioStreamBasicDescription()
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &format)
        return status == noErr ? format : nil
    }

    private func readStringProperty(_ selector: AudioObjectPropertySelector, from objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private func describe(_ status: OSStatus) -> String {
        guard status != noErr else { return "noErr" }
        let bigEndian = UInt32(bitPattern: status).bigEndian
        let bytes: [UInt8] = [
            UInt8((bigEndian >> 24) & 0xff),
            UInt8((bigEndian >> 16) & 0xff),
            UInt8((bigEndian >> 8) & 0xff),
            UInt8(bigEndian & 0xff)
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }),
           let text = String(bytes: bytes, encoding: .macOSRoman) {
            return "'\(text)' (\(status))"
        }
        return "\(status)"
    }
}

private struct WEPuppetVertex {
    let x: CGFloat
    let y: CGFloat
    let u: CGFloat
    let v: CGFloat
    let boneIndices: [Int]
    let boneWeights: [CGFloat]
}

private struct WEPuppetBone {
    let parentIndex: Int?
    let bindTransform: CGAffineTransform
}

private struct WEPuppetRenderedAnimation {
    let textures: [SKTexture]
    let timePerFrame: TimeInterval
    let duration: TimeInterval
    let estimatedByteCost: Int
}

private struct WEPuppetAnimationData {
    let name: String
    let loopMode: String
    let fps: CGFloat
    let duration: CGFloat
    let frames: [[CGAffineTransform]]
}

private struct WEPuppetAnimationRenderOptions {
    let maxTextureDimension: CGFloat
    let maxFrameCount: Int
    let memoryBudget: Int
    let label: String
}

private struct WEPuppetPreparedModel {
    let cgImage: CGImage
    let textureSize: CGSize
    let mesh: (vertices: [WEPuppetVertex], indices: [UInt16])
    let bones: [WEPuppetBone]
}

private final class WEPuppetRenderedAnimationBox {
    let animation: WEPuppetRenderedAnimation

    init(_ animation: WEPuppetRenderedAnimation) {
        self.animation = animation
    }
}

private final class WEPuppetAnimationCache {
    static let shared = WEPuppetAnimationCache()

    private let cache = NSCache<NSString, WEPuppetRenderedAnimationBox>()

    private init() {
        cache.countLimit = 2
        cache.totalCostLimit = 360 * 1024 * 1024
    }

    func animation(for key: String) -> WEPuppetRenderedAnimation? {
        cache.object(forKey: key as NSString)?.animation
    }

    func store(_ animation: WEPuppetRenderedAnimation, for key: String) {
        cache.setObject(
            WEPuppetRenderedAnimationBox(animation),
            forKey: key as NSString,
            cost: animation.estimatedByteCost
        )
    }
}

/// Minimal renderer for Wallpaper Engine MDLV puppet meshes.
///
/// Some scene wallpapers store character parts in a texture atlas and rely on
/// the MDL mesh to cut those parts out. Rendering the atlas as one rectangle
/// shows eyes, hair, and body fragments in the wrong places, so we rasterize
/// the triangle mesh through SceneKit when available. This keeps one source
/// texture on the GPU and swaps compact frame geometries instead of uploading
/// large pre-rendered textures for every animation frame. The older CPU
/// rasterizer remains as a fallback for SceneKit failures.
private enum WEPuppetModelRenderer {
    private static let vertexStride = 52
    private static let maxPreRenderedAnimationFrames = 60

    static func staticTextureDimension(for quality: GSTextureResolutionQuality) -> CGFloat {
        switch quality {
        case .highQuality: return 2048
        case .highPerformance: return 1536
        case .automatic: return 1920
        }
    }

    static func fullRenderOptions(
        targetFPS: Double,
        textureResolution: GSTextureResolutionQuality
    ) -> WEPuppetAnimationRenderOptions {
        let fps = max(10, min(targetFPS, 120))
        let qualityFrameLimit: Int
        let memoryBudget: Int
        let maxDimension: CGFloat
        switch textureResolution {
        case .highQuality:
            qualityFrameLimit = maxPreRenderedAnimationFrames
            memoryBudget = 320 * 1024 * 1024
            maxDimension = 2048
        case .highPerformance:
            qualityFrameLimit = 50
            memoryBudget = 220 * 1024 * 1024
            maxDimension = 1536
        case .automatic:
            qualityFrameLimit = 60
            memoryBudget = 280 * 1024 * 1024
            maxDimension = 1920
        }

        return WEPuppetAnimationRenderOptions(
            maxTextureDimension: maxDimension,
            maxFrameCount: min(qualityFrameLimit, max(12, Int(ceil(fps * 2.4)))),
            memoryBudget: memoryBudget,
            label: "full"
        )
    }

    static func cacheKey(
        wallpaperDir: URL,
        puppetPath: String,
        texturePath: String,
        mdlData: Data,
        targetSize: CGSize?,
        targetFPS: Double,
        animationRate: CGFloat,
        textureResolution: GSTextureResolutionQuality
    ) -> String {
        let fpsBucket = Int(round(max(1, min(targetFPS, 120))))
        let rateBucket = Int(round(validPlaybackRate(animationRate) * 1_000))
        let targetSizeKey: String
        if let targetSize {
            targetSizeKey = "\(Int(round(targetSize.width)))x\(Int(round(targetSize.height)))"
        } else {
            targetSizeKey = "auto"
        }

        return [
            "v10",
            wallpaperDir.path(percentEncoded: false),
            puppetPath,
            texturePath,
            stableHash(mdlData),
            targetSizeKey,
            "fps\(fpsBucket)",
            "rate\(rateBucket)",
            textureResolution.rawValue
        ].joined(separator: "|")
    }

    static func makeSceneKitNode(
        mdlData: Data,
        texture: NSImage,
        targetSize: CGSize?,
        effects: WESceneRenderEffects = .empty,
        targetFPS: Double,
        animationRate: CGFloat = 1,
        textureResolution: GSTextureResolutionQuality
    ) -> SK3DNode? {
        let mdlData = Data(mdlData)
        guard let prepared = prepareModel(mdlData: mdlData, texture: texture),
              let textureImage = sceneKitTextureImage(from: texture, quality: textureResolution) else {
            return nil
        }

        let animation = parseAnimation(in: mdlData, boneCount: prepared.bones.count)
        let sourcePoses = animation?.frames ?? [parseFirstAnimationPose(in: mdlData, boneCount: prepared.bones.count)]
        guard !sourcePoses.isEmpty else { return nil }

        if effects.usesAudio {
            WEAudioSpectrum.shared.startMonitoringIfNeeded()
        }

        let playbackRate = validPlaybackRate(animationRate)
        let frameSamples: [(poseTransforms: [CGAffineTransform], time: CGFloat)]
        if let animation {
            frameSamples = sampledAnimationPoses(
                animation: animation,
                playbackRate: playbackRate,
                targetFPS: targetFPS
            )
        } else {
            frameSamples = [(poseTransforms: sourcePoses[0], time: 0)]
        }

        let material = sceneKitMaterial(texture: textureImage)
        let indexData = sceneKitIndexData(prepared.mesh.indices)
        let dynamicWaterWaves = effects.hasTimeVaryingGeometry
        let staticTexcoordData = sceneKitTexcoordData(
            prepared.mesh.vertices,
            waterWaves: [],
            time: 0
        )
        let vertexSources: [SCNGeometrySource]
        let geometries: [SCNGeometry]
        if dynamicWaterWaves {
            vertexSources = frameSamples.compactMap {
                sceneKitVertexSource(prepared: prepared, poseTransforms: $0.poseTransforms)
            }
            guard let firstVertexSource = vertexSources.first else { return nil }
            let firstTexcoordData = sceneKitTexcoordData(
                prepared.mesh.vertices,
                waterWaves: effects.waterWavesEffects,
                time: 0
            )
            geometries = [
                sceneKitGeometry(
                    vertexSource: firstVertexSource,
                    vertexCount: prepared.mesh.vertices.count,
                    indexCount: prepared.mesh.indices.count,
                    material: material,
                    indexData: indexData,
                    texcoordData: firstTexcoordData
                )
            ]
        } else {
            vertexSources = []
            geometries = frameSamples.compactMap { sample in
                sceneKitGeometry(
                    prepared: prepared,
                    poseTransforms: sample.poseTransforms,
                    material: material,
                    indexData: indexData,
                    texcoordData: staticTexcoordData
                )
            }
        }
        guard let firstGeometry = geometries.first else { return nil }

        func dynamicGeometry(frameIndex: Int, elapsedTime: CGFloat) -> SCNGeometry? {
            guard dynamicWaterWaves, frameIndex >= 0, frameIndex < vertexSources.count else { return nil }
            let texcoordData = sceneKitTexcoordData(
                prepared.mesh.vertices,
                waterWaves: effects.waterWavesEffects,
                time: elapsedTime
            )
            return sceneKitGeometry(
                vertexSource: vertexSources[frameIndex],
                vertexCount: prepared.mesh.vertices.count,
                indexCount: prepared.mesh.indices.count,
                material: material,
                indexData: indexData,
                texcoordData: texcoordData
            )
        }

        let displaySize: CGSize
        if let targetSize, targetSize.width > 0, targetSize.height > 0 {
            displaySize = targetSize
        } else {
            let firstBounds = bounds(
                of: skin(prepared.mesh.vertices, bones: prepared.bones, poseTransforms: sourcePoses[0])
            )
            displaySize = firstBounds.size
        }
        guard displaySize.width > 0, displaySize.height > 0 else { return nil }

        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        let geometryNode = SCNNode(geometry: firstGeometry)
        geometryNode.castsShadow = false
        scene.rootNode.addChildNode(geometryNode)

        let pulseOverlays = makeMaskedPulseOverlays(
            effects: effects,
            geometries: geometries,
            texture: textureImage
        )
        for overlay in pulseOverlays {
            scene.rootNode.addChildNode(overlay.node)
        }

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(displaySize.height)
        camera.zNear = 0.1
        camera.zFar = 1_000
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 100)
        scene.rootNode.addChildNode(cameraNode)

        let node = SK3DNode(viewportSize: displaySize)
        node.scnScene = scene
        node.pointOfView = cameraNode
        node.autoenablesDefaultLighting = false
        node.isPlaying = true
        updatePulseMaterial(material, effects: effects, time: 0)
        updatePulseOverlays(pulseOverlays, time: 0)

        if animation != nil || dynamicWaterWaves || effects.hasDynamicMaterial {
            let playbackDuration = animation.map { $0.duration / playbackRate } ?? 0
            let frameCount = dynamicWaterWaves ? vertexSources.count : geometries.count
            let frameInterval = 1 / CGFloat(max(1, min(targetFPS, 120)))
            var lastHostTime = CACurrentMediaTime()
            var continuousTime = CGFloat(0)
            var currentIndex = -1
            var currentWaveTick = -1
            let action = SKAction.customAction(withDuration: 1) { _, _ in
                let now = CACurrentMediaTime()
                let delta = min(max(0, CGFloat(now - lastHostTime)), frameInterval * 2)
                lastHostTime = now
                continuousTime += delta
                let elapsedTime = continuousTime
                let nextIndex: Int
                if playbackDuration > 0, frameCount > 1 {
                    let phaseTime = elapsedTime.truncatingRemainder(dividingBy: playbackDuration)
                    let progress = min(0.999_999, max(0, phaseTime / playbackDuration))
                    nextIndex = min(frameCount - 1, Int(progress * CGFloat(frameCount)))
                } else {
                    nextIndex = 0
                }

                let waveTick = Int(floor(elapsedTime / frameInterval))
                let shouldRefreshGeometry = nextIndex != currentIndex || (dynamicWaterWaves && waveTick != currentWaveTick)
                if shouldRefreshGeometry {
                    currentIndex = nextIndex
                    currentWaveTick = waveTick

                    if dynamicWaterWaves, let geometry = dynamicGeometry(frameIndex: nextIndex, elapsedTime: elapsedTime) {
                        geometryNode.geometry = geometry
                        for overlay in pulseOverlays {
                            overlay.node.geometry = geometryCopy(geometry, material: overlay.material)
                        }
                    } else if nextIndex < geometries.count {
                        geometryNode.geometry = geometries[nextIndex]
                        for overlay in pulseOverlays where nextIndex < overlay.geometries.count {
                            overlay.node.geometry = overlay.geometries[nextIndex]
                        }
                    }
                }

                if effects.hasDynamicMaterial {
                    updatePulseMaterial(material, effects: effects, time: elapsedTime)
                    updatePulseOverlays(pulseOverlays, time: elapsedTime)
                }
            }
            node.run(.repeatForever(action), withKey: "we-puppet-scene-kit-animation")
            SceneWallpaperViewModel.log(
                "Puppet SceneKit animation: name=\(animation?.name ?? "none") mode=\(animation?.loopMode ?? "none") sourceFrames=\(sourcePoses.count) renderedGeometries=\(frameCount) fps=\(animation?.fps ?? 0) targetFPS=\(targetFPS) rate=\(playbackRate) duration=\(playbackDuration) dynamicWaterWaves=\(dynamicWaterWaves) texture=\(textureImage.width)x\(textureImage.height)"
            )
        }

        return node
    }

    static func render(
        mdlData: Data,
        texture: NSImage,
        targetSize: CGSize? = nil,
        maxTextureDimension: CGFloat
    ) -> NSImage? {
        let mdlData = Data(mdlData)
        guard let prepared = prepareModel(mdlData: mdlData, texture: texture) else { return nil }
        let poseTransforms = parseFirstAnimationPose(in: mdlData, boneCount: prepared.bones.count)
        guard let rendered = renderFrameCGImage(
            prepared: prepared,
            poseTransforms: poseTransforms,
            targetSize: targetSize,
            maxTextureDimension: maxTextureDimension,
            logSummary: true
        ) else { return nil }
        return NSImage(cgImage: rendered, size: CGSize(width: rendered.width, height: rendered.height))
    }

    static func renderAnimation(
        mdlData: Data,
        texture: NSImage,
        targetSize: CGSize? = nil,
        targetFPS: Double,
        animationRate: CGFloat = 1,
        options: WEPuppetAnimationRenderOptions
    ) -> WEPuppetRenderedAnimation? {
        let mdlData = Data(mdlData)
        guard let prepared = prepareModel(mdlData: mdlData, texture: texture),
              let animation = parseAnimation(in: mdlData, boneCount: prepared.bones.count),
              animation.frames.count > 1 else {
            return nil
        }

        let previewPose = animation.frames.first ?? []
        let previewBounds = bounds(of: skin(prepared.mesh.vertices, bones: prepared.bones, poseTransforms: previewPose))
        let nominalSize = targetSize ?? previewBounds.size
        let outputSize = cappedRenderSize(nominalSize, maxDimension: options.maxTextureDimension)
        let bytesPerFrame = max(1, Int(outputSize.width * outputSize.height * 4))
        let memoryBoundFrames = max(6, options.memoryBudget / bytesPerFrame)
        let playbackRate = validPlaybackRate(animationRate)
        let playbackDuration = animation.duration / playbackRate
        let requestedFrames = max(1, Int(ceil(playbackDuration * CGFloat(max(1, min(targetFPS, 120))))))
        let maxAnimationFrames = min(
            animation.frames.count,
            requestedFrames,
            options.maxFrameCount,
            memoryBoundFrames
        )
        let step = max(1, Int(ceil(Double(animation.frames.count) / Double(maxAnimationFrames))))
        let selectedIndices = Array(stride(from: 0, to: animation.frames.count, by: step))
        var textures: [SKTexture] = []
        textures.reserveCapacity(selectedIndices.count)

        for frameIndex in selectedIndices {
            autoreleasepool {
                guard let frame = renderFrameCGImage(
                    prepared: prepared,
                    poseTransforms: animation.frames[frameIndex],
                    targetSize: targetSize,
                    maxTextureDimension: options.maxTextureDimension,
                    logSummary: false
                ) else {
                    return
                }
                let texture = SKTexture(cgImage: frame)
                texture.filteringMode = .linear
                textures.append(texture)
            }
        }

        guard textures.count > 1 else { return nil }
        let timePerFrame = TimeInterval(playbackDuration / CGFloat(textures.count))
        SceneWallpaperViewModel.log(
            "Puppet animation input (\(options.label)): sourceFrames=\(animation.frames.count) renderedFrames=\(textures.count) fps=\(animation.fps) targetFPS=\(targetFPS) rate=\(playbackRate) duration=\(playbackDuration) step=\(step) output=\(Int(outputSize.width))x\(Int(outputSize.height)) frameBytes=\(bytesPerFrame)"
        )
        return WEPuppetRenderedAnimation(
            textures: textures,
            timePerFrame: max(timePerFrame, 1.0 / 120.0),
            duration: TimeInterval(playbackDuration),
            estimatedByteCost: bytesPerFrame * textures.count
        )
    }

    private static func validPlaybackRate(_ rate: CGFloat) -> CGFloat {
        guard rate.isFinite, rate > 0 else { return 1 }
        return rate
    }

    private static func sampledAnimationPoses(
        animation: WEPuppetAnimationData,
        playbackRate: CGFloat,
        targetFPS: Double
    ) -> [(poseTransforms: [CGAffineTransform], time: CGFloat)] {
        let sourceFrameCount = animation.frames.count
        guard sourceFrameCount > 1 else {
            return animation.frames.first.map { [(poseTransforms: $0, time: 0)] } ?? []
        }

        let sampleFPS = CGFloat(max(1, min(targetFPS, 120)))
        let playbackDuration = animation.duration / validPlaybackRate(playbackRate)
        let sampleCount = max(2, Int(ceil(playbackDuration * sampleFPS)))

        return (0..<sampleCount).map { sampleIndex in
            let playbackTime = playbackDuration * CGFloat(sampleIndex) / CGFloat(sampleCount)
            let sourceFrame = playbackTime * playbackRate * animation.fps
            return (
                poseTransforms: interpolatedPose(animation.frames, sourceFrame: sourceFrame),
                time: playbackTime
            )
        }
    }

    private static func interpolatedPose(
        _ frames: [[CGAffineTransform]],
        sourceFrame: CGFloat
    ) -> [CGAffineTransform] {
        guard frames.count > 1 else { return frames.first ?? [] }
        let frameCount = CGFloat(frames.count)
        let wrappedFrame = sourceFrame.truncatingRemainder(dividingBy: frameCount)
        let positiveFrame = wrappedFrame >= 0 ? wrappedFrame : wrappedFrame + frameCount
        let currentIndex = min(frames.count - 1, Int(floor(positiveFrame)))
        let nextIndex = (currentIndex + 1) % frames.count
        let fraction = positiveFrame - CGFloat(currentIndex)
        return interpolatePose(from: frames[currentIndex], to: frames[nextIndex], amount: fraction)
    }

    private static func interpolatePose(
        from current: [CGAffineTransform],
        to next: [CGAffineTransform],
        amount: CGFloat
    ) -> [CGAffineTransform] {
        guard current.count == next.count else { return current }
        let t = min(1, max(0, amount))
        return zip(current, next).map { pair in
            let a = pair.0
            let b = pair.1
            return CGAffineTransform(
                a: a.a + (b.a - a.a) * t,
                b: a.b + (b.b - a.b) * t,
                c: a.c + (b.c - a.c) * t,
                d: a.d + (b.d - a.d) * t,
                tx: a.tx + (b.tx - a.tx) * t,
                ty: a.ty + (b.ty - a.ty) * t
            )
        }
    }

    private static func sceneKitTextureImage(
        from image: NSImage,
        quality: GSTextureResolutionQuality
    ) -> CGImage? {
        guard let cgImage = makeCGImage(from: image) else { return nil }
        let maxDimension = sceneKitTextureDimension(for: quality)
        let largestSide = max(cgImage.width, cgImage.height)

        let scale = CGFloat(largestSide) > maxDimension ? maxDimension / CGFloat(largestSide) : 1
        let outputWidth = max(1, Int(round(CGFloat(cgImage.width) * scale)))
        let outputHeight = max(1, Int(round(CGFloat(cgImage.height) * scale)))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGImageByteOrderInfo.order32Big.rawValue
        ) else {
            return cgImage
        }

        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        return context.makeImage() ?? cgImage
    }

    private static func sceneKitTextureDimension(for quality: GSTextureResolutionQuality) -> CGFloat {
        switch quality {
        case .highQuality: return 4_096
        case .automatic: return 3_072
        case .highPerformance: return 2_048
        }
    }

    private static func sceneKitMaterial(texture: CGImage) -> SCNMaterial {
        let material = SCNMaterial()
        configureSceneKitTexture(material.diffuse, texture: texture)
        material.emission.contents = NSColor.black
        configureSceneKitTexture(material.transparent, texture: texture)
        material.lightingModel = .constant
        material.multiply.contents = nil
        material.transparencyMode = .aOne
        material.isDoubleSided = true
        material.transparency = 1
        material.blendMode = .alpha
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        applySceneKitSpriteKitColorCorrection(to: material)
        return material
    }

    private static func configureSceneKitTexture(_ property: SCNMaterialProperty, texture: CGImage) {
        property.contents = texture
        property.magnificationFilter = .linear
        property.minificationFilter = .linear
        property.mipFilter = .none
        property.wrapS = .clamp
        property.wrapT = .clamp
    }

    private static func applySceneKitSpriteKitColorCorrection(to material: SCNMaterial) {
        // SK3DNode hands SceneKit's linear pass to SpriteKit, so encode it back to display sRGB.
        material.shaderModifiers = [
            .fragment: """
            _output.color.rgb = pow(max(_output.color.rgb, vec3(0.0)), vec3(0.45454545));
            """
        ]
    }

    private static func makeMaskedPulseOverlays(
        effects: WESceneRenderEffects,
        geometries: [SCNGeometry],
        texture: CGImage
    ) -> [WEPulseOverlay] {
        guard !geometries.isEmpty else { return [] }

        return effects.pulseEffects.enumerated().compactMap { index, pulse in
            guard let maskImage = pulse.maskImage,
                  let maskCGImage = makeCGImage(from: maskImage),
                  let maskedTexture = maskedTextureImage(texture: texture, mask: maskCGImage) else {
                return nil
            }

            let material = maskedPulseMaterial(texture: maskedTexture, tint: pulse.tintHigh)
            let overlayGeometries = geometries.compactMap { geometry -> SCNGeometry? in
                guard let copy = geometry.copy() as? SCNGeometry else { return nil }
                copy.materials = [material]
                return copy
            }
            guard let firstGeometry = overlayGeometries.first else { return nil }

            let node = SCNNode(geometry: firstGeometry)
            node.castsShadow = false
            node.position.z = 0.04 + CGFloat(index) * 0.01
            return WEPulseOverlay(
                pulse: pulse,
                node: node,
                material: material,
                geometries: overlayGeometries
            )
        }
    }

    private static func maskedPulseMaterial(
        texture: CGImage,
        tint: (r: CGFloat, g: CGFloat, b: CGFloat)
    ) -> SCNMaterial {
        let material = SCNMaterial()
        let color = NSColor(
            red: min(1, max(0, tint.r)),
            green: min(1, max(0, tint.g)),
            blue: min(1, max(0, tint.b)),
            alpha: 1
        )
        configureSceneKitTexture(material.diffuse, texture: texture)
        material.multiply.contents = color
        material.emission.contents = NSColor.black
        configureSceneKitTexture(material.transparent, texture: texture)
        material.lightingModel = .constant
        material.transparencyMode = .aOne
        material.isDoubleSided = true
        material.transparency = 0
        material.blendMode = .add
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        applySceneKitSpriteKitColorCorrection(to: material)
        return material
    }

    private static func updatePulseOverlays(_ overlays: [WEPulseOverlay], time: CGFloat) {
        for overlay in overlays {
            let value = max(0, min(1, overlay.pulse.value(at: time)))
            let response = min(1, pow(value, 0.50) * 1.20)
            let tint = overlay.pulse.tintHigh
            let color = NSColor(
                red: min(1, max(0, tint.r)),
                green: min(1, max(0, tint.g)),
                blue: min(1, max(0, tint.b)),
                alpha: 1
            )
            overlay.material.multiply.contents = color
            overlay.material.transparency = min(0.85, response * 0.85)
        }
    }

    private static func maskedTextureImage(texture: CGImage, mask: CGImage) -> CGImage? {
        let width = texture.width
        let height = texture.height
        guard width > 0, height > 0 else { return nil }

        var texturePixels = Array(repeating: UInt8(0), count: width * height * 4)
        var maskPixels = Array(repeating: UInt8(0), count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGImageByteOrderInfo.order32Big.rawValue
        let textureDrawn = texturePixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            context.draw(texture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard textureDrawn else { return nil }

        let maskDrawn = maskPixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard maskDrawn else { return nil }

        var index = 0
        while index + 3 < texturePixels.count {
            let maskValue = max(maskPixels[index], max(maskPixels[index + 1], maskPixels[index + 2]))
            texturePixels[index] = UInt8((UInt16(texturePixels[index]) * UInt16(maskValue)) / 255)
            texturePixels[index + 1] = UInt8((UInt16(texturePixels[index + 1]) * UInt16(maskValue)) / 255)
            texturePixels[index + 2] = UInt8((UInt16(texturePixels[index + 2]) * UInt16(maskValue)) / 255)
            texturePixels[index + 3] = UInt8((UInt16(texturePixels[index + 3]) * UInt16(maskValue)) / 255)
            index += 4
        }

        return texturePixels.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }
            return context.makeImage()
        }
    }

    private static func updatePulseMaterial(
        _ material: SCNMaterial,
        effects: WESceneRenderEffects,
        time: CGFloat
    ) {
        let unmaskedPulses = effects.pulseEffects.filter { !$0.isMasked }
        guard !unmaskedPulses.isEmpty else {
            material.multiply.contents = nil
            return
        }

        var tint = (r: CGFloat(1), g: CGFloat(1), b: CGFloat(1))
        for pulse in unmaskedPulses {
            let value = pulse.value(at: time)
            let effectTint = (
                r: pulse.tintLow.r + (pulse.tintHigh.r - pulse.tintLow.r) * value,
                g: pulse.tintLow.g + (pulse.tintHigh.g - pulse.tintLow.g) * value,
                b: pulse.tintLow.b + (pulse.tintHigh.b - pulse.tintLow.b) * value
            )
            tint.r *= effectTint.r
            tint.g *= effectTint.g
            tint.b *= effectTint.b
        }

        material.multiply.contents = NSColor(
            red: min(1, max(0, tint.r)),
            green: min(1, max(0, tint.g)),
            blue: min(1, max(0, tint.b)),
            alpha: 1
        )
    }

    private static func sceneKitGeometry(
        prepared: WEPuppetPreparedModel,
        poseTransforms: [CGAffineTransform],
        material: SCNMaterial,
        indexData: Data,
        texcoordData: Data
    ) -> SCNGeometry? {
        guard let vertexSource = sceneKitVertexSource(prepared: prepared, poseTransforms: poseTransforms) else {
            return nil
        }
        return sceneKitGeometry(
            vertexSource: vertexSource,
            vertexCount: prepared.mesh.vertices.count,
            indexCount: prepared.mesh.indices.count,
            material: material,
            indexData: indexData,
            texcoordData: texcoordData
        )
    }

    private static func sceneKitVertexSource(
        prepared: WEPuppetPreparedModel,
        poseTransforms: [CGAffineTransform]
    ) -> SCNGeometrySource? {
        let points = skin(prepared.mesh.vertices, bones: prepared.bones, poseTransforms: poseTransforms)
        guard points.count == prepared.mesh.vertices.count else { return nil }

        var vertexData = Data(capacity: points.count * 3 * MemoryLayout<Float>.size)
        for point in points {
            appendFloat(Float(point.x), to: &vertexData)
            appendFloat(Float(point.y), to: &vertexData)
            appendFloat(0, to: &vertexData)
        }

        return SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: points.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 3 * MemoryLayout<Float>.size
        )
    }

    private static func sceneKitGeometry(
        vertexSource: SCNGeometrySource,
        vertexCount: Int,
        indexCount: Int,
        material: SCNMaterial,
        indexData: Data,
        texcoordData: Data
    ) -> SCNGeometry {
        let texcoordSource = SCNGeometrySource(
            data: texcoordData,
            semantic: .texcoord,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: 2 * MemoryLayout<Float>.size
        )
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indexCount / 3,
            bytesPerIndex: MemoryLayout<UInt16>.size
        )
        let geometry = SCNGeometry(sources: [vertexSource, texcoordSource], elements: [element])
        geometry.materials = [material]
        return geometry
    }

    private static func geometryCopy(_ geometry: SCNGeometry, material: SCNMaterial) -> SCNGeometry? {
        guard let copy = geometry.copy() as? SCNGeometry else { return nil }
        copy.materials = [material]
        return copy
    }

    private static func sceneKitIndexData(_ indices: [UInt16]) -> Data {
        var data = Data(capacity: indices.count * MemoryLayout<UInt16>.size)
        for value in indices {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func sceneKitTexcoordData(
        _ vertices: [WEPuppetVertex],
        waterWaves: [WEWaterWavesEffect],
        time: CGFloat
    ) -> Data {
        var data = Data(capacity: vertices.count * 2 * MemoryLayout<Float>.size)
        for vertex in vertices {
            let coord = waterWaves.reduce(CGPoint(x: vertex.u, y: vertex.v)) { coord, effect in
                waterWaveTexcoord(coord, effect: effect, time: time)
            }
            appendFloat(Float(coord.x), to: &data)
            appendFloat(Float(coord.y), to: &data)
        }
        return data
    }

    private static func waterWaveTexcoord(
        _ coord: CGPoint,
        effect: WEWaterWavesEffect,
        time: CGFloat
    ) -> CGPoint {
        guard effect.affectsGeometry else { return coord }
        let mask = effect.mask?.sample(u: coord.x, v: coord.y) ?? 1
        guard mask > 0.001 else { return coord }

        let direction = CGPoint(
            x: -sin(effect.direction),
            y: cos(effect.direction)
        )
        let distance = time * effect.speed + (coord.x * direction.x + coord.y * direction.y) * effect.scale
        let wave = sin(distance)
        let signedWave = (wave < 0 ? -1 : 1) * pow(abs(wave), max(0.01, effect.exponent))
        let offset = CGPoint(x: direction.y, y: -direction.x)
        let strength = effect.strength * effect.strength * mask

        return CGPoint(
            x: coord.x + signedWave * offset.x * strength,
            y: coord.y + signedWave * offset.y * strength
        )
    }

    private static func appendFloat(_ value: Float, to data: inout Data) {
        var mutableValue = value
        withUnsafeBytes(of: &mutableValue) { data.append(contentsOf: $0) }
    }

    private static func stableHash(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        data.withUnsafeBytes { rawBuffer in
            for byte in rawBuffer {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
        }
        return String(hash, radix: 16)
    }

    private static func prepareModel(mdlData: Data, texture: NSImage) -> WEPuppetPreparedModel? {
        guard let cgImage = makeCGImage(from: texture) else {
            SceneWallpaperViewModel.log("Puppet render failed: texture CGImage unavailable size=\(texture.size)")
            return nil
        }

        let textureSize = CGSize(width: cgImage.width, height: cgImage.height)
        guard textureSize.width > 0, textureSize.height > 0 else {
            SceneWallpaperViewModel.log("Puppet render failed: invalid texture size \(textureSize)")
            return nil
        }
        guard let mdlsOffset = findMarker("MDLS", in: mdlData) else {
            SceneWallpaperViewModel.log("Puppet render failed: MDLS marker missing")
            return nil
        }
        guard let mesh = parseMesh(in: mdlData, before: mdlsOffset) else {
            SceneWallpaperViewModel.log("Puppet render failed: mesh parse failed before MDLS offset \(mdlsOffset)")
            return nil
        }

        let bones = parseBones(in: mdlData, at: mdlsOffset)
        return WEPuppetPreparedModel(cgImage: cgImage, textureSize: textureSize, mesh: mesh, bones: bones)
    }

    private static func renderFrameCGImage(
        prepared: WEPuppetPreparedModel,
        poseTransforms: [CGAffineTransform],
        targetSize: CGSize?,
        maxTextureDimension: CGFloat,
        logSummary: Bool
    ) -> CGImage? {
        let positionedVertices = skin(prepared.mesh.vertices, bones: prepared.bones, poseTransforms: poseTransforms)
        let meshBounds = bounds(of: positionedVertices)
        guard meshBounds.width > 0, meshBounds.height > 0 else { return nil }

        let resolvedSize: CGSize
        if let targetSize,
           targetSize.width > 0,
           targetSize.height > 0 {
            resolvedSize = targetSize
        } else {
            resolvedSize = meshBounds.size
        }

        let renderSize = cappedRenderSize(resolvedSize, maxDimension: maxTextureDimension)
        let outputWidth = max(1, Int(ceil(renderSize.width)))
        let outputHeight = max(1, Int(ceil(renderSize.height)))
        let usesModelFrame = targetSize != nil
        let fitScale: CGFloat
        if usesModelFrame, let targetSize {
            fitScale = min(
                CGFloat(outputWidth) / max(targetSize.width, 1),
                CGFloat(outputHeight) / max(targetSize.height, 1)
            )
        } else {
            fitScale = min(
                CGFloat(outputWidth) / max(meshBounds.width, 1),
                CGFloat(outputHeight) / max(meshBounds.height, 1)
            )
        }

        if logSummary {
            SceneWallpaperViewModel.log(
                "Puppet render input: vertices=\(prepared.mesh.vertices.count) indices=\(prepared.mesh.indices.count) bones=\(prepared.bones.count) pose=\(poseTransforms.count) bounds=\(meshBounds) output=\(outputWidth)x\(outputHeight) scale=\(fitScale)"
            )
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            SceneWallpaperViewModel.log("Puppet render failed: CGContext unavailable output=\(outputWidth)x\(outputHeight)")
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        context.interpolationQuality = .high
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)

        let triangleCount = prepared.mesh.indices.count / 3
        for triangleIndex in 0..<triangleCount {
            let indexOffset = triangleIndex * 3
            let i0 = Int(prepared.mesh.indices[indexOffset])
            let i1 = Int(prepared.mesh.indices[indexOffset + 1])
            let i2 = Int(prepared.mesh.indices[indexOffset + 2])
            guard i0 < prepared.mesh.vertices.count, i1 < prepared.mesh.vertices.count, i2 < prepared.mesh.vertices.count else {
                continue
            }

            let vertices = [positionedVertices[i0], positionedVertices[i1], positionedVertices[i2]]
            let destination = vertices.map {
                if usesModelFrame {
                    return CGPoint(
                        x: $0.x * fitScale + CGFloat(outputWidth) / 2,
                        y: $0.y * fitScale + CGFloat(outputHeight) / 2
                    )
                }
                return CGPoint(x: ($0.x - meshBounds.minX) * fitScale, y: ($0.y - meshBounds.minY) * fitScale)
            }
            let source = [prepared.mesh.vertices[i0], prepared.mesh.vertices[i1], prepared.mesh.vertices[i2]].map {
                CGPoint(x: $0.u * prepared.textureSize.width, y: (1 - $0.v) * prepared.textureSize.height)
            }

            guard let transform = affineTransform(from: source, to: destination) else { continue }

            context.saveGState()
            let path = CGMutablePath()
            path.move(to: destination[0])
            path.addLine(to: destination[1])
            path.addLine(to: destination[2])
            path.closeSubpath()
            context.addPath(path)
            context.clip()
            context.concatenate(transform)
            context.draw(prepared.cgImage, in: CGRect(origin: .zero, size: prepared.textureSize))
            context.restoreGState()
        }

        return context.makeImage()
    }

    private static func cappedRenderSize(_ size: CGSize, maxDimension: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let largestSide = max(size.width, size.height)
        guard largestSide > maxDimension else { return size }
        let scale = maxDimension / largestSide
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private static func makeCGImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cgImage
        }

        if let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let cgImage = bitmap.cgImage {
            return cgImage
        }

        return nil
    }

    private static func bounds(of vertices: [CGPoint]) -> CGRect {
        guard let first = vertices.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y

        for vertex in vertices.dropFirst() {
            minX = min(minX, vertex.x)
            maxX = max(maxX, vertex.x)
            minY = min(minY, vertex.y)
            maxY = max(maxY, vertex.y)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func skin(
        _ vertices: [WEPuppetVertex],
        bones: [WEPuppetBone],
        poseTransforms: [CGAffineTransform]
    ) -> [CGPoint] {
        guard !bones.isEmpty else {
            return vertices.map { CGPoint(x: $0.x, y: $0.y) }
        }

        let parents = bones.map(\.parentIndex)
        let bindGlobals = globalTransforms(bones.map(\.bindTransform), parents: parents)
        let localPose = poseTransforms.count == bones.count ? poseTransforms : bones.map(\.bindTransform)
        let poseGlobals = globalTransforms(localPose, parents: parents)

        return vertices.map { vertex in
            let base = CGPoint(x: vertex.x, y: vertex.y)

            var skinned = CGPoint.zero
            var totalWeight: CGFloat = 0
            for (index, boneIndex) in vertex.boneIndices.enumerated() {
                guard index < vertex.boneWeights.count,
                      boneIndex >= 0, boneIndex < bones.count else {
                    continue
                }

                let weight = vertex.boneWeights[index]
                guard weight > 0 else { continue }
                let transformed = base
                    .applying(bindGlobals[boneIndex].inverted())
                    .applying(poseGlobals[boneIndex])
                skinned.x += transformed.x * weight
                skinned.y += transformed.y * weight
                totalWeight += weight
            }

            guard totalWeight > 0 else { return base }
            if abs(totalWeight - 1) > 0.001 {
                skinned.x /= totalWeight
                skinned.y /= totalWeight
            }
            return skinned
        }
    }

    private static func globalTransforms(_ localTransforms: [CGAffineTransform], parents: [Int?]) -> [CGAffineTransform] {
        var cache = Array<CGAffineTransform?>(repeating: nil, count: localTransforms.count)

        func build(_ index: Int) -> CGAffineTransform {
            if let cached = cache[index] { return cached }

            let local = localTransforms[index]
            let global: CGAffineTransform
            if let parent = parents[index],
               parent >= 0,
               parent < localTransforms.count,
               parent != index {
                global = local.concatenating(build(parent))
            } else {
                global = local
            }

            cache[index] = global
            return global
        }

        for index in localTransforms.indices {
            _ = build(index)
        }

        return cache.map { $0 ?? .identity }
    }

    private static func parseMesh(in data: Data, before mdlsOffset: Int) -> (vertices: [WEPuppetVertex], indices: [UInt16])? {
        var bestStart = 0
        var bestCount = 0
        let maxCandidate = min(256, mdlsOffset)

        for candidate in 0..<maxCandidate {
            var count = 0
            while candidate + (count + 1) * vertexStride <= mdlsOffset {
                let offset = candidate + count * vertexStride
                guard isValidVertexRecord(data, offset: offset) else { break }
                count += 1
            }
            if count > bestCount {
                bestStart = candidate
                bestCount = count
            }
        }

        guard bestCount >= 3 else { return nil }

        var vertices: [WEPuppetVertex] = []
        vertices.reserveCapacity(bestCount)
        for index in 0..<bestCount {
            let offset = bestStart + index * vertexStride
            guard let x = readFloat(data, offset),
                  let y = readFloat(data, offset + 4),
                  let bone0 = readUInt32(data, offset + 12),
                  let bone1 = readUInt32(data, offset + 16),
                  let bone2 = readUInt32(data, offset + 20),
                  let bone3 = readUInt32(data, offset + 24),
                  let weight0 = readFloat(data, offset + 28),
                  let weight1 = readFloat(data, offset + 32),
                  let weight2 = readFloat(data, offset + 36),
                  let weight3 = readFloat(data, offset + 40),
                  let u = readFloat(data, offset + 44),
                  let v = readFloat(data, offset + 48) else { return nil }
            vertices.append(WEPuppetVertex(
                x: CGFloat(x),
                y: CGFloat(y),
                u: CGFloat(u),
                v: CGFloat(v),
                boneIndices: [Int(bone0), Int(bone1), Int(bone2), Int(bone3)],
                boneWeights: [CGFloat(weight0), CGFloat(weight1), CGFloat(weight2), CGFloat(weight3)]
            ))
        }

        let indexStart = bestStart + bestCount * vertexStride + 4
        guard indexStart < mdlsOffset else { return nil }

        let indexByteCount = mdlsOffset - indexStart
        guard indexByteCount >= 6, indexByteCount % 6 == 0 else { return nil }

        var indices: [UInt16] = []
        indices.reserveCapacity(indexByteCount / 2)
        var offset = indexStart
        while offset + 2 <= mdlsOffset {
            guard let value = readUInt16(data, offset) else { return nil }
            indices.append(value)
            offset += 2
        }

        return (vertices, indices)
    }

    private static func parseBones(in data: Data, at mdlsOffset: Int) -> [WEPuppetBone] {
        var offset = mdlsOffset
        guard readNullTerminatedString(data, &offset)?.hasPrefix("MDLS") == true,
              let nextOffset = readUInt32(data, offset),
              nextOffset > UInt32(mdlsOffset),
              let boneCount = readUInt32(data, offset + 4) else {
            return []
        }

        offset += 8
        // Wallpaper Engine pads each MDLS bone record with one null byte.
        if offset < data.count && data[offset] == 0 {
            offset += 1
        }

        var bones: [WEPuppetBone] = []
        bones.reserveCapacity(Int(boneCount))

        for _ in 0..<boneCount {
            guard offset + 12 <= data.count,
                  let parentRaw = readUInt32(data, offset + 4),
                  let matrixByteCount = readUInt32(data, offset + 8),
                  matrixByteCount >= 64,
                  offset + 12 + Int(matrixByteCount) <= data.count else {
                return bones
            }

            offset += 12
            guard let m0 = readFloat(data, offset),
                  let m1 = readFloat(data, offset + 4),
                  let m4 = readFloat(data, offset + 16),
                  let m5 = readFloat(data, offset + 20),
                  let tx = readFloat(data, offset + 48),
                  let ty = readFloat(data, offset + 52) else {
                return bones
            }
            let parentIndex = parentRaw == UInt32.max ? nil : Int(parentRaw)
            let bindTransform = CGAffineTransform(
                a: CGFloat(m0),
                b: CGFloat(m1),
                c: CGFloat(m4),
                d: CGFloat(m5),
                tx: CGFloat(tx),
                ty: CGFloat(ty)
            )
            bones.append(WEPuppetBone(parentIndex: parentIndex, bindTransform: bindTransform))

            offset += Int(matrixByteCount)
            _ = readNullTerminatedString(data, &offset)
            if offset < data.count && data[offset] == 0 {
                offset += 1
            }
        }

        return bones
    }

    private static func parseFirstAnimationPose(in data: Data, boneCount: Int) -> [CGAffineTransform] {
        parseAnimation(in: data, boneCount: boneCount)?.frames.first ?? []
    }

    private static func parseAnimation(in data: Data, boneCount: Int) -> WEPuppetAnimationData? {
        guard boneCount > 0,
              let mdlaOffset = findMarker("MDLA", in: data) else {
            return nil
        }

        var offset = mdlaOffset
        guard readNullTerminatedString(data, &offset)?.hasPrefix("MDLA") == true,
              let animationEndRaw = readUInt32(data, offset),
              let animationCount = readUInt32(data, offset + 4),
              animationCount > 0 else {
            return nil
        }
        let animationEnd = min(Int(animationEndRaw), data.count)

        offset += 8
        guard offset + 8 <= data.count else { return nil }
        offset += 8 // animation id + unknown
        let animationName = readNullTerminatedString(data, &offset) ?? ""
        let loopMode = readNullTerminatedString(data, &offset) ?? ""

        guard offset + 16 <= data.count,
              let fpsRaw = readFloat(data, offset),
              let declaredFrameCountRaw = readUInt32(data, offset + 4),
              let animatedBoneCountRaw = readUInt32(data, offset + 12) else {
            return nil
        }

        let fps = CGFloat(max(1, min(fpsRaw, 120)))
        let declaredFrameCount = Int(declaredFrameCountRaw)
        let trackCount = min(Int(animatedBoneCountRaw), boneCount)
        offset += 16 // fps + frame count + unknown + animated bone count

        guard trackCount == boneCount else { return nil }

        var trackFrames = Array(repeating: [CGAffineTransform](), count: boneCount)
        var parsedFrameCount = Int.max

        for boneIndex in 0..<trackCount {
            guard offset + 8 <= data.count,
                  let trackByteCountRaw = readUInt32(data, offset + 4) else {
                return nil
            }

            let trackByteCount = Int(trackByteCountRaw)
            offset += 8 // track id + track byte count
            guard trackByteCount >= 36,
                  offset + trackByteCount <= animationEnd else {
                return nil
            }

            let usableFrameCount = trackByteCount / 36
            guard usableFrameCount > 0 else { return nil }

            var frames: [CGAffineTransform] = []
            frames.reserveCapacity(usableFrameCount)
            for frameIndex in 0..<usableFrameCount {
                let frameOffset = offset + frameIndex * 36
                guard let tx = readFloat(data, frameOffset),
                      let ty = readFloat(data, frameOffset + 4),
                      let rz = readFloat(data, frameOffset + 20),
                      let sx = readFloat(data, frameOffset + 24),
                      let sy = readFloat(data, frameOffset + 28) else {
                    return nil
                }

                var transform = CGAffineTransform(translationX: CGFloat(tx), y: CGFloat(ty))
                transform = transform.rotated(by: CGFloat(rz))
                transform = transform.scaledBy(x: CGFloat(sx), y: CGFloat(sy))
                frames.append(transform)
            }

            trackFrames[boneIndex] = frames
            parsedFrameCount = min(parsedFrameCount, frames.count)
            offset += trackByteCount
        }

        guard parsedFrameCount > 1, parsedFrameCount < Int.max else { return nil }

        var frames: [[CGAffineTransform]] = []
        frames.reserveCapacity(parsedFrameCount)
        for frameIndex in 0..<parsedFrameCount {
            var pose: [CGAffineTransform] = []
            pose.reserveCapacity(boneCount)
            for boneIndex in 0..<boneCount {
                pose.append(trackFrames[boneIndex][frameIndex])
            }
            frames.append(pose)
        }

        let durationFrames: Int
        if loopMode == "loop", declaredFrameCount > 0, declaredFrameCount < frames.count {
            frames = Array(frames.prefix(declaredFrameCount))
            durationFrames = declaredFrameCount
        } else if declaredFrameCount > 0 {
            durationFrames = min(declaredFrameCount, frames.count)
        } else if loopMode == "loop", frames.count > 1 {
            frames.removeLast()
            durationFrames = frames.count
        } else {
            durationFrames = frames.count
        }
        return WEPuppetAnimationData(
            name: animationName,
            loopMode: loopMode,
            fps: fps,
            duration: CGFloat(durationFrames) / fps,
            frames: frames
        )
    }

    private static func isValidVertexRecord(_ data: Data, offset: Int) -> Bool {
        guard offset + vertexStride <= data.count,
              let x = readFloat(data, offset),
              let y = readFloat(data, offset + 4),
              let z = readFloat(data, offset + 8),
              let u = readFloat(data, offset + 44),
              let v = readFloat(data, offset + 48),
              let bone0 = readUInt32(data, offset + 12),
              let bone1 = readUInt32(data, offset + 16),
              let bone2 = readUInt32(data, offset + 20),
              let bone3 = readUInt32(data, offset + 24),
              let weight0 = readFloat(data, offset + 28),
              let weight1 = readFloat(data, offset + 32),
              let weight2 = readFloat(data, offset + 36),
              let weight3 = readFloat(data, offset + 40) else { return false }

        let weights = [weight0, weight1, weight2, weight3]
        let weightSum = weights.reduce(Float(0), +)
        return x.isFinite && y.isFinite && z.isFinite && u.isFinite && v.isFinite
            && abs(x) < 20_000 && abs(y) < 20_000 && abs(z) < 0.001
            && u >= -0.05 && u <= 1.05 && v >= -0.05 && v <= 1.05
            && bone0 < 256 && bone1 < 256 && bone2 < 256 && bone3 < 256
            && weights.allSatisfy { $0.isFinite && $0 >= -0.001 && $0 <= 1.001 }
            && weightSum > 0.9 && weightSum < 1.1
    }

    private static func affineTransform(from source: [CGPoint], to destination: [CGPoint]) -> CGAffineTransform? {
        let x1 = source[0].x
        let y1 = source[0].y
        let x2 = source[1].x
        let y2 = source[1].y
        let x3 = source[2].x
        let y3 = source[2].y
        let x1Prime = destination[0].x
        let y1Prime = destination[0].y
        let x2Prime = destination[1].x
        let y2Prime = destination[1].y
        let x3Prime = destination[2].x
        let y3Prime = destination[2].y

        let determinant = x1 * (y2 - y3) + x2 * (y3 - y1) + x3 * (y1 - y2)
        guard abs(determinant) > 0.00001 else { return nil }

        let a = (x1Prime * (y2 - y3) + x2Prime * (y3 - y1) + x3Prime * (y1 - y2)) / determinant
        let c = (x1Prime * (x3 - x2) + x2Prime * (x1 - x3) + x3Prime * (x2 - x1)) / determinant
        let tx = (
            x1Prime * (x2 * y3 - x3 * y2)
            + x2Prime * (x3 * y1 - x1 * y3)
            + x3Prime * (x1 * y2 - x2 * y1)
        ) / determinant

        let b = (y1Prime * (y2 - y3) + y2Prime * (y3 - y1) + y3Prime * (y1 - y2)) / determinant
        let d = (y1Prime * (x3 - x2) + y2Prime * (x1 - x3) + y3Prime * (x2 - x1)) / determinant
        let ty = (
            y1Prime * (x2 * y3 - x3 * y2)
            + y2Prime * (x3 * y1 - x1 * y3)
            + y3Prime * (x1 * y2 - x2 * y1)
        ) / determinant

        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    private static func findMarker(_ marker: String, in data: Data) -> Int? {
        guard let markerData = marker.data(using: .ascii), !markerData.isEmpty else { return nil }
        var index = data.startIndex
        while index + markerData.count <= data.endIndex {
            if data[index..<index + markerData.count] == markerData {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func readNullTerminatedString(_ data: Data, _ offset: inout Int) -> String? {
        guard offset < data.count else { return nil }
        let start = offset
        while offset < data.count && data[offset] != 0 {
            offset += 1
        }
        guard offset < data.count else { return nil }
        let string = String(data: data[start..<offset], encoding: .utf8)
        offset += 1
        return string
    }

    private static func readFloat(_ data: Data, _ offset: Int) -> Float? {
        guard offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
}
