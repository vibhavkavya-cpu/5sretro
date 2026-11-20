import SwiftUI
import AVFoundation

@main struct RetroCamApp: App {
    var body: some Scene { WindowGroup { CameraView().preferredColorScheme(.dark).statusBarHidden() } }
}

enum Mode: String, CaseIterable { case photo = "PHOTO", filters = "FILTERS", manual = "MANUAL" }

struct FilterEditor: View {
    @Binding var params: FilterParams
    @Binding var strength: Double
    var onSave: ((String) -> Void)? = nil
    @State private var name = ""
    private let rows: [(String, WritableKeyPath<FilterParams, Double>, ClosedRange<Double>)] = [
        ("Exposure", \.exposure, -2...2), ("Contrast", \.contrast, 0.5...1.5), ("Saturation", \.saturation, 0...2),
        ("Temperature", \.temperature, -1...1), ("Tint", \.tint, -1...1), ("Highlights", \.highlights, 0...1), ("Shadows", \.shadows, -1...1),
        ("Fade", \.fade, 0...1), ("Grain", \.grain, 0...1), ("Color noise", \.chroma, 0...1), ("Grain size", \.grainSize, 0.5...3),
        ("Roughness", \.grainRoughness, 0...1), ("Bloom", \.bloom, 0...1), ("Halation", \.halation, 0...1), ("Vignette", \.vignette, 0...1),
        ("Sharpness", \.sharpness, 0...2), ("Chromatic aberr.", \.aberration, 0...1)]
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                row("Intensity", Binding(get: { strength }, set: { strength = $0 }), 0...1)
                ForEach(rows, id: \.0) { r in row(r.0, Binding(get: { params[keyPath: r.1] }, set: { params[keyPath: r.1] = $0 }), r.2) }
                HStack {
                    Button("Reset") { params = FilterParams(); strength = 1 }
                    if let onSave {
                        TextField("Preset name", text: $name).textFieldStyle(.roundedBorder)
                        Button("Save") { if !name.isEmpty { onSave(name); name = "" } }
                    }
                }.font(.footnote)
            }.padding()
        }
    }
    func row(_ t: String, _ b: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        HStack {
            Text(t.uppercased()).font(.system(size: 10)).foregroundStyle(.gray).frame(width: 96, alignment: .leading)
            Slider(value: b, in: r).tint(.white)
            Text(String(format: "%.2f", b.wrappedValue)).font(.system(size: 11, design: .monospaced)).frame(width: 40)
        }
    }
}

