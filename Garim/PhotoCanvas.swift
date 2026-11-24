import SwiftUI

struct PhotoCanvas: View {
    @ObservedObject var editor: Editor
    @Binding var drawing: Bool
    let cleanPreview: Bool

    var body: some View {
        GeometryReader { geo in
            if let page = editor.current {
                let pixels = page.size
                let scale = min(geo.size.width / max(pixels.width, 1), geo.size.height / max(pixels.height, 1))
                let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
                ZStack {
                    Palette.ink
                    ZStack(alignment: .topLeading) {
                        if let preview = editor.preview {
                            Image(decorative: preview, scale: 1).resizable()
                                .frame(width: size.width, height: size.height)
                        } else {
                            // The thumbnail holds the place while the photo is decoded.
                            Image(decorative: page.thumbnail, scale: 1).resizable()
                                .frame(width: size.width, height: size.height)
                                .blur(radius: 8).opacity(0.55)
                        }
                        if !cleanPreview && !drawing && editor.preview != nil {
                            switch editor.style.mode {
                            case .cover: coverMarks(page, size: size)
                            case .keep: keepMarks(page, size: size)
                            }
                        }
                        if drawing {
                            ManualMaskOverlay(imageSize: size) { region in
                                editor.addArea(region)
                                drawing = false
                            }
                            // Touch locations belong to this image size for the entire stroke.
                            .id([size.width, size.height])
                        }
                    }
                    .frame(width: size.width, height: size.height).clipped()
                    if editor.rendering {
                        ProgressView().tint(.white)
                            .padding(12).background(Palette.ink.opacity(0.55), in: Circle())
                            .accessibilityLabel(editor.analyzingCurrent ? "사람과 물체를 찾는 중" : "가림 적용 중")
                    } else if editor.preview == nil {
                        Button("미리보기 다시 만들기") { editor.refresh() }.buttonStyle(.borderedProminent)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    @ViewBuilder private func coverMarks(_ page: PhotoPage, size: CGSize) -> some View {
        ForEach(Array(page.regions.enumerated()), id: \.element.id) { index, region in
            AreaMark(area: region, number: index + 1, size: size, onValue: "가림", offValue: "원본") {
                editor.toggleArea(region.id)
            }
        }
    }

    @ViewBuilder private func keepMarks(_ page: PhotoPage, size: CGSize) -> some View {
        let subjects = page.analysis.result?.subjects ?? []
        if let overlay = editor.overlay {
            Image(decorative: overlay, scale: 1).resizable().interpolation(.medium)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
        }
        if !subjects.isEmpty {
            Color.clear
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    editor.tapSubject(at: CGPoint(x: value.location.x / size.width,
                                                  y: value.location.y / size.height))
                })
                .accessibilityHidden(true)
        }
        ForEach(Array(subjects.enumerated()), id: \.element.id) { index, subject in
            let kept = page.kept.contains(subject.id)
            Text("\(index + 1)").font(.caption2.bold()).monospacedDigit()
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(kept ? Palette.lime : Color.white, in: Capsule())
                .position(x: subject.center.x * size.width, y: subject.center.y * size.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        ForEach(Array(page.keepAreas.enumerated()), id: \.element.id) { index, area in
            AreaMark(area: area, number: subjects.count + index + 1, size: size, onValue: "남김", offValue: "가림") {
                editor.toggleArea(area.id)
            }
        }
    }
}

/// A tappable outline of a face or drawn area.
private struct AreaMark: View {
    let area: MaskRegion
    let number: Int
    let size: CGSize
    let onValue: String
    let offValue: String
    let toggle: () -> Void

    var body: some View {
        let rect = area.displayRect(in: size)
        Button(action: toggle) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.clear)
                Rectangle().strokeBorder(area.active ? Palette.lime : .white,
                                         style: StrokeStyle(lineWidth: 2, dash: area.active ? [] : [5, 3]))
                if rect.width >= 22 && rect.height >= 22 {
                    Text("\(number)").font(.caption2.bold()).monospacedDigit()
                        .foregroundStyle(Palette.ink).padding(3)
                        .background(area.active ? Palette.lime : .white)
                }
            }
            .contentShape(Rectangle())
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .accessibilityLabel("영역 \(number)")
        .accessibilityValue(area.active ? onValue : offValue)
    }
}

struct ManualMaskOverlay: View {
    let imageSize: CGSize
    let add: (MaskRegion) -> Void
    @GestureState private var draft: CGRect?

    var body: some View {
        Color.clear.contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if let draft {
                    Rectangle().fill(Palette.lime.opacity(0.3))
                        .overlay(Rectangle().strokeBorder(Palette.lime, lineWidth: 2))
                        .frame(width: draft.width, height: draft.height)
                        .position(x: draft.midX, y: draft.midY)
                        .allowsHitTesting(false)
                }
            }
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($draft) { value, rect, _ in
                    rect = CGRect(x: value.startLocation.x, y: value.startLocation.y,
                                  width: value.translation.width, height: value.translation.height).standardized
                }
                .onEnded { value in
                    if let region = MaskRegion.drawn(from: value.startLocation, to: value.location, in: imageSize) {
                        add(region)
                    }
                })
    }
}
