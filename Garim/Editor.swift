import Photos
import PhotosUI
import SwiftUI
import UIKit

struct BatchProgress: Equatable {
    var done: Int
    let total: Int
}

@MainActor
final class Editor: ObservableObject {
    static let selectionLimit = 20
    /// Keeps a batch of RAW or very large originals from exhausting memory.
    static let byteLimit = 600_000_000

    @Published private(set) var pages: [PhotoPage] = []
    @Published private(set) var currentID: UUID?
    @Published private(set) var style = MaskStyle()
    /// The editing preview of the current photo before masking.
    @Published private(set) var source: CGImage?
    @Published private(set) var preview: CGImage?
    /// Tint over the subjects in keep mode.
    @Published private(set) var overlay: CGImage?
    @Published private(set) var importProgress: BatchProgress?
    @Published private(set) var saveProgress: BatchProgress?
    /// The running save was started by "save all".
    @Published private(set) var savingAll = false
    @Published private(set) var rendering = false
    @Published private(set) var analyzing: Set<UUID> = []
    @Published var notice: String?
    @Published var needsSettings = false

    private let engine = PhotoEngine()
    private var revision = UUID()
    private var previewTask: Task<Void, Never>?
    private var sourceID: UUID?
    private var previewID: UUID?
    private var analysisTasks: [UUID: Task<SubjectAnalysis, Never>] = [:]

    var currentIndex: Int? {
        guard let currentID else { return nil }
        return pages.firstIndex { $0.id == currentID }
    }
    var current: PhotoPage? { currentIndex.map { pages[$0] } }
    var importing: Bool { importProgress != nil }
    var saving: Bool { saveProgress != nil }
    var busy: Bool { importing || saving }
    var canAddPhotos: Bool { !busy && pages.count < Self.selectionLimit }
    var analyzingCurrent: Bool { currentID.map { analyzing.contains($0) } ?? false }

    /// Covered areas in cover mode, kept subjects and areas in keep mode.
    var activeCount: Int {
        guard let page = current else { return 0 }
        switch style.mode {
        case .cover:
            return page.regions.filter(\.active).count
        case .keep:
            let subjects = page.analysis.result?.subjects ?? []
            return subjects.filter { page.kept.contains($0.id) }.count + page.keepAreas.filter(\.active).count
        }
    }

    var canSaveCurrent: Bool {
        guard let page = current else { return false }
        return !busy && !rendering && preview != nil && previewID == page.id
            && !page.saved && page.plan(style).changesPhoto
    }

    var unsavedCount: Int { pages.filter(isPending).count }
    var canSaveAll: Bool { !busy && unsavedCount > 0 }

    /// Photos left out of "save all" in keep mode because their kept subjects were never shown.
    var unreviewedCount: Int {
        style.mode == .keep ? pages.filter { !$0.saved && !$0.keepReviewed }.count : 0
    }

    /// In keep mode a photo is saved only after its kept subjects were on screen, so a batch save never
    /// reveals a person the user didn't choose to keep.
    private func isPending(_ page: PhotoPage) -> Bool {
        !page.saved && page.plan(style).changesPhoto && (style.mode == .cover || page.keepReviewed)
    }

    // MARK: - Batch

    func load(_ items: [PhotosPickerItem], replacing: Bool) async {
        await load(items, replacing: replacing) { try await $0.loadTransferable(type: Data.self) }
    }