struct CameraView: View {
    @StateObject private var cam = CameraManager()
    @State private var mode = Mode.photo
    @State private var showLibrary = false, showEditor = false
    @State private var tapPoint: CGPoint?, bias: Float = 0, zoomBase: CGFloat = 1, zoom: CGFloat = 1
    @State private var manualExp = false, iso: Float = 100, shutterLog = 0.5, lens: Float = 0.5, wb = WB.auto
    @ObservedObject private var lib = Library.shared

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
            controls
            bottomBar
            modeBar
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { cam.start() }
        .sheet(isPresented: $showLibrary) { LibraryView() }
        .sheet(isPresented: $showEditor) {
            FilterEditor(params: $cam.params, strength: $cam.strength, onSave: cam.savePreset)
                .presentationDetents([.fraction(0.4), .large]).presentationBackgroundInteraction(.enabled).preferredColorScheme(.dark)
        }
    }

    var topBar: some View {
        HStack {
            Button { cam.flash = cam.flash == .on ? .off : .on } label: { Image(systemName: cam.flash == .on ? "bolt.fill" : "bolt.slash") }
                .disabled(!cam.caps.flash).opacity(cam.caps.flash ? 1 : 0.3)
            Spacer()
            Text(cam.presetName.uppercased()).font(.system(size: 10, weight: .medium)).foregroundStyle(.gray)
            Text(String(format: "%.1f×", zoom)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.yellow)
            Spacer()
            Button { cam.flip() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera") }
        }.padding(.horizontal, 20).frame(height: 44).foregroundStyle(.white)
        // Live Photo intentionally omitted: it can't be combined with a custom processed-JPEG pipeline.
    }

    var preview: some View {
        GeometryReader { g in
            ZStack {
                if let cg = cam.preview { Image(decorative: cg, scale: 1).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped() }
                if let p = tapPoint {
                    Rectangle().stroke(.yellow, lineWidth: 1).frame(width: 70, height: 70).position(p)
                    Slider(value: Binding(get: { Double(bias) }, set: { bias = Float($0); cam.setBias(bias) }),
                           in: Double(cam.caps.bias.lowerBound)...Double(cam.caps.bias.upperBound)).tint(.yellow)
                        .frame(width: 110).rotationEffect(.degrees(-90)).position(x: min(p.x + 55, g.size.width - 15), y: p.y)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { e in
                tapPoint = e.location; bias = 0; cam.setBias(0)
                cam.focus(normalized: CGPoint(x: e.location.x / g.size.width, y: e.location.y / g.size.height))
                let p = e.location
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if tapPoint == p { withAnimation { tapPoint = nil } } }
            })
            .gesture(MagnificationGesture().onChanged { zoom = min(max(zoomBase * $0, 1), cam.caps.maxZoom); cam.setZoom(zoom) }.onEnded { _ in zoomBase = zoom })
            .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { v in
                guard mode == .filters, abs(v.translation.width) > abs(v.translation.height) else { return }
                let n = cam.allPresets.count
                withAnimation(.easeOut(duration: 0.2)) { cam.presetIndex = (cam.presetIndex + (v.translation.width < 0 ? 1 : n - 1)) % n }
                UISelectionFeedbackGenerator().selectionChanged()
            })
        }.aspectRatio(3.0 / 4.0, contentMode: .fit)
    }

    @ViewBuilder var controls: some View {
        switch mode {
        case .photo: Spacer(minLength: 0)
        case .filters:
            VStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(Array(cam.allPresets.enumerated()), id: \.offset) { i, p in
                            Text(p.name.uppercased()).font(.system(size: 11, weight: .medium)).foregroundStyle(i == cam.presetIndex ? .yellow : .gray)
                                .onTapGesture { cam.presetIndex = i }
                        }
                    }.padding(.horizontal, 20)
                }
                slider("INTENSITY", $cam.strength, 0...1, "%.2f")
                slider("GRAIN", $cam.params.grain, 0...1, "%.2f")
            }.padding(.vertical, 8)
        case .manual: manualPanel
        }
    }

    var manualPanel: some View {
        let c = cam.caps
        return ScrollView {
            VStack(spacing: 6) {
                Toggle("MANUAL EXPOSURE", isOn: $manualExp).font(.system(size: 10)).toggleStyle(.switch).tint(.yellow)
                    .disabled(c.iso == nil || c.shutter == nil)
                    .onChange(of: manualExp) { _, on in on ? pushExposure() : cam.setAutoExposure() }
                if let r = c.iso {
                    slider("ISO", Binding(get: { Double(iso) }, set: { iso = Float($0); pushExposure() }), Double(max(r.lowerBound, 50))...Double(r.upperBound), "%.0f").disabled(!manualExp)
                } else { unsupported("ISO") }
                if let r = c.shutter {
                    let lo = log(max(r.lowerBound, 1.0 / 8000)), hi = log(min(r.upperBound, 1.0))
                    let t = exp(lo + (hi - lo) * shutterLog)
                    slider("SHUTTER \(t < 1 ? "1/\(Int(1 / t))" : "1")s", $shutterLog, 0...1, "").disabled(!manualExp)
                        .onChange(of: shutterLog) { _, _ in pushExposure() }
                } else { unsupported("SHUTTER") }
                if c.manualFocus { slider("FOCUS", Binding(get: { Double(lens) }, set: { lens = Float($0); cam.setLens(lens) }), 0...1, "%.2f") } else { unsupported("MANUAL FOCUS") }
                slider("EXP COMP", Binding(get: { Double(bias) }, set: { bias = Float($0); cam.setBias(bias) }), Double(c.bias.lowerBound)...Double(c.bias.upperBound), "%+.1f")
                if c.wbLock {
                    Picker("WB", selection: $wb) { ForEach(WB.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                        .onChange(of: wb) { _, v in cam.setWB(v) }
                } else { unsupported("WHITE BALANCE") }
            }.padding(.horizontal, 20)
        }.frame(maxHeight: 170)
    }
    func pushExposure() {
        guard let r = cam.caps.shutter else { return }
        let lo = log(max(r.lowerBound, 1.0 / 8000)), hi = log(min(r.upperBound, 1.0))
        cam.setManualExposure(iso: iso, shutter: exp(lo + (hi - lo) * shutterLog))
    }
    func unsupported(_ t: String) -> some View {
        Text("\(t) — NOT SUPPORTED ON THIS DEVICE").font(.system(size: 9)).foregroundStyle(.gray.opacity(0.6)).frame(maxWidth: .infinity, alignment: .leading)
    }
    func slider(_ t: String, _ b: Binding<Double>, _ r: ClosedRange<Double>, _ f: String) -> some View {
        HStack {
            Text(t).font(.system(size: 10)).foregroundStyle(.gray).frame(width: 84, alignment: .leading)
            Slider(value: b, in: r).tint(.white)
            if !f.isEmpty { Text(String(format: f, b.wrappedValue)).font(.system(size: 11, design: .monospaced)).frame(width: 40) }
        }.padding(.horizontal, 20)
    }

    var bottomBar: some View {
        HStack {
            Button { showLibrary = true } label: {
                Group { if let r = lib.items.first { Thumb(id: r.id, px: 120).id(lib.version) } else { Color(white: 0.12) } }
                    .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Spacer()
            Button { cam.capture() } label: {
                ZStack { Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74); Circle().fill(.white).frame(width: 62, height: 62) }
            }.buttonStyle(ShutterStyle())
            Spacer()
            Button { showEditor = true } label: { Image(systemName: "slider.horizontal.3").font(.title2).frame(width: 48, height: 48) }
        }.padding(.horizontal, 28).padding(.vertical, 12).foregroundStyle(.white)
    }

    var modeBar: some View {
        HStack(spacing: 28) {
            ForEach(Mode.allCases, id: \.self) { m in
                Text(m.rawValue).font(.system(size: 12, weight: .medium)).foregroundStyle(m == mode ? .yellow : .gray)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { mode = m } }
            }
        }.padding(.bottom, 10)
    }
}

struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1).animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
