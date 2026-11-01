import SwiftUI

struct HomeHeaderView: View {
    let isLargeText: Bool
    let openSettings: () -> Void
    var body: some View {
        // Large accessibility text cannot fit brand and settings on one row; stack them.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) {
                brand
                Spacer()
                settingsButton
            }
            VStack(alignment: .leading, spacing: 12) {
                brand
                settingsButton
            }
        }
        .padding(.top, 8)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image("HomeLogo")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            Text("PRTS")
                .font(.title2.weight(.bold))
        }
        // The brand is a title, not content; past accessibility1 it would push the controls away.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("app.home")
        .accessibilityAddTraits(.isHeader)
    }

    private var settingsButton: some View {
        Button {
            openSettings()
        } label: {
            if isLargeText {
                // Icon-only so the header stays one row; long-press shows the Large Content Viewer.
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .dynamicTypeSize(.xxxLarge)
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
                    .glassSurface(in: Circle(), interactive: true)
            } else {
                Label("home.settings.button", systemImage: "gearshape.fill")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .contentShape(Capsule())
                    .glassSurface(in: Capsule(), interactive: true)
            }
        }
        .accessibilityShowsLargeContentViewer {
            Label("home.settings.button", systemImage: "gearshape.fill")
        }
        .accessibilityLabel("home.settings.label")
        .accessibilityHint("home.settings.hint")
        .accessibilityIdentifier("settingsButton")
    }
}
