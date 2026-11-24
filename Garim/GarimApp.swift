import SwiftUI

@main
struct GarimApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

enum Palette {
    static let paper = Color(red: 0.967, green: 0.961, blue: 0.925)
    static let ink = Color(red: 0.084, green: 0.15, blue: 0.126)
    static let moss = Color(red: 0.22, green: 0.31, blue: 0.26)
    static let lime = Color(red: 0.82, green: 0.95, blue: 0.45)
    static let line = Color(red: 0.81, green: 0.83, blue: 0.76)
}

struct PrimaryLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack {
            Label(title, systemImage: symbol).font(.headline)
            Spacer()
            Image(systemName: "arrow.right").accessibilityHidden(true)
        }
        .padding(.horizontal, 20).padding(.vertical, 17)
        .foregroundStyle(Palette.lime)
        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 17))
    }
}
