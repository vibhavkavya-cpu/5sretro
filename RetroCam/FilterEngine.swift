import CoreImage

struct FilterParams: Codable, Equatable {
    var exposure = 0.0, contrast = 1.0, saturation = 1.0
    var temperature = 0.0, tint = 0.0
    var highlights = 1.0, shadows = 0.0, fade = 0.0
    var grain = 0.0, chroma = 0.0, grainSize = 1.0, grainRoughness = 0.3
    var bloom = 0.0, halation = 0.0, vignette = 0.0
    var sharpness = 0.0, aberration = 0.0
    static func with(_ f: (inout FilterParams) -> Void) -> FilterParams { var p = FilterParams(); f(&p); return p }
}

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var params: FilterParams
    static let builtIn: [Preset] = [
        Preset(name: "iPhone 5S", params: .with { $0.temperature = 0.15; $0.contrast = 1.08; $0.saturation = 1.05; $0.highlights = 0.85; $0.shadows = 0.1; $0.grain = 0.08; $0.sharpness = 0.4; $0.vignette = 0.1; $0.bloom = 0.1 }),
        Preset(name: "CCD Flash", params: .with { $0.exposure = 0.15; $0.contrast = 1.25; $0.saturation = 1.2; $0.temperature = -0.1; $0.tint = 0.1; $0.grain = 0.15; $0.chroma = 0.35; $0.sharpness = 0.9; $0.vignette = 0.25 }),
        Preset(name: "Golden Haze", params: .with { $0.exposure = 0.2; $0.contrast = 0.88; $0.temperature = 0.5; $0.highlights = 0.7; $0.fade = 0.4; $0.bloom = 0.7; $0.halation = 0.6; $0.grain = 0.1; $0.vignette = 0.2 }),
        Preset(name: "Cold Memory", params: .with { $0.temperature = -0.45; $0.saturation = 0.7; $0.contrast = 0.95; $0.fade = 0.5; $0.grain = 0.45; $0.grainSize = 1.3; $0.grainRoughness = 0.5; $0.vignette = 0.3 }),
        Preset(name: "Digicam 2005", params: .with { $0.temperature = 0.12; $0.tint = -0.2; $0.contrast = 1.2; $0.saturation = 1.3; $0.grain = 0.35; $0.chroma = 0.5; $0.sharpness = 1.2; $0.aberration = 0.4; $0.vignette = 0.2 }),
        Preset(name: "Soft Film", params: .with { $0.contrast = 0.95; $0.saturation = 0.95; $0.temperature = 0.1; $0.highlights = 0.7; $0.shadows = 0.15; $0.fade = 0.2; $0.grain = 0.3; $0.grainSize = 1.6; $0.grainRoughness = 0.2; $0.bloom = 0.15 }),
    ]
}

struct SplitMix64: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31)
    }
}

enum FilterEngine {
    static let ctx = CIContext()

    private static func matrix(_ i: CIImage, r: [CGFloat], g: [CGFloat], b: [CGFloat], bias: [CGFloat] = [0, 0, 0, 0]) -> CIImage {
        i.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(values: r, count: 4), "inputGVector": CIVector(values: g, count: 4),
            "inputBVector": CIVector(values: b, count: 4), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(values: bias, count: 4)])
    }
    private static func screen(_ top: CIImage, over bg: CIImage) -> CIImage {
        top.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: bg])
    }

    /// `scale` = processed size / full-res size, so blur and grain sizes match between preview and capture.
    static func apply(_ input: CIImage, _ p: FilterParams, seed: UInt64, scale: CGFloat = 1, strength: Double = 1) -> CIImage {
        let ext = input.extent
        var img = input
        if p.exposure != 0 { img = img.applyingFilter("CIExposureAdjust", parameters: ["inputEV": p.exposure]) }
        if p.temperature != 0 || p.tint != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + p.temperature * 1500, y: p.tint * 50),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        img = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: p.saturation, kCIInputContrastKey: p.contrast])
        if p.highlights != 1 || p.shadows != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": p.highlights, "inputShadowAmount": p.shadows])
        }
        if p.fade > 0 { // lift blacks
            let b = CGFloat(p.fade) * 0.08, s = 1 - b
            img = matrix(img, r: [s, 0, 0, 0], g: [0, s, 0, 0], b: [0, 0, s, 0], bias: [b, b, b, 0])
        }
        if p.bloom > 0 {
            img = img.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: 25 * scale, kCIInputIntensityKey: p.bloom]).cropped(to: ext)
        }
        if p.halation > 0 { // red-orange glow bleeding from bright areas
            let h = CGFloat(p.halation) * 0.8
            let hi = matrix(img, r: [3, 0, 0, 0], g: [0, 3, 0, 0], b: [0, 0, 3, 0], bias: [-2.1, -2.1, -2.1, 0]).applyingFilter("CIColorClamp")
            let tinted = matrix(hi, r: [h, 0, 0, 0], g: [0, 0.3 * h, 0, 0], b: [0, 0, 0.08 * h, 0])
            img = screen(tinted.clampedToExtent().applyingGaussianBlur(sigma: 25 * scale).cropped(to: ext), over: img)
        }
        if p.aberration > 0 { // split channels apart
            let a = CGFloat(p.aberration) * 4 * scale
            let r = matrix(img, r: [1, 0, 0, 0], g: [0, 0, 0, 0], b: [0, 0, 0, 0]).transformed(by: .init(translationX: a, y: 0))
            let g = matrix(img, r: [0, 0, 0, 0], g: [0, 1, 0, 0], b: [0, 0, 0, 0])
            let b = matrix(img, r: [0, 0, 0, 0], g: [0, 0, 0, 0], b: [0, 0, 1, 0]).transformed(by: .init(translationX: -a, y: 0))
            img = screen(r, over: screen(g, over: b)).cropped(to: ext)
        }
        if p.sharpness > 0 { img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: p.sharpness]) }
        if p.vignette > 0 { img = img.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: p.vignette * 1.5, kCIInputRadiusKey: 2]) }

        if p.grain > 0 || p.chroma > 0 {
            var rng = SplitMix64(s: seed) // different noise field per photo/frame
            func field() -> CIImage {
                let s = max(1, 1.5 * CGFloat(p.grainSize) * scale)
                var n = CIFilter(name: "CIRandomGenerator")!.outputImage!
                    .transformed(by: .init(translationX: CGFloat(rng.next() % 8192), y: CGFloat(rng.next() % 8192)))
                    .transformed(by: .init(scaleX: s, y: s)).cropped(to: ext)
                if p.grainRoughness > 0 { // organic clumping
                    n = n.clampedToExtent().applyingGaussianBlur(sigma: p.grainRoughness * s * 0.6).cropped(to: ext)
                }
                return n
            }
            if p.grain > 0 { // luminance noise
                let k = CGFloat(p.grain) * 1.6, b = 0.5 - 0.5 * k
                img = matrix(field(), r: [k, 0, 0, 0], g: [k, 0, 0, 0], b: [k, 0, 0, 0], bias: [b, b, b, 0])
                    .applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: img])
            }
            if p.chroma > 0 { // independent per-channel noise
                let k = CGFloat(p.chroma) * 1.2, b = 0.5 - 0.5 * k
                img = matrix(field(), r: [k, 0, 0, 0], g: [0, k, 0, 0], b: [0, 0, k, 0], bias: [b, b, b, 0])
                    .applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: img])
            }
        }
        if strength < 1 {
            img = input.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: img, kCIInputTimeKey: strength])
        }
        return img.cropped(to: ext)
    }
}
