import SwiftUI

struct WelcomeView: View {
    let columns: Bool
    let choosePhoto: () -> Void
    @State private var sampleMasked = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Brand()
                    Spacer()
                    Label("기기 내 처리", systemImage: "lock.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(Palette.moss)
                }
                if columns {
                    HStack(alignment: .center, spacing: 24) {
                        sample
                        VStack(alignment: .leading, spacing: 24) {
                            introduction
                            chooseButton
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    introduction
                    sample
                    chooseButton
                }
            }
            .padding(22)
            .frame(maxWidth: columns ? .infinity : 570)
            .frame(maxWidth: .infinity)
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("얼굴 모자이크").font(.system(.largeTitle, design: .rounded, weight: .heavy))
            Text("사진을 골라 가릴 얼굴과 남길 얼굴을 정하세요.")
                .font(.body).foregroundStyle(Palette.moss)
        }
    }

    private var chooseButton: some View {
        VStack(spacing: 12) {
            Button(action: choosePhoto) {
                PrimaryLabel(title: "사진 선택하기", symbol: "photo.on.rectangle.angled")
            }
            .buttonStyle(.plain)
            Text("얼굴 감지와 모자이크는 아이폰에서 처리해요.")
                .font(.footnote).foregroundStyle(Palette.moss)
        }
    }

    private var sample: some View {
        VStack(spacing: 0) {
            Button { sampleMasked.toggle() } label: {
                PortraitSample(masked: sampleMasked)
                    .aspectRatio(1.42, contentMode: .fit)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("예시 얼굴 모자이크 전환")
            .accessibilityValue(sampleMasked ? "가림" : "원본")
            HStack {
                Text("사용 예시").font(.subheadline.bold())
                Spacer()
                Button { sampleMasked.toggle() } label: {
                    Label(sampleMasked ? "원본 보기" : "가림 보기",
                          systemImage: sampleMasked ? "eye" : "eye.slash")
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.white.opacity(0.65))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.line, lineWidth: 1))
    }
}

/// An interactive illustration lets someone try the masking gesture without sharing a photo.
private struct PortraitSample: View {
    let masked: Bool

    var body: some View {
        Canvas { originalContext, size in
            var context = originalContext
            context.scaleBy(x: size.width / 320, y: size.height / 225)
            func color(_ hex: Int) -> Color {
                Color(red: Double((hex >> 16) & 255) / 255,
                      green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
            }
            func rectangle(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: Int) {
                context.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(color(hex)))
            }
            func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: Int) {
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h)), with: .color(color(hex)))
            }
            func polygon(_ points: [CGPoint], _ hex: Int) {
                var path = Path()
                path.addLines(points)
                path.closeSubpath()
                context.fill(path, with: .color(color(hex)))
            }
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

            rectangle(0, 0, 320, 225, 0xBBCBC6)
            oval(250, 20, 36, 36, 0xF5E4A7)
            polygon([point(0, 133), point(62, 92), point(111, 117), point(175, 74),
                     point(246, 109), point(320, 59), point(320, 225), point(0, 225)], 0x92ABA0)
            polygon([point(0, 150), point(89, 120), point(175, 142), point(270, 109),
                     point(320, 126), point(320, 225), point(0, 225)], 0x66897B)

            // Portrait on the left, wearing a rust-coloured jacket.
            oval(39, 55, 65, 101, 0x3B302D)
            polygon([point(12, 225), point(23, 162), point(45, 143), point(69, 136),
                     point(95, 141), point(130, 164), point(142, 225)], 0xBC6748)
            rectangle(65, 118, 21, 30, 0xB9795B)
            oval(51, 66, 49, 66, 0xD69A77)
            polygon([point(45, 89), point(52, 61), point(78, 52), point(100, 64),
                     point(102, 78), point(77, 72), point(64, 86)], 0x3B302D)
            rectangle(82, 93, 4, 4, 0x44332B)
            rectangle(94, 92, 3, 4, 0x44332B)
            rectangle(83, 113, 9, 2, 0x975B4B)
            polygon([point(49, 142), point(69, 151), point(77, 167), point(85, 150),
                     point(99, 143), point(85, 188), point(69, 188)], 0xEDBA82)

            // Portrait on the right, under the selectable mask.
            polygon([point(122, 225), point(139, 161), point(162, 140), point(194, 131),
                     point(229, 140), point(261, 153), point(287, 225)], 0x2A5046)
            rectangle(189, 114, 25, 31, 0xAB7255)
            oval(169, 56, 62, 74, 0xC98D68)
            oval(165, 43, 64, 42, 0x463932)
            rectangle(165, 72, 9, 26, 0x463932)
            rectangle(181, 89, 4, 4, 0x3E332C)
            rectangle(205, 89, 4, 4, 0x3E332C)
            rectangle(188, 110, 13, 2, 0x915C48)
            polygon([point(180, 137), point(200, 151), point(219, 137),
                     point(209, 166), point(188, 166)], 0xDDD1AB)

            if masked {
                let tones = [0x51443A, 0x84634E, 0xA5795F, 0xC89470, 0xDEAA84, 0xB48363]
                let grid = [[0,0,1,0,0,1], [0,1,1,0,1,2], [1,2,3,2,3,5],
                            [2,3,4,5,4,3], [1,5,3,4,2,5], [2,3,5,3,5,2], [1,2,3,5,2,1]]
                for (y, row) in grid.enumerated() {
                    for (x, tone) in row.enumerated() {
                        rectangle(CGFloat(164 + x * 12), CGFloat(45 + y * 12), 12, 12, tones[tone])
                    }
                }
            }
            var corners = Path()
            for (x, y, dx, dy) in [(160, 41, 1, 1), (240, 41, -1, 1),
                                   (160, 133, 1, -1), (240, 133, -1, -1)] {
                corners.move(to: point(CGFloat(x + 11 * dx), CGFloat(y)))
                corners.addLine(to: point(CGFloat(x), CGFloat(y)))
                corners.addLine(to: point(CGFloat(x), CGFloat(y + 11 * dy)))
            }
            context.stroke(corners, with: .color(Palette.lime), lineWidth: 2.5)
        }
        .accessibilityHidden(true)
    }
}
