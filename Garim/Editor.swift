import Photos
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class Editor: ObservableObject {
    @Published private(set) var document: PhotoDocument?
    @Published private(set) var regions: [MaskRegion] = []
    @Published private(set) var strength: MosaicStrength = .regular
    @Published private(set) var preview: CGImage?
    @Published private(set) var loading = false
    @Published private(set) var rendering = false
    @Published private(set) var saving = false
    @Published private(set) var saved = false
    @Published var notice: String?
    @Published var needsSettings = false

    private let engine = PhotoEngine()
    private var revision = UUID()
    private var previewTask: Task<Void, Never>?
    var coveredCount: Int { regions.filter(\.covered).count }
    var canSave: Bool {
        document != nil && preview != nil && coveredCount > 0 && !loading && !rendering && !saving && !saved
    }

    func load(_ item: PhotosPickerItem) async {
        guard !saving else { return }
        let ticket = UUID()
        revision = ticket
        previewTask?.cancel()
        loading = true
        rendering = false
        defer { if revision == ticket { loading = false } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoError.unreadable }
            try Task.checkCancellation()
            guard revision == ticket else { return }
            let photo = try await engine.open(data)
            let image = try await engine.preview(photo, regions: photo.regions, strength: .regular)
            try Task.checkCancellation()
            guard revision == ticket else { return }
            document = photo
            regions = photo.regions
            strength = .regular
            preview = image
            saved = false
        } catch {
            guard revision == ticket, !Task.isCancelled else { return }
            notice = "사진을 불러오지 못했어요. 원본이 iCloud에만 있다면 사진 앱에서 먼저 내려받아 주세요."
            if document != nil && preview == nil {
                loading = false
                refresh()
            }
        }
    }

    func toggle(_ id: UUID) {
        guard !saving, let i = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[i].covered.toggle()
        refresh()
    }

    func add(_ region: MaskRegion) {
        guard !saving else { return }
        regions.append(region)
        refresh()
    }

    func setStrength(_ value: MosaicStrength) {
        guard !saving, value != strength else { return }
        strength = value
        refresh()
    }

    func refresh() {
        guard let document, !saving else { return }
        let ticket = UUID()
        revision = ticket
        previewTask?.cancel()
        let masks = regions
        let level = strength
        saved = false
        rendering = true
        preview = nil
        previewTask = Task {
            do {
                let image = try await engine.preview(document, regions: masks, strength: level)
                guard ticket == revision, !Task.isCancelled else { return }
                preview = image
            } catch {
                guard ticket == revision, !Task.isCancelled else { return }
                notice = PhotoError.render.localizedDescription
            }
            if ticket == revision { rendering = false }
        }
    }

    func save() async {
        guard canSave, let document else { return }
        saving = true
        defer { saving = false }
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                needsSettings = status == .denied
                throw PhotoError.permission
            }
            let data = try await engine.jpeg(document, regions: regions, strength: strength)
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "Garim-\(UUID().uuidString).jpg"
                request.addResource(with: .photo, data: data, options: options)
            }
            saved = true
            UIAccessibility.post(notification: .announcement, argument: "새 사진을 저장했어요.")
        } catch {
            notice = (error as? PhotoError)?.localizedDescription ?? "사진을 저장하지 못했어요. 여유 공간을 확인한 뒤 다시 시도해 주세요."
        }
    }
}
