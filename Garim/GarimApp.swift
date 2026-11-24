import SwiftUI

@main
struct GarimApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

enum Palette {
    static let paper = Color(red: 0.965, green: 0.961, blue: 0.944)
    static let ink = Color(white: 0.10)
    static let secondary = Color(white: 0.34)
    static let accent = Color(red: 0.66, green: 0.19, blue: 0.09)
    static let marker = Color(red: 1, green: 0.70, blue: 0.36)
    static let line = Color(white: 0.79)
}

struct PrimaryLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 8)
            .foregroundStyle(.white)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 8))
    }
}
