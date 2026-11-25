import SwiftUI

/// One visit to the full-screen area editor. The editor works on a copy of the areas and stores it
/// only with "완료".
struct RegionSession: Identifiable {
    let id = UUID()
    let pageID: UUID
    let mode: MaskMode
    /// Faces and drawn areas to cover in cover mode, drawn areas to keep in keep mode.
    let areas: [MaskRegion]
    /// The area to select first, when the editor opens from an area's menu.
    var focus: UUID?
}

/// Fits the photo into the editing canvas and decides what a touch grabs. Points are canvas points.
struct RegionLayout {
    /// The smallest comfortable touch target.
    static let reach: CGFloat = 44
    /// A finger that moves less than this has tapped.
    static let tapSlop: CGFloat = 8
    /// How far handles stay inside the canvas edge, so each one can be seen and touched.
    static let handleMargin: CGFloat = 12

    /// The whole canvas.
    let bounds: CGRect
    /// The fitted photo.
    let frame: CGRect

    init(photo pixels: CGSize, in canvas: CGSize) {
        bounds = CGRect(origin: .zero, size: canvas)
        let scale = min(canvas.width / max(pixels.width, 1), canvas.height / max(pixels.height, 1))
        let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        frame = CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                       width: size.width, height: size.height)
    }

    static func isTap(_ translation: CGSize) -> Bool {
        (translation.width * translation.width + translation.height * translation.height).squareRoot() < tapSlop
    }

    /// The smallest area a corner drag leaves, as fractions of the photo.
    var minimum: CGSize {
        CGSize(width: MaskRegion.minimumSide / max(frame.width, 1),
               height: MaskRegion.minimumSide / max(frame.height, 1))
    }

    func rect(_ box: CGRect) -> CGRect {
        CGRect(x: frame.minX + box.minX * frame.width, y: frame.minY + box.minY * frame.height,
               width: box.width * frame.width, height: box.height * frame.height)
    }

    /// A canvas point measured from the photo's top left corner.
    func photoPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    /// A drag across the canvas as fractions of the photo.
    func fraction(_ translation: CGSize) -> CGVector {
        CGVector(dx: translation.width / max(frame.width, 1), dy: translation.height / max(frame.height, 1))
    }

    struct Handle {
        let corner: MaskRegion.Corner
        let point: CGPoint
    }

    /// How far the handles of an area sit outside its corners. A small area's handles move apart so that
    /// each corner and the middle keep room for a finger.
    func handleOutset(for box: CGRect) -> CGSize {
        let area = rect(box)
        let spread = Self.reach * 1.5
        return CGSize(width: max(0, (spread - area.width) / 2), height: max(0, (spread - area.height) / 2))
    }

    /// The corner handles of a selected area, kept inside the canvas. During a drag the caller passes the
    /// outset from touch-down, so the held corner stays under the finger.
    func handles(for box: CGRect, outset: CGSize? = nil) -> [Handle] {
        let spread = outset ?? handleOutset(for: box)
        let outer = rect(box).insetBy(dx: -spread.width, dy: -spread.height)
        let inside = bounds.insetBy(dx: Self.handleMargin, dy: Self.handleMargin)
        return MaskRegion.Corner.allCases.map { corner -> Handle in
            var point = CGPoint(x: corner.isLeft ? outer.minX : outer.maxX, y: corner.isTop ? outer.minY : outer.maxY)
            if !inside.isNull {
                point.x = min(max(point.x, inside.minX), inside.maxX)
                point.y = min(max(point.y, inside.minY), inside.maxY)
            }
            return Handle(corner: corner, point: point)
        }
    }

    /// Where an area answers to a touch: the area itself, grown to at least `reach` on each side.
    func target(for box: CGRect) -> CGRect {
        let area = rect(box)
        return area.insetBy(dx: min(0, (area.width - Self.reach) / 2), dy: min(0, (area.height - Self.reach) / 2))
    }

    enum Grab: Equatable {
        /// Resizes the selected area from one corner.
        case corner(UUID, MaskRegion.Corner)
        /// Selects an area, or moves it.
        case area(UUID)
        /// Draws a new area, or clears the selection with a tap.
        case empty

        func holds(_ id: UUID) -> Bool {
            switch self {
            case .corner(let held, _), .area(let held): return held == id
            case .empty: return false
            }
        }
    }

    func grab(at point: CGPoint, areas: [MaskRegion], selected: UUID?) -> Grab {
        if let selected, let area = areas.first(where: { $0.id == selected }) {
            let nearest = handles(for: area.box).min { distance($0.point, point) < distance($1.point, point) }
            if let nearest, distance(nearest.point, point) <= Self.reach / 2 {
                return .corner(selected, nearest.corner)
            }
        }
        // The smallest area under the finger wins, so a face inside a large drawn area stays reachable.
        let hit = areas.filter { target(for: $0.box).contains(point) }
            .min { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
        if let hit { return .area(hit.id) }
        return .empty
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}

/// A finger on the editing canvas, from touch-down to now.
private struct RegionStroke {
    let start: CGPoint
    var location: CGPoint
    /// What the finger took hold of when it touched down.
    let grab: RegionLayout.Grab
    /// The finger went further than a tap at some point. From then on this is a drag, even if the finger
    /// comes back close to where it started.
    var moved = false

    init(start: CGPoint, grab: RegionLayout.Grab) {
        self.start = start
        location = start
        self.grab = grab
    }

    var translation: CGSize { CGSize(width: location.x - start.x, height: location.y - start.y) }

    mutating func follow(_ point: CGPoint) {
        location = point
        if !RegionLayout.isTap(translation) { moved = true }
    }
}

/// Full-screen editor for the areas of one photo. Dragging over an empty spot draws a new area, as many
/// times as needed. Touching an area selects it; then dragging inside moves it, dragging a corner resizes
/// it, and "삭제" removes it. "완료" stores the result, "취소" leaves the photo as it was.
struct RegionEditor: View {
    @ObservedObject var editor: Editor
    let session: RegionSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [MaskRegion]
    @State private var selection: UUID?
    @State private var confirmDiscard = false
    @GestureState private var stroke: RegionStroke?
    /// Touch-down point of the current stroke once it turned into a drag. `stroke` resets when the
    /// gesture ends, so the end handler keeps its own record.
    @State private var travelled: CGPoint?

    init(editor: Editor, session: RegionSession) {
        _editor = ObservedObject(wrappedValue: editor)
        self.session = session
        _draft = State(initialValue: session.areas)
        _selection = State(initialValue: session.areas.contains(where: { $0.id == session.focus }) ? session.focus : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                canvas(RegionLayout(photo: page?.size ?? .zero, in: geo.size))
            }
            .background(Palette.ink)
            .clipped()
            footer
        }
        .background(Palette.paper)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .sensoryFeedback(.selection, trigger: selection)
        .confirmationDialog("고친 내용을 버릴까요?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("버리기", role: .destructive) { dismiss() }
            Button("계속 고치기", role: .cancel) { }
        }
    }

    private var page: PhotoPage? { editor.pages.first { $0.id == session.pageID } }

    /// Keep areas are numbered after the subjects, as in the list under the photo.
    private var numberOffset: Int {
        session.mode == .keep ? (page?.analysis.result?.subjects.count ?? 0) : 0
    }

    private var header: some View {
        ZStack {
            Text(session.mode == .keep ? "남길 영역" : "가릴 영역").font(.headline)
            HStack {
                Button("취소") { cancel() }
                Spacer()
                Button { finish() } label: { Text("완료").bold() }
            }
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// Keeps one height whether or not an area is selected, so the photo above never shifts.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("영역 \(draft.count)개").font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("region-count")
                Spacer()
                Button(role: .destructive) {
                    if let id = selection { remove(id) }
                } label: {
                    Label("삭제", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(Color.white, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
                .opacity(selection == nil ? 0 : 1)
                .disabled(selection == nil)
                .accessibilityHidden(selection == nil)
            }
            // Both hints take up space and only one shows.
            ZStack(alignment: .topLeading) {
                Text(drawHint)
                    .opacity(selection == nil ? 1 : 0)
                    .accessibilityHidden(selection != nil)
                Text(editHint)
                    .opacity(selection == nil ? 0 : 1)
                    .accessibilityHidden(selection == nil)
            }
            .font(.footnote).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var drawHint: String {
        session.mode == .keep
            ? "빈 곳을 드래그해 남길 영역을 그리세요. 영역을 누르면 크기와 위치를 고칠 수 있어요."
            : "빈 곳을 드래그해 가릴 영역을 그리세요. 영역을 누르면 크기와 위치를 고칠 수 있어요."
    }

    private var editHint: String {
        "모서리를 끌면 크기가, 안쪽을 끌면 위치가 바뀌어요. 빈 곳을 누르면 선택이 풀려요."
    }

    // MARK: - Canvas

    private func canvas(_ layout: RegionLayout) -> some View {
        let areas = draft
        let selected = selection
        let first = numberOffset + 1
        return ZStack(alignment: .topLeading) {
            photo(layout)
            if session.mode == .keep, let overlay = editor.overlay {
                Image(decorative: overlay, scale: 1).resizable().interpolation(.medium)
                    .frame(width: layout.frame.width, height: layout.frame.height)
                    .position(x: layout.frame.midX, y: layout.frame.midY)
                    .allowsHitTesting(false)
            }
            ForEach(Array(areas.enumerated()), id: \.element.id) { index, area in
                outline(area, number: first + index, layout: layout)
            }
            sketch(layout)
            handles(layout)
            // One gesture decides at touch-down whether the finger resizes, moves or draws.
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($stroke) { value, state, _ in
                        if state == nil {
                            state = RegionStroke(start: value.startLocation,
                                                 grab: layout.grab(at: value.startLocation, areas: areas,
                                                                   selected: selected))
                        }
                        state?.follow(value.location)
                    }
                    .onChanged { value in
                        if travelled != value.startLocation && !RegionLayout.isTap(value.translation) {
                            travelled = value.startLocation
                        }
                    }
                    .onEnded { value in
                        let moved = travelled == value.startLocation || !RegionLayout.isTap(value.translation)
                        travelled = nil
                        endStroke(value, moved: moved, layout: layout)
                    })
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func photo(_ layout: RegionLayout) -> some View {
        let source = editor.currentID == session.pageID ? editor.currentSource : nil
        Group {
            if let source {
                Image(source, scale: 1, label: Text("사진")).resizable()
            } else if let page = page {
                // The thumbnail holds the place while the photo is decoded.
                Image(page.thumbnail, scale: 1, label: Text("사진")).resizable()
                    .blur(radius: 8).opacity(0.55)
            }
        }
        .frame(width: layout.frame.width, height: layout.frame.height)
        .position(x: layout.frame.midX, y: layout.frame.midY)
        .allowsHitTesting(false)
        .accessibilityIdentifier("region-photo")
        .accessibilityAction(named: "가운데에 영역 추가") { addCentered() }
        if source == nil {
            ProgressView().tint(.white)
                .position(x: layout.frame.midX, y: layout.frame.midY)
                .allowsHitTesting(false)
        }
    }

    private func outline(_ area: MaskRegion, number: Int, layout: RegionLayout) -> some View {
        let rect = layout.rect(liveBox(area, layout: layout))
        let focused = area.id == selection || stroke?.grab.holds(area.id) == true
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(area.active ? Palette.marker.opacity(0.22) : Color.clear)
            Rectangle().strokeBorder(area.active ? Palette.marker : .white,
                                     style: StrokeStyle(lineWidth: focused ? 3 : 2, dash: area.active ? [] : [5, 3]))
            if rect.width >= 22 && rect.height >= 22 {
                Text("\(number)").font(.caption2.bold()).monospacedDigit()
                    .foregroundStyle(Palette.ink).padding(3)
                    .background(area.active ? Palette.marker : .white)
            }
        }
        .frame(width: max(rect.width, 2), height: max(rect.height, 2))
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("영역 \(number)")
        .accessibilityValue(stateName(area))
        .accessibilityAddTraits(area.id == selection ? .isSelected : [])
        .accessibilityAction { selection = area.id }
        .accessibilityAction(named: "삭제") { remove(area.id) }
    }

    /// The rectangle being drawn.
    @ViewBuilder private func sketch(_ layout: RegionLayout) -> some View {
        if let stroke = stroke, stroke.grab == .empty, stroke.moved {
            let rect = CGRect(x: min(stroke.start.x, stroke.location.x), y: min(stroke.start.y, stroke.location.y),
                              width: abs(stroke.location.x - stroke.start.x),
                              height: abs(stroke.location.y - stroke.start.y))
                .intersection(layout.frame)
            if !rect.isNull {
                Rectangle().fill(Palette.marker.opacity(0.3))
                    .overlay(Rectangle().strokeBorder(Palette.marker, lineWidth: 2))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private func handles(_ layout: RegionLayout) -> some View {
        if let id = selection, let area = draft.first(where: { $0.id == id }) {
            // `area.box` is where the area was at touch-down, so the spacing holds for the whole drag.
            let outset = layout.handleOutset(for: area.box)
            ForEach(layout.handles(for: liveBox(area, layout: layout), outset: outset), id: \.corner) { handle in
                Circle().fill(Color.white)
                    .overlay(Circle().strokeBorder(Palette.marker, lineWidth: 3))
                    .frame(width: 18, height: 18)
                    .position(handle.point)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Where an area is drawn while a finger moves or resizes it. A tap leaves it where it is, the same
    /// rule `endStroke` uses, so what the finger shows is what gets stored.
    private func liveBox(_ area: MaskRegion, layout: RegionLayout) -> CGRect {
        guard let stroke = stroke, stroke.moved else { return area.box }
        let offset = layout.fraction(stroke.translation)
        switch stroke.grab {
        case .area(let id) where id == area.id:
            return MaskRegion.move(area.box, by: offset)
        case .corner(let id, let corner) where id == area.id:
            return MaskRegion.resize(area.box, dragging: corner, by: offset, minimum: layout.minimum)
        default:
            return area.box
        }
    }

    private func stateName(_ area: MaskRegion) -> String {
        switch session.mode {
        case .cover: return area.active ? "가림" : "원본"
        case .keep: return area.active ? "남김" : "가림"
        }
    }

    // MARK: - Editing

    /// `moved` is false for a tap, which only selects or clears the selection.
    private func endStroke(_ value: DragGesture.Value, moved: Bool, layout: RegionLayout) {
        // Nothing changes during a stroke, so the touch-down point grabs the same thing again.
        let grab = layout.grab(at: value.startLocation, areas: draft, selected: selection)
        let offset = layout.fraction(value.translation)
        switch grab {
        case .corner(let id, let corner):
            guard moved, let index = draft.firstIndex(where: { $0.id == id }) else { return }
            draft[index].box = MaskRegion.resize(draft[index].box, dragging: corner, by: offset, minimum: layout.minimum)
        case .area(let id):
            selection = id
            guard moved, let index = draft.firstIndex(where: { $0.id == id }) else { return }
            draft[index].box = MaskRegion.move(draft[index].box, by: offset)
        case .empty:
            guard moved else {
                selection = nil
                return
            }
            if let region = MaskRegion.drawn(from: layout.photoPoint(value.startLocation),
                                             to: layout.photoPoint(value.location), in: layout.frame.size) {
                draft.append(region)
                selection = region.id
            }
        }
    }

    private func remove(_ id: UUID) {
        draft.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    /// VoiceOver can't draw, so it adds an area in the middle of the photo instead.
    private func addCentered() {
        var box = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        // Step aside from earlier ones so repeated adds don't hide each other.
        while draft.contains(where: { $0.box == box }), box.maxX < 0.95 {
            box = box.offsetBy(dx: 0.05, dy: 0.05)
        }
        let region = MaskRegion(box: box, manual: true)
        draft.append(region)
        selection = region.id
    }

    private func cancel() {
        if draft == session.areas {
            dismiss()
        } else {
            confirmDiscard = true
        }
    }

    private func finish() {
        editor.setAreas(draft, page: session.pageID, mode: session.mode)
        dismiss()
    }
}

/// The long-press actions of a face or drawn area.
struct AreaMenu: View {
    let adjust: () -> Void
    let remove: () -> Void

    var body: some View {
        Button(action: adjust) {
            Label("크기·위치 조정", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        Button(role: .destructive, action: remove) {
            Label("삭제", systemImage: "trash")
        }
    }
}
