import UIKit
import Photos
import ImageIO
import SwiftUI

struct CaptureRecord: Codable, Identifiable, Hashable {
    var id: String, filter: String, params: FilterParams, strength: Double
    var iso: Double?, shutter: Double?, date: Date
    func hash(into h: inout Hasher) { h.combine(id) }
}

final class Library: ObservableObject {
    static let shared = Library()
    @Published var items: [CaptureRecord] = []
    @Published var version = 0
    let dir: URL
    init() {
        dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Captures")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
    }
    func url(_ id: String, _ ext: String) -> URL { dir.appendingPathComponent("\(id).\(ext)") }
    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        let all = files.filter { $0.pathExtension == "json" }.compactMap { try? dec.decode(CaptureRecord.self, from: Data(contentsOf: $0)) }
        DispatchQueue.main.async { self.items = all.sorted { $0.date > $1.date }; self.version += 1 }
    }
    /// Processes the ORIGINAL full-res image (not the preview) with a fresh grain seed. Original is kept for re-editing.
    func save(original: Data, params: FilterParams, strength: Double, filter: String, iso: Double?, shutter: Double?, id: String?, toPhotos: Bool) {
        guard let ci = CIImage(data: original, options: [.applyOrientationProperty: true]) else { return }
        let out = FilterEngine.apply(ci, params, seed: UInt64.random(in: 1...UInt64.max), scale: 1, strength: strength)
        guard let jpeg = FilterEngine.ctx.jpegRepresentation(of: out, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]) else { return }
        let rid = id ?? UUID().uuidString
        let old = items.first { $0.id == rid }
        let rec = CaptureRecord(id: rid, filter: filter, params: params, strength: strength, iso: iso ?? old?.iso, shutter: shutter ?? old?.shutter, date: old?.date ?? Date())
        try? jpeg.write(to: url(rid, "jpg"))
        if id == nil { try? original.write(to: url(rid, "orig")) }
        try? JSONEncoder().encode(rec).write(to: url(rid, "json"))
        if toPhotos { exportToPhotos(jpeg) }
        reload()
    }
    func exportToPhotos(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else { return }
            PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil) }
        }
    }
    func delete(_ id: String) { ["jpg", "orig", "json"].forEach { try? FileManager.default.removeItem(at: url(id, $0)) }; reload() }
    func image(_ id: String, ext: String = "jpg", maxPixel: Int) -> UIImage? {
        guard let s = CGImageSourceCreateWithURL(url(id, ext) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct Thumb: View {
    let id: String; var px = 300
    @State private var img: UIImage?
    var body: some View {
        Color(white: 0.1).overlay(Group { if let img { Image(uiImage: img).resizable().scaledToFill() } }).clipped()
            .task(id: id) { img = await Task.detached { Library.shared.image(id, maxPixel: px) }.value }
    }
}

struct LibraryView: View {
    @ObservedObject var lib = Library.shared
    @Environment(\.dismiss) var dismiss
    @State private var selected: CaptureRecord?
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(lib.items) { r in
                        Thumb(id: r.id).aspectRatio(1, contentMode: .fit).onTapGesture { selected = r }
                    }
                }
            }
            .background(Color.black).navigationTitle("Collection").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .navigationDestination(item: $selected) { Viewer(start: $0.id) }
        }.preferredColorScheme(.dark)
    }
}

struct Viewer: View {
    @ObservedObject var lib = Library.shared
    @State var start: String
    @State private var editing: CaptureRecord?
    @Environment(\.dismiss) var dismiss
    var rec: CaptureRecord? { lib.items.first { $0.id == start } }
    var body: some View {
        TabView(selection: $start) {
            ForEach(lib.items) { r in
                Thumb(id: r.id, px: 2400).scaledToFit().id("\(r.id)-\(lib.version)").tag(r.id)
            }
        }.tabViewStyle(.page(indexDisplayMode: .never)).background(Color.black).ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .bottom) {
            if let r = rec {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.filter.uppercased()).font(.caption.weight(.semibold))
                    Text([r.iso.map { "ISO \(Int($0))" }, r.shutter.map { $0 < 1 ? "1/\(Int(1 / $0))s" : "\($0)s" },
                          r.date.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.caption2).foregroundStyle(.gray)
                }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.black)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let r = rec {
                    Button { editing = r } label: { Image(systemName: "slider.horizontal.3") }
                    ShareLink(item: lib.url(r.id, "jpg"))
                    Button { if let d = try? Data(contentsOf: lib.url(r.id, "jpg")) { lib.exportToPhotos(d) } } label: { Image(systemName: "square.and.arrow.down") }
                    Button(role: .destructive) { lib.delete(r.id); if lib.items.isEmpty { dismiss() } else { start = lib.items[0].id } } label: { Image(systemName: "trash") }
                }
            }
        }
        .sheet(item: $editing) { ReEdit(rec: $0) }
    }
}

struct ReEdit: View {
    let rec: CaptureRecord
    @State private var params: FilterParams
    @State private var strength: Double
    @State private var name: String
    @State private var base: CIImage?
    @Environment(\.dismiss) var dismiss
    init(rec: CaptureRecord) { self.rec = rec; _params = State(initialValue: rec.params); _strength = State(initialValue: rec.strength); _name = State(initialValue: rec.filter) }
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let base {
                    let out = FilterEngine.apply(base, params, seed: 7, scale: base.extent.width / 4032, strength: strength)
                    if let cg = FilterEngine.ctx.createCGImage(out, from: base.extent) { Image(decorative: cg, scale: 1).resizable().scaledToFit() }
                } else { ProgressView() }
            }.frame(maxHeight: 340)
            FilterEditor(params: $params, strength: $strength)
            Button("Save") {
                if let d = try? Data(contentsOf: Library.shared.url(rec.id, "orig")) {
                    let (p, k, n) = (params, strength, name)
                    DispatchQueue.global().async { Library.shared.save(original: d, params: p, strength: k, filter: n + "*", iso: nil, shutter: nil, id: rec.id, toPhotos: false) }
                }
                dismiss()
            }.padding()
        }.background(Color.black).preferredColorScheme(.dark)
        .task { if let u = Library.shared.image(rec.id, ext: "orig", maxPixel: 1000), let cg = u.cgImage { base = CIImage(cgImage: cg) } }
    }
}