    /// Imports one original at a time, including when Photos has to fetch it from iCloud.
    func load<Item>(_ items: [Item], replacing: Bool, read: (Item) async throws -> Data?) async {
        guard !busy, !items.isEmpty else { return }
        let room = replacing ? Self.selectionLimit : Self.selectionLimit - pages.count
        let picked = Array(items.prefix(max(0, room)))
        guard !picked.isEmpty else {
            notice = "사진은 한 번에 \(Self.selectionLimit)장까지 편집할 수 있어요."
            return
        }
        cancelPreview()
        importProgress = BatchProgress(done: 0, total: picked.count)
        var loaded: [PhotoPage] = []
        var firstSource: CGImage?
        var bytes = replacing ? 0 : pages.reduce(0) { $0 + $1.original.count }
        var failed = 0
        var tooLarge = 0
        for item in picked {
            if Task.isCancelled { break }
            do {
                guard let data = try await read(item) else { throw PhotoError.unreadable }
                if bytes + data.count > Self.byteLimit {
                    tooLarge += 1
                } else {
                    let photo = try await engine.open(data)
                    loaded.append(photo.page)
                    bytes += data.count
                    if firstSource == nil { firstSource = photo.source }
                }
            } catch {
                if Task.isCancelled { break }
                failed += 1
            }
            importProgress?.done += 1
        }
        importProgress = nil

        var messages: [String] = []
        if items.count > picked.count {
            messages.append("한 번에 \(Self.selectionLimit)장까지 편집할 수 있어 \(items.count - picked.count)장은 빼고 불러왔어요.")
        }
        if tooLarge > 0 { messages.append("용량이 커서 \(tooLarge)장은 불러오지 않았어요.") }
        if failed > 0 {
            messages.append("\(failed)장은 불러오지 못했어요. 원본이 iCloud에만 있다면 사진 앱에서 먼저 내려받아 주세요.")
        }
        if !messages.isEmpty { notice = messages.joined(separator: "\n") }

        guard let first = loaded.first else {
            // Nothing new arrived; keep editing the photos that were already open.
            refresh()
            return
        }
        if replacing {
            pages = loaded
        } else {
            pages.append(contentsOf: loaded)
        }
        currentID = first.id
        source = firstSource
        sourceID = firstSource == nil ? nil : first.id
        preview = nil
        previewID = nil
        overlay = nil
        refresh()
    }

    func openSample() async {
        guard !busy, pages.isEmpty, let data = FieldStudy.data else { return }
        style = MaskStyle()
        await load([data], replacing: true) { $0 }
        addArea(MaskRegion(box: FieldStudy.plate, manual: true))
    }

    func select(_ id: UUID) {
        guard !busy, id != currentID, pages.contains(where: { $0.id == id }) else { return }
        currentID = id
        refresh()
    }

    /// Takes a photo out of the batch without touching the photo library.
    func remove(_ id: UUID) {
        guard !busy, let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages.remove(at: index)
        guard !pages.isEmpty else {
            close()
            return
        }
        if currentID == id {
            currentID = pages[min(index, pages.count - 1)].id
            refresh()
        }
    }

    /// Returns to the start screen.
    func close() {
        guard !busy else { return }
        cancelPreview()
        pages = []
        currentID = nil
        source = nil
        sourceID = nil
        preview = nil
        previewID = nil
        overlay = nil
    }

    // MARK: - Editing the current photo

    func toggleArea(_ id: UUID) {
        guard !busy, let p = currentIndex else { return }
        if let i = pages[p].regions.firstIndex(where: { $0.id == id }) {
            pages[p].regions[i].active.toggle()
        } else if let i = pages[p].keepAreas.firstIndex(where: { $0.id == id }) {
            pages[p].keepAreas[i].active.toggle()
        } else {
            return
        }
        changed(p)
    }

    /// Adds a drawn area: one to cover in cover mode, one to keep in keep mode.
    func addArea(_ region: MaskRegion) {
        guard !busy, let p = currentIndex else { return }
        switch style.mode {
        case .cover: pages[p].regions.append(region)
        case .keep: pages[p].keepAreas.append(region)
        }
        changed(p)
    }

    func toggleSubject(_ subjectID: Int) {
        guard !busy, let p = currentIndex,
              pages[p].analysis.result?.subjects.contains(where: { $0.id == subjectID }) == true
        else { return }
        if pages[p].kept.contains(subjectID) {
            pages[p].kept.remove(subjectID)
        } else {
            pages[p].kept.insert(subjectID)
        }
        changed(p)
    }

    /// Toggles the subject under a point given as fractions of the photo.
    func tapSubject(at point: CGPoint) {
        guard let subject = current?.analysis.result?.subject(at: point) else { return }
        toggleSubject(subject.id)
    }

    // MARK: - Style shared by every photo

    func setMode(_ mode: MaskMode) {
        guard !busy, mode != style.mode else { return }
        style.mode = mode
        styleChanged()
    }

    func setEffect(_ effect: MaskEffect) {
        guard !busy, effect != style.effect else { return }
        style.effect = effect
        styleChanged()
    }

    func setStrength(_ strength: MosaicStrength) {
        guard !busy, strength != style.strength else { return }
        style.strength = strength
        styleChanged()
    }

    private func styleChanged() {
        for index in pages.indices { pages[index].saved = false }
        refresh()
    }

    private func changed(_ index: Int) {
        pages[index].saved = false
        refresh()
    }

    // MARK: - Preview

