import SwiftUI

/// Cropped from the Library of Congress negative fsa.8b27245.
enum FieldStudy {
    static let data = NSDataAsset(name: "FieldStudy")?.data
    static let image = data.flatMap { UIImage(data: $0) }
    static let plate = CGRect(x: 0.635, y: 0.69, width: 0.09, height: 0.07)
}

struct WelcomeView: View {
    let columns: Bool
    let limit: Int
    let choosePhoto: () -> Void
    let openSample: () -> Void
    @State private var masked = true
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 68

    var body: some View {
        GeometryReader { window in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .lastTextBaseline) {
                        Text("모자이크").font(.system(size: titleSize, weight: .black)).tracking(-4)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text("사진 편집기").font(.subheadline.weight(.medium))
                    }
                    Rectangle().frame(height: 2)
                    if columns {
                        HStack(alignment: .center, spacing: 26) {
                            example
                            actions.frame(width: max(200, window.size.width * 0.31))
                        }
                    } else {
                        example
                        Spacer(minLength: 8)
                        actions
                    }
                }
                .padding(24)
                .frame(minHeight: window.size.height, alignment: .center)
                .frame(maxWidth: 1040)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var example: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = FieldStudy.image {
                Button { masked.toggle() } label: {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { proxy in
                                if masked {
                                    let plate = FieldStudy.plate
                                    Rectangle().fill(.black)
                                        .frame(width: proxy.size.width * plate.width, height: proxy.size.height * plate.height)
                                        .position(x: proxy.size.width * plate.midX, y: proxy.size.height * plate.midY)
                                }
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("예시 번호판 가림 전환")
                .accessibilityValue(masked ? "가림" : "원본")
            }
            HStack {
                Text("도로시아 랭, 캘리포니아").font(.caption).foregroundStyle(Palette.secondary)
                Spacer()
                Button { masked.toggle() } label: {
                    Label(masked ? "원본 보기" : "가림 보기", systemImage: masked ? "eye" : "eye.slash")
                        .font(.caption.bold()).frame(minHeight: 44)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("내 사진 편집").font(.title2.bold())
            Text("얼굴이나 원하는 부분을 가립니다.\n한 번에 사진 \(limit)장까지 선택하세요.")
                .font(.subheadline).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: choosePhoto) {
                PrimaryLabel(title: "사진 선택하기", symbol: "photo.on.rectangle")
            }.buttonStyle(.plain)
            Button(action: openSample) {
                Text("예시 사진으로 연습").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }
}
