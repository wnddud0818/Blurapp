import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var editor = Editor()
    @State private var selections: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var replacing = true
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize
    private enum Tool: String, CaseIterable {
        case region = "영역", effect = "효과", save = "저장"
        var symbol: String {
            switch self {
            case .region: "viewfinder"
            case .effect: "circle.lefthalf.filled"
            case .save: "square.and.arrow.down"
            }
        }
    }

    @State private var tool = Tool.region
    @State private var confirmClose = false
    /// The full-screen area editor, while it is open.
    @State private var regionSession: RegionSession?
    @State private var cleanPreview = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            if let progress = editor.importProgress {
                ImportProgressView(progress: progress)
            } else if let page = editor.current {
                edit(page)
            } else {
                GeometryReader { geo in
                    WelcomeView(columns: usesColumns(geo.size), limit: Editor.selectionLimit,
                                choosePhoto: { choose(replacing: true) },
                                openSample: { Task { await editor.openSample() } })
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .preferredColorScheme(.light)
        .photosPicker(isPresented: $choosingPhotos, selection: $selections,
                      maxSelectionCount: pickerLimit, selectionBehavior: .ordered, matching: .images,
                      preferredItemEncoding: .current, photoLibrary: .shared())
        .fullScreenCover(item: $regionSession) { session in
            RegionEditor(editor: editor, session: session)
        }
        .task(id: selections) {
            guard !selections.isEmpty else { return }
            regionSession = nil
            cleanPreview = false
            await editor.load(selections, replacing: replacing)
            if !Task.isCancelled { selections = [] }
        }
        .onChange(of: editor.currentID) {
            regionSession = nil
            if editor.currentID == nil { tool = .region; cleanPreview = false }
        }
        .onChange(of: editor.style.mode) { regionSession = nil }
        .alert("알림", isPresented: Binding(
            get: { editor.notice != nil },
            set: { if !$0 { editor.notice = nil; editor.needsSettings = false } }
        )) {
            if editor.needsSettings {
                Button("설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            Button("확인", role: .cancel) { }
        } message: { Text(editor.notice ?? "") }
    }

    private func usesColumns(_ size: CGSize) -> Bool {
        size.width >= 620 && (widthClass == .regular || size.width > size.height) && !typeSize.isAccessibilitySize
    }

    private var pickerLimit: Int {
        replacing ? Editor.selectionLimit : max(1, Editor.selectionLimit - editor.pages.count)
    }

    private func choose(replacing: Bool) {
        self.replacing = replacing
        choosingPhotos = true
    }

    /// Opens the current photo full screen to draw, move, resize and delete areas until "완료".
    private func editAreas(focus: UUID? = nil) {
        guard let page = editor.current, !editor.busy else { return }
        regionSession = RegionSession(pageID: page.id, mode: editor.style.mode,
                                      areas: editor.editableAreas, focus: focus)
    }

    private func edit(_ page: PhotoPage) -> some View {
        GeometryReader { window in
            VStack(spacing: 0) {
                editorHeader
                if cleanPreview {
                    stage
                } else if #available(iOS 27.1, *),
                          window.reservedRegions(kind: .division).contains(where: \.isActive) {
                    ArrangementView {
                        stage
                    } secondary: {
                        controls(page)
                    }
                    .arrangementViewStyle(.split)
                } else if usesColumns(window.size) {
                    HStack(spacing: 0) {
                        stage
                        controls(page).frame(width: min(340, window.size.width * 0.40))
                    }
                } else if typeSize.isAccessibilitySize || window.size.height < 460 {
                    ScrollView {
                        VStack(spacing: 0) {
                            stage.frame(height: max(230, window.size.height * 0.45))
                            toolBar
                            toolContent(page)
                        }
                    }
                } else {
                    stage
                    controls(page).frame(height: min(300, window.size.height * 0.40))
                }
            }
        }
        .disabled(editor.saving)
        .confirmationDialog("편집 중인 사진을 모두 닫을까요?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("모두 닫기", role: .destructive) { editor.close() }
            Button("취소", role: .cancel) { }
        }
    }

    private var stage: some View {
        VStack(spacing: 0) {
            canvas
            previewControls
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .tint(.white)
            if editor.pages.count > 1 && !cleanPreview {
                strip.padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .background(Palette.ink, ignoresSafeAreaEdges: [])
    }

    private func controls(_ page: PhotoPage) -> some View {
        VStack(spacing: 0) {
            toolBar
            ScrollView { toolContent(page) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var toolBar: some View {
        HStack(spacing: 0) {
            ForEach(Tool.allCases, id: \.self) { item in
                Button {
                    tool = item
                } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(item == tool ? Palette.accent : Palette.secondary)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(item == tool ? Palette.accent : Palette.line)
                                .frame(height: item == tool ? 2 : 1)
                        }
                }
                .accessibilityIdentifier("tool-\(item.rawValue)")
                .accessibilityAddTraits(item == tool ? .isSelected : [])
            }
        }.buttonStyle(.plain)
    }

    private func toolContent(_ page: PhotoPage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            switch tool {
            case .region:
                modeSection
                targets(page)
            case .effect: effectSection
            case .save: saveSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var editorHeader: some View {
        HStack {
            Text("모자이크").font(.title2.weight(.black))
            Text("\((editor.currentIndex ?? 0) + 1) / \(editor.pages.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(Palette.secondary)
            Spacer()
            Menu {
                Button { choose(replacing: false) } label: {
                    Label("사진 추가", systemImage: "plus")
                }.disabled(!editor.canAddPhotos)
                Button { choose(replacing: true) } label: {
                    Label("새로 고르기", systemImage: "photo.on.rectangle")
                }
                Button(role: .destructive) { confirmClose = true } label: {
                    Label("모두 닫기", systemImage: "xmark")
                }
            } label: {
                Label("사진", systemImage: "photo.stack")
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }.accessibilityIdentifier("photos-menu")
        }
        .padding(.horizontal, 16)
    }

    private var strip: some View {
        PhotoStrip(editor: editor) { choose(replacing: false) }
    }

    private var previewControls: some View {
        HStack {
            Text(statusText).font(.subheadline.weight(.semibold))
            Spacer()
            Button { cleanPreview.toggle() } label: {
                Label(cleanPreview ? "편집 보기" : "결과 보기",
                      systemImage: cleanPreview ? "viewfinder" : "eye")
            }
            .font(.subheadline).frame(minHeight: 44)
        }
    }

    private var statusText: String {
        editor.style.mode == .keep ? "남긴 대상 \(editor.activeCount)개" : "가린 영역 \(editor.activeCount)개"
    }

    private var canvas: some View {
        PhotoCanvas(editor: editor, cleanPreview: cleanPreview, adjust: { editAreas(focus: $0) })
    }

    // MARK: - Mode and targets

    private var modeSection: some View {
        Picker("가리는 방식", selection: Binding(get: { editor.style.mode }, set: { editor.setMode($0) })) {
            ForEach(MaskMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private func targets(_ page: PhotoPage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(editor.style.mode == .keep ? "남길 대상" : "가릴 영역").font(.headline)
                Spacer()
                Button { editAreas() } label: {
                    Label("직접 추가", systemImage: "plus.viewfinder")
                        .font(.subheadline.weight(.semibold))
                }
            }
            switch editor.style.mode {
            case .cover: coverTargets(page)
            case .keep: keepTargets(page)
            }
        }
    }

    @ViewBuilder private func coverTargets(_ page: PhotoPage) -> some View {
        if page.regions.isEmpty {
            if !page.faces.isEmpty {
                hint("가릴 영역을 모두 지웠어요. ‘직접 추가’로 다시 그릴 수 있어요.")
            } else {
                hint(page.faceDetectionFailed ? "자동 감지가 어려운 사진이에요. ‘직접 추가’로 영역을 그려 주세요." :
                        "얼굴을 찾지 못했습니다. 직접 영역을 그려주세요.")
            }
        } else {
            hint("영역을 눌러 가림을 켜거나 끄세요. 길게 누르면 크기·위치를 고치거나 삭제할 수 있어요.")
            TargetChips(targets: coverChips(page), onValue: "가림", offValue: "원본", toggle: toggle,
                        adjust: { editAreas(focus: $0) }, remove: { editor.removeArea($0) })
        }
    }

    @ViewBuilder private func keepTargets(_ page: PhotoPage) -> some View {
        let subjects = page.analysis.result?.subjects ?? []
        if editor.analyzingCurrent || !page.analysis.hasRun {
            HStack(spacing: 8) {
                ProgressView()
                Text("사람과 물체를 찾고 있어요").font(.subheadline)
            }
            .foregroundStyle(Palette.secondary)
        } else if subjects.isEmpty && page.keepAreas.isEmpty {
            if case .failed = page.analysis {
                hint("사람이나 물체를 자동으로 찾지 못했어요. ‘직접 추가’로 남길 영역을 그려 주세요. 지금은 사진 전체가 가려져요.")
            } else {
                hint("찾은 사람이나 물체가 없어요. ‘직접 추가’로 남길 영역을 그려 주세요. 지금은 사진 전체가 가려져요.")
            }
        } else {
            hint("남길 대상을 사진이나 목록에서 누르세요. 고르지 않은 부분은 모두 가려져요."
                 + (page.keepAreas.isEmpty ? "" : " 직접 그린 영역은 길게 눌러 고치거나 삭제해요."))
        }
        if !subjects.isEmpty || !page.keepAreas.isEmpty {
            TargetChips(targets: keepChips(page, subjects: subjects), onValue: "남김", offValue: "가림", toggle: toggle,
                        adjust: { editAreas(focus: $0) }, remove: { editor.removeArea($0) })
        }
    }

    private func keepChips(_ page: PhotoPage, subjects: [Subject]) -> [Target] {
        var chips: [Target] = []
        for (index, subject) in subjects.enumerated() {
            chips.append(Target(kind: .subject(subject.id), name: "\(subject.person ? "사람" : "대상") \(index + 1)",
                                on: page.kept.contains(subject.id)))
        }
        for (index, area) in page.keepAreas.enumerated() {
            chips.append(Target(kind: .area(area.id), name: "영역 \(subjects.count + index + 1)", on: area.active))
        }
        return chips
    }

    private func coverChips(_ page: PhotoPage) -> [Target] {
        var chips: [Target] = []
        for (index, region) in page.regions.enumerated() {
            chips.append(Target(kind: .area(region.id), name: "\(region.manual ? "수동" : "얼굴") \(index + 1)",
                                on: region.active))
        }
        return chips
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Palette.secondary)
    }

    private func toggle(_ kind: Target.Kind) {
        switch kind {
        case .area(let id): editor.toggleArea(id)
        case .subject(let id): editor.toggleSubject(id)
        }
    }

    // MARK: - Effect

    private var effectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("가림 효과").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(MaskEffect.allCases) { effect in
                        let selected = editor.style.effect == effect
                        Button { editor.setEffect(effect) } label: {
                            VStack(spacing: 6) {
                                EffectSwatch(effect: effect)
                                    .frame(width: 60, height: 46)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(selected ? Palette.marker : Palette.line, lineWidth: selected ? 3 : 1))
                                Text(effect.rawValue)
                                    .font(.caption.weight(selected ? .bold : .regular))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(effect.rawValue)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            if editor.style.effect.usesStrength {
                Picker("강도", selection: Binding(get: { editor.style.strength }, set: { editor.setStrength($0) })) {
                    ForEach(MosaicStrength.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if editor.pages.count > 1 {
                Text("가리는 방식·효과·강도는 모든 사진에 똑같이 적용돼요.")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
        }
    }

    // MARK: - Saving

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editor.pages.count > 1 {
                Button {
                    Task { await editor.saveAll() }
                } label: {
                    PrimaryLabel(title: saveAllTitle,
                                 symbol: batchDone ? "checkmark.circle.fill" : "square.and.arrow.down.on.square")
                }
                .buttonStyle(.plain)
                .disabled(!editor.canSaveAll)
                .opacity(editor.canSaveAll || editor.savingAll || batchDone ? 1 : 0.5)
                Button {
                    Task { await editor.saveCurrent() }
                } label: {
                    Label(editor.saving && !editor.savingAll ? "저장하는 중…" : (currentSaved ? "이 사진은 저장됨" : "이 사진만 저장"),
                          systemImage: currentSaved ? "checkmark" : "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 15))
                        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Palette.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!editor.canSaveCurrent)
                .opacity(editor.canSaveCurrent || currentSaved ? 1 : 0.5)
            } else {
                Button {
                    Task { await editor.saveCurrent() }
                } label: {
                    PrimaryLabel(title: editor.saving ? "저장하는 중…" : (currentSaved ? "사진 앱에 저장됨" : "새 사진으로 저장"),
                                 symbol: currentSaved ? "checkmark.circle.fill" : "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .disabled(!editor.canSaveCurrent)
                .opacity(editor.canSaveCurrent || currentSaved ? 1 : 0.5)
            }
            if editor.pages.count > 1 && editor.unreviewedCount > 0 {
                Text("골라서 남기기에서는 열어서 남길 대상을 확인한 사진만 모두 저장에 들어가요. 아직 확인하지 않은 사진 \(editor.unreviewedCount)장")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink)
            }
            Text("원본 해상도의 최고 품질 JPEG로 저장합니다. 촬영 정보와 위치 정보도 함께 저장됩니다.")
                .font(.footnote).foregroundStyle(Palette.secondary)
        }
    }

    private var currentSaved: Bool { editor.current?.saved ?? false }
    private var savedCount: Int { editor.pages.filter(\.saved).count }
    /// Everything that can be saved right now has been saved.
    private var batchDone: Bool { editor.unsavedCount == 0 && savedCount > 0 }

    private var saveAllTitle: String {
        if editor.savingAll, let progress = editor.saveProgress {
            return "저장하는 중 \(progress.done)/\(progress.total)"
        }
        if editor.unsavedCount > 0 { return "모두 저장 · \(editor.unsavedCount)장" }
        if savedCount > 0 {
            return savedCount == editor.pages.count ? "모두 저장됨" : "\(savedCount)장 저장됨"
        }
        return editor.style.mode == .keep ? "사진을 열어 남길 대상을 확인해 주세요" : "가릴 영역을 먼저 골라 주세요"
    }
}

// MARK: - Pieces

private struct Target: Identifiable {
    enum Kind: Hashable {
        case area(UUID)
        case subject(Int)
    }

    let kind: Kind
    let name: String
    let on: Bool
    var id: Kind { kind }
}

private struct TargetChips: View {
    let targets: [Target]
    let onValue: String
    let offValue: String
    let toggle: (Target.Kind) -> Void
    /// Opens a face or drawn area in the full-screen editor.
    let adjust: (UUID) -> Void
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(targets) { target in
                    chip(target)
                }
            }
        }
    }

    /// Faces and drawn areas can also be resized or deleted from a long press. Subjects only switch.
    @ViewBuilder private func chip(_ target: Target) -> some View {
        let button = Button { toggle(target.kind) } label: {
            Label(target.name, systemImage: target.on ? "checkmark.circle.fill" : "circle")
                .font(.subheadline.weight(.medium)).padding(.horizontal, 13).padding(.vertical, 10)
                .background(target.on ? Palette.marker : Color.white, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(target.on ? onValue : offValue)
        if case .area(let id) = target.kind {
            button
                .contextMenu { AreaMenu(adjust: { adjust(id) }, remove: { remove(id) }) }
                .accessibilityAction(named: "크기·위치 조정") { adjust(id) }
                .accessibilityAction(named: "삭제") { remove(id) }
        } else {
            button
        }
    }
}

/// Thumbnails of the batch. Tap to edit, long-press to take a photo out.
private struct PhotoStrip: View {
    @ObservedObject var editor: Editor
    let add: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(editor.pages.enumerated()), id: \.element.id) { index, page in
                        let selected = page.id == editor.currentID
                        Button { editor.select(page.id) } label: {
                            Image(decorative: page.thumbnail, scale: 1).resizable().scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11)
                                    .strokeBorder(selected ? Palette.marker : Palette.line, lineWidth: selected ? 3 : 1))
                                .overlay(alignment: .bottomTrailing) {
                                    if page.saved {
                                        Image(systemName: "checkmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .font(.subheadline).foregroundStyle(Palette.ink, Palette.marker)
                                            .padding(3)
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 11))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { editor.remove(page.id) } label: {
                                Label("목록에서 빼기", systemImage: "minus.circle")
                            }
                        }
                        .accessibilityLabel("사진 \(index + 1)")
                        .accessibilityValue(page.saved ? "저장됨" : "")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .id(page.id)
                    }
                    if editor.canAddPhotos {
                        Button(action: add) {
                            Image(systemName: "plus")
                                .font(.title3.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11)
                                    .strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("사진 추가")
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: editor.currentID, initial: true) { old, id in
                guard let id else { return }
                if old == id {
                    // First appearance, for example after photos were added.
                    proxy.scrollTo(id, anchor: .center)
                } else {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

private struct ImportProgressView: View {
    let progress: BatchProgress

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .frame(maxWidth: 220)
            Text(progress.total > 1
                 ? "사진 \(min(progress.done + 1, progress.total))/\(progress.total) 준비 중"
                 : "사진을 준비하고 있어요")
                .font(.headline)
            Text("얼굴을 찾고 있어요").font(.subheadline).foregroundStyle(Palette.secondary)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}

/// A small drawing of what each effect looks like, so the choice doesn't depend on reading.
private struct EffectSwatch: View {
    let effect: MaskEffect

    private static let tones: [Color] = [0x242421, 0x555451, 0x82807B, 0xABAAA6, 0xE1DFD9, 0x9B9995].map { hex in
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }

    var body: some View {
        Canvas { context, size in
            let tones = Self.tones
            let bounds = CGRect(origin: .zero, size: size)
            switch effect {
            case .pixel:
                let columns = 5, rows = 4
                let w = size.width / CGFloat(columns), h = size.height / CGFloat(rows)
                for row in 0..<rows {
                    for column in 0..<columns {
                        let cell = CGRect(x: CGFloat(column) * w, y: CGFloat(row) * h, width: w + 0.5, height: h + 0.5)
                        context.fill(Path(cell), with: .color(tones[(row * 3 + column * 2 + row * column) % tones.count]))
                    }
                }
            case .hexagon:
                context.fill(Path(bounds), with: .color(tones[1]))
                let radius = size.height / 3.2
                let rowStep = radius * 1.732
                for column in 0..<6 {
                    for row in -1..<3 {
                        let x = CGFloat(column) * radius * 1.5
                        let y = CGFloat(row) * rowStep + (column % 2 == 0 ? 0 : rowStep / 2)
                        var hexagon = Path()
                        for corner in 0..<6 {
                            let angle = CGFloat(corner) * .pi / 3
                            let point = CGPoint(x: x + radius * cos(angle), y: y + radius * sin(angle))
                            if corner == 0 { hexagon.move(to: point) } else { hexagon.addLine(to: point) }
                        }
                        hexagon.closeSubpath()
                        context.fill(hexagon, with: .color(tones[(column * 2 + row + 3) % tones.count]))
                    }
                }
            case .crystal:
                let columns = 4, rows = 3
                let shifts: [CGFloat] = [0.22, -0.3, 0.26, -0.14, 0.31, -0.24, 0.12, -0.2, 0.18, 0.28, -0.1, 0.2]
                func corner(_ column: Int, _ row: Int) -> CGPoint {
                    let shift = shifts[(row * (columns + 1) + column) % shifts.count]
                    let dx = column > 0 && column < columns ? shift : 0
                    let dy = row > 0 && row < rows ? -shift : 0
                    return CGPoint(x: (CGFloat(column) + dx) * size.width / CGFloat(columns),
                                   y: (CGFloat(row) + dy) * size.height / CGFloat(rows))
                }
                for row in 0..<rows {
                    for column in 0..<columns {
                        let a = corner(column, row), b = corner(column + 1, row)
                        let c = corner(column + 1, row + 1), d = corner(column, row + 1)
                        var upper = Path()
                        upper.addLines([a, b, c])
                        upper.closeSubpath()
                        var lower = Path()
                        lower.addLines([a, c, d])
                        lower.closeSubpath()
                        context.fill(upper, with: .color(tones[(row * 2 + column) % tones.count]))
                        context.fill(lower, with: .color(tones[(row + column * 3 + 2) % tones.count]))
                    }
                }
            case .blur:
                context.fill(Path(bounds), with: .color(tones[1]))
                context.addFilter(.blur(radius: 7))
                context.fill(Path(ellipseIn: CGRect(x: size.width * 0.18, y: size.height * 0.08,
                                                    width: size.width * 0.5, height: size.height * 0.75)),
                             with: .color(tones[4]))
                context.fill(Path(ellipseIn: CGRect(x: size.width * 0.55, y: size.height * 0.45,
                                                    width: size.width * 0.45, height: size.height * 0.5)),
                             with: .color(tones[0]))
            case .solid:
                context.fill(Path(bounds), with: .color(Color(white: 0.08)))
            }
        }
        .accessibilityHidden(true)
    }
}