    func refresh() {
        guard let page = current, !saving else { return }
        let ticket = UUID()
        revision = ticket
        previewTask?.cancel()
        let style = self.style
        if sourceID != page.id {
            source = nil
            sourceID = nil
        }
        if previewID != page.id {
            preview = nil
            previewID = nil
            overlay = nil
        }
        let cached = source
        rendering = true
        previewTask = Task {
            do {
                let image: CGImage
                if let cached {
                    image = cached
                } else {
                    let decoded = try await engine.previewSource(page.original)
                    guard ticket == revision else { return }
                    source = decoded
                    sourceID = page.id
                    image = decoded
                }
                var latest = page
                if style.mode == .keep && !page.analysis.hasRun {
                    await analyze(page.id, source: image)
                    guard ticket == revision, let updated = current, updated.id == page.id else { return }
                    latest = updated
                }
                let output = try await engine.render(image, plan: latest.plan(style))
                guard ticket == revision, !Task.isCancelled else { return }
                preview = output.image
                overlay = output.overlay
                previewID = page.id
                if style.mode == .keep, let index = currentIndex, pages[index].id == page.id {
                    pages[index].keepReviewed = true
                }
            } catch {
                guard ticket == revision, !Task.isCancelled else { return }
                notice = PhotoError.render.localizedDescription
            }
            if ticket == revision { rendering = false }
        }
    }

    private func cancelPreview() {
        revision = UUID()
        previewTask?.cancel()
        previewTask = nil
        rendering = false
    }

    /// Finds the subjects of a photo once. Concurrent callers share the same work.
    @discardableResult
    private func analyze(_ id: UUID, source: CGImage?) async -> SubjectAnalysis {
        guard let page = pages.first(where: { $0.id == id }) else { return .failed }
        if page.analysis.hasRun { return page.analysis }
        if let running = analysisTasks[id] {
            let result = await running.value
            store(result, for: id)
            return result
        }
        let faces = page.regions.filter { !$0.manual }.map(\.box)
        let original = page.original
        let engine = self.engine
        let task = Task<SubjectAnalysis, Never> {
            do {
                let image: CGImage
                if let source {
                    image = source
                } else {
                    image = try await engine.previewSource(original)
                }
                return await engine.subjects(in: image, faces: faces)
            } catch {
                return .failed
            }
        }
        analysisTasks[id] = task
        analyzing.insert(id)
        let result = await task.value
        store(result, for: id)
        return result
    }

    /// Every awaiter stores the result, so whichever resumes first already sees it in `pages`.
    private func store(_ result: SubjectAnalysis, for id: UUID) {
        analysisTasks[id] = nil
        analyzing.remove(id)
        if let index = pages.firstIndex(where: { $0.id == id }), !pages[index].analysis.hasRun {
            pages[index].analysis = result
            pages[index].kept = result.result?.defaultKept ?? []
        }
    }

    // MARK: - Saving

    func saveCurrent() async {
        guard canSaveCurrent, let id = currentID else { return }
        await save([id])
    }

    func saveAll() async {
        guard canSaveAll else { return }
        savingAll = true
        defer { savingAll = false }
        await save(pages.filter(isPending).map(\.id))
    }

    private func save(_ ids: [UUID]) async {
        saveProgress = BatchProgress(done: 0, total: ids.count)
        defer { saveProgress = nil }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            needsSettings = status == .denied
            notice = PhotoError.permission.localizedDescription
            return
        }
        let style = self.style
        var count = 0
        for id in ids {
            guard let page = pages.first(where: { $0.id == id }) else { continue }
            do {
                let data = try await engine.jpeg(page.original, plan: page.plan(style))
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = "모자이크-\(UUID().uuidString).jpg"
                    request.addResource(with: .photo, data: data, options: options)
                }
                if let index = pages.firstIndex(where: { $0.id == id }) { pages[index].saved = true }
                count += 1
                saveProgress?.done = count
            } catch {
                notice = count == 0
                    ? "사진을 저장하지 못했어요. 여유 공간을 확인한 뒤 다시 시도해 주세요."
                    : "\(count)장을 저장한 뒤 멈췄어요. 여유 공간을 확인한 뒤 남은 사진을 다시 저장해 주세요."
                break
            }
        }
        if count > 0 {
            UIAccessibility.post(notification: .announcement,
                                 argument: count == 1 ? "새 사진을 저장했어요." : "새 사진 \(count)장을 저장했어요.")
        }
    }
}
