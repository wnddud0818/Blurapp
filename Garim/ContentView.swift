import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var editor = Editor()
    @State private var selection: PhotosPickerItem?
    @State private var choosingPhoto = false
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var drawing = false
    @State private var cleanPreview = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            if editor.loading {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("얼굴을 찾고 있어요").font(.headline)
                }
                .accessibilityElement(children: .combine)
            } else if let doc = editor.document {
                edit(doc)
            } else {
                WelcomeView(columns: usesColumns) { choosingPhoto = true }
            }
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.moss)
        .preferredColorScheme(.light)
        .photosPicker(isPresented: $choosingPhoto, selection: $selection, matching: .images,
                     preferredItemEncoding: .current, photoLibrary: .shared())
        .task(id: selection) {
            guard let item = selection else { return }
            drawing = false
            cleanPreview = false
            await editor.load(item)
            if !Task.isCancelled { selection = nil }
        }
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

    private var usesColumns: Bool {
        widthClass == .regular && !typeSize.isAccessibilitySize
    }

    private func edit(_ document: PhotoDocument) -> some View {
        GeometryReader { window in
            if usesColumns {
                VStack(alignment: .leading, spacing: 14) {
                    editorHeader
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 10) {
                            previewControls
                            canvas
                        }
                        Divider()
                        ScrollView {
                            inspector(document)
                        }
                        .frame(width: min(340, window.size.width * 0.36))
                    }
                }
                .padding(18)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            editorHeader
                            previewControls
                            canvas
                                .frame(height: max(180, window.size.height * 0.48))
                                .id("photoCanvas")
                            inspector(document)
                        }
                        .padding(16)
                    }
                    .onChange(of: drawing, initial: true) { _, active in
                        if active { scroll.scrollTo("photoCanvas", anchor: .center) }
                    }
                }
            }
        }
        .disabled(editor.saving)
    }

    private var editorHeader: some View {
        HStack {
            Text("얼굴 모자이크").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Spacer()
            Button { choosingPhoto = true } label: {
                Label("사진 바꾸기", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.semibold)).padding(.vertical, 9)
            }
        }
    }

    private var previewControls: some View {
        HStack {
            Text(drawing ? "가릴 부분을 드래그하세요" : "가린 영역 \(editor.coveredCount)개")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if drawing {
                Button("취소") { drawing = false }
            } else {
                Button { cleanPreview.toggle() } label: {
                    Label(cleanPreview ? "편집 보기" : "결과 보기",
                          systemImage: cleanPreview ? "viewfinder" : "eye")
                }
                .font(.subheadline)
            }
        }
    }

    private var canvas: some View {
        PhotoCanvas(editor: editor, drawing: $drawing, cleanPreview: cleanPreview)
    }

    private func inspector(_ document: PhotoDocument) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if !cleanPreview { tools(document) }
            Button {
                Task { await editor.save() }
            } label: {
                PrimaryLabel(title: editor.saving ? "저장하는 중…" : (editor.saved ? "사진 앱에 저장됨" : "새 사진으로 저장"),
                             symbol: editor.saved ? "checkmark.circle.fill" : "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .disabled(!editor.canSave || drawing)
            .opacity(editor.canSave && !drawing || editor.saved ? 1 : 0.5)
            Text("JPEG · 긴 변 최대 4,096픽셀")
                .font(.footnote).foregroundStyle(Palette.moss)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func tools(_ document: PhotoDocument) -> some View {
        HStack {
            Text("가릴 영역").font(.headline)
            Spacer()
            Button {
                drawing.toggle()
            } label: {
                Label(drawing ? "그리기 취소" : "직접 추가",
                      systemImage: drawing ? "xmark" : "plus.viewfinder")
                    .font(.subheadline.weight(.semibold))
            }
        }
        if editor.regions.isEmpty {
            Text(document.detectionFailed ? "자동 감지가 어려운 사진이에요. ‘직접 추가’로 영역을 그려 주세요." :
                   "찾은 얼굴이 없어요. ‘직접 추가’로 원하는 부분을 가릴 수 있어요.")
                .font(.subheadline).foregroundStyle(Palette.moss)
        } else {
            Text("남길 얼굴을 누르면 모자이크가 풀려요.").font(.subheadline)
                .foregroundStyle(Palette.moss)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Array(editor.regions.enumerated()), id: \.element.id) { index, region in
                        let name = "\(region.manual ? "수동" : "얼굴") \(index + 1)"
                        Button { editor.toggle(region.id) } label: {
                            Label(name, systemImage: region.covered ? "checkmark.circle.fill" : "circle")
                                .font(.subheadline.weight(.medium)).padding(.horizontal, 13).padding(.vertical, 10)
                                .background(region.covered ? Palette.lime : Color.white, in: Capsule())
                        }
                        .buttonStyle(.plain).accessibilityValue(region.covered ? "가림" : "원본")
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("모자이크 강도").font(.headline)
            Picker("모자이크 강도", selection: Binding(get: { editor.strength }, set: { editor.setStrength($0) })) {
                ForEach(MosaicStrength.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

struct Brand: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "squareshape.split.3x3")
                .font(.headline.bold()).foregroundStyle(Palette.lime)
                .frame(width: 32, height: 32).background(Palette.ink, in: RoundedRectangle(cornerRadius: 9))
            Text("가림").font(.title3.weight(.heavy))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PhotoCanvas: View {
    @ObservedObject var editor: Editor
    @Binding var drawing: Bool
    let cleanPreview: Bool

    var body: some View {
        GeometryReader { geo in
            if let document = editor.document {
                let source = document.previewSource
                let scale = min(geo.size.width / CGFloat(source.width), geo.size.height / CGFloat(source.height))
                let size = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
                ZStack {
                    Palette.ink
                    ZStack(alignment: .topLeading) {
                        if let preview = editor.preview {
                            Image(decorative: preview, scale: 1).resizable()
                                .frame(width: size.width, height: size.height)
                        }
                        if !cleanPreview && !drawing && editor.preview != nil {
                            ForEach(Array(editor.regions.enumerated()), id: \.element.id) { index, region in
                                let rect = region.displayRect(in: size)
                                Button { editor.toggle(region.id) } label: {
                                    ZStack(alignment: .topLeading) {
                                        Rectangle().fill(Color.clear)
                                        Rectangle().strokeBorder(region.covered ? Palette.lime : .white,
                                            style: StrokeStyle(lineWidth: 2, dash: region.covered ? [] : [5, 3]))
                                        if rect.width >= 22 && rect.height >= 22 {
                                            Text("\(index + 1)").font(.caption2.bold()).monospacedDigit()
                                                .foregroundStyle(Palette.ink).padding(3)
                                                .background(region.covered ? Palette.lime : .white)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .accessibilityLabel("영역 \(index + 1)")
                                .accessibilityValue(region.covered ? "가림" : "원본")
                            }
                        }
                        if drawing {
                            ManualMaskOverlay(imageSize: size) { region in
                                editor.add(region)
                                drawing = false
                            }
                            // Touch locations belong to this image size for the entire stroke.
                            .id([size.width, size.height])
                        }
                    }
                    .frame(width: size.width, height: size.height).clipped()
                    if editor.rendering {
                        ProgressView().tint(.white).accessibilityLabel("모자이크 적용 중")
                    } else if editor.preview == nil {
                        Button("미리보기 다시 만들기") { editor.refresh() }.buttonStyle(.borderedProminent)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

private struct ManualMaskOverlay: View {
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
