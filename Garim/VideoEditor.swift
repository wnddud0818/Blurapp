import AVKit
import CoreTransferable
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct VideoImport: Identifiable {
    let id = UUID()
    let item: PhotosPickerItem
}

private struct PickedMovie: Transferable {
    let file: MovieFile

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let file = MovieFile(extension: received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: file.url)
            return Self(file: file)
        }
    }
}

struct VideoEditor: View {
    let input: VideoImport
    @Environment(\.dismiss) private var dismiss
    @State private var source: MovieSource?
    @State private var mode = VideoMaskMode.faces
    @State private var seconds = 0.0
    @State private var frameRequest = UUID()
    @State private var frame: VideoSelectionFrame?
    @State private var selection: Int?
    @State private var progress: Double?
    @State private var rendering: Task<Void, Never>?
    @State private var result: RenderedMovie?
    @State private var player: AVPlayer?
    @State private var saving = false
    @State private var saved = false
    @State private var problem: String?
    @State private var importFailed = false
    @State private var frameFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let player, let result {
                        VideoPlayer(player: player)
                            .aspectRatio(frameAspect, contentMode: .fit)
                            .accessibilityLabel("모자이크 결과 영상")
                        if let interval = result.partialTrack {
                            Text("인물을 추적한 구간은 \(interval.lowerBound, specifier: "%.1f")~\(interval.upperBound, specifier: "%.1f")초예요. 그 밖의 구간에서는 선택한 인물도 가림 대상으로 처리해요.")
                                .font(.subheadline)
                        }
                        Button { Task { await save(result.file) } } label: {
                            PrimaryLabel(title: saved ? "사진 앱에 저장됨" : "새 동영상으로 저장",
                                         symbol: saved ? "checkmark" : "square.and.arrow.down")
                        }
                        .buttonStyle(.plain)
                        .disabled(saving || saved)
                        Button("선택 다시 편집") { clearResult() }.disabled(saving)
                    } else if let source {
                        controls(source)
                    } else if importFailed {
                        Text("영상을 가져오지 못했어요. 닫고 다른 동영상을 선택해 주세요.")
                    } else {
                        ProgressView("동영상 불러오는 중")
                    }
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("동영상 모자이크")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }.disabled(saving)
                }
            }
            .background(Palette.paper)
        }
        .task {
            do {
                guard let movie = try await input.item.loadTransferable(type: PickedMovie.self) else {
                    throw VideoError.unreadable
                }
                let loaded = try await MovieSource(file: movie.file)
                try Task.checkCancellation()
                seconds = loaded.range.start.seconds
                source = loaded
                reloadFrame()
            } catch {
                if !Task.isCancelled { importFailed = true; problem = error.localizedDescription }
            }
        }
        .task(id: frameRequest) {
            guard let source else { return }
            do {
                let loaded = try await source.frame(at: seconds, mode: mode)
                try Task.checkCancellation()
                frame = loaded
            } catch {
                if !Task.isCancelled { frameFailed = true; problem = error.localizedDescription }
            }
        }
        .onDisappear { rendering?.cancel(); player?.pause() }
        .alert("알림", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("확인") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    private var frameAspect: CGFloat {
        guard let frame else { return 16.0 / 9 }
        return CGFloat(frame.image.width) / CGFloat(frame.image.height)
    }

    @ViewBuilder
    private func controls(_ source: MovieSource) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("가리는 방식", selection: $mode) {
                ForEach(VideoMaskMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { reloadFrame() }
            Text(mode == .faces ? "남길 얼굴을 선택하세요. 다른 얼굴에 모자이크를 적용해요."
                                : "남길 사람을 선택하세요. 그 사람의 윤곽 밖을 모두 가려요.")
                .font(.subheadline)
            if let frame {
                Image(decorative: frame.image, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
                    .overlay {
                        GeometryReader { geo in
                            ForEach(frame.boxes.indices, id: \.self) { index in
                                let box = frame.boxes[index]
                                let color: Color = selection == index ? .yellow : .white
                                Button { selection = index } label: {
                                    Rectangle().strokeBorder(color, lineWidth: 3)
                                        .overlay(alignment: .topLeading) {
                                            Text("\(index + 1)").font(.caption.bold())
                                                .padding(3).foregroundStyle(.black).background(color)
                                        }
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("인물 \(index + 1)")
                                .frame(width: box.width * geo.size.width, height: box.height * geo.size.height)
                                .position(x: box.midX * geo.size.width, y: (1 - box.midY) * geo.size.height)
                            }
                        }
                    }
                if frame.boxes.isEmpty {
                    Text("이 장면에서 대상을 찾지 못했어요. 다른 시점을 골라 주세요.")
                } else {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(frame.boxes.indices, id: \.self) { index in
                                Button("인물 \(index + 1)") { selection = index }
                                    .buttonStyle(.bordered)
                                    .tint(selection == index ? Palette.accent : Palette.secondary)
                                    .accessibilityAddTraits(selection == index ? .isSelected : [])
                            }
                        }
                    }
                }
            } else if frameFailed {
                Text("이 장면을 분석하지 못했어요. 다른 시점이나 가리는 방식을 선택해 주세요.")
                Button("장면 다시 분석") { reloadFrame() }
            } else {
                ProgressView("장면 분석 중").frame(maxWidth: .infinity, minHeight: 120)
            }
            let start = source.range.start.seconds
            let end = max(start, source.range.end.seconds - 0.001)
            if end > start {
                Text("인물 선택 시점  \(seconds - start, specifier: "%.1f")초")
                    .font(.subheadline.monospacedDigit())
                Slider(value: $seconds, in: start...end, onEditingChanged: { editing in
                    if !editing { reloadFrame() }
                })
                .accessibilityLabel("인물 선택 시점")
            }
        }
        .disabled(progress != nil)
        if let progress {
            ProgressView(value: progress) {
                Text(progress < 0.3 ? "선택한 인물 추적 중" : "모자이크 영상 만드는 중")
            }
            Button("작업 취소") { rendering?.cancel() }
        } else {
            Button {
                guard let frame, let selection else { return }
                render(source, frame: frame, box: frame.boxes[selection])
            } label: {
                PrimaryLabel(title: "결과 영상 만들기", symbol: "play.rectangle")
            }
            .buttonStyle(.plain)
            .disabled(selection == nil || frame == nil)
        }
    }

    private func reloadFrame() {
        frameFailed = false
        frame = nil
        selection = nil
        frameRequest = UUID()
    }

    private func clearResult() {
        player?.pause()
        player = nil
        result = nil
        saved = false
    }

    private func render(_ source: MovieSource, frame: VideoSelectionFrame, box: CGRect) {
        guard progress == nil else { return }
        progress = 0
        let mode = self.mode
        rendering = Task { @MainActor in
            defer { progress = nil; rendering = nil }
            do {
                let rendered = try await VideoRenderer.render(source, frame: frame, box: box, mode: mode) { value in
                    await MainActor.run { if progress != nil { progress = value } }
                }
                try Task.checkCancellation()
                result = rendered
                player = AVPlayer(url: rendered.file.url)
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
            }
        }
    }

    @MainActor private func save(_ file: MovieFile) async {
        guard !saving, !saved else { return }
        saving = true
        defer { saving = false }
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { throw VideoError.permission }
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: file.url, options: nil)
            }
            saved = true
        } catch {
            problem = error.localizedDescription
        }
    }
}
