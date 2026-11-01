import SwiftUI

struct HomePlaceholderView: View {
    let state: CameraState
    let isLargeText: Bool
    /// Idle: what the three gestures do. Starting: a spinner until the first frame.
    var body: some View {
        VStack(alignment: isLargeText ? .leading : .center, spacing: 22) {
            if state.isBusy {
                ProgressView().controlSize(.large).tint(.appAccent)
            } else {
                if !isLargeText {
                    Image("HomeLogo")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityHidden(true)
                }
                Text("home.idle.title")
                    .font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 14) {
                    tip("figure.walk", "home.idle.tip.guide")
                    tip("hand.tap.fill", "home.idle.tip.photo")
                    tip("text.viewfinder", "home.idle.tip.text")
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .glassSurface(in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .multilineTextAlignment(isLargeText ? .leading : .center)
        .animation(.easeInOut(duration: 0.25), value: state.isBusy)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("homeTips")
    }

    private func tip(_ symbol: String, _ key: LocalizedStringKey) -> some View {
        Label {
            Text(key).font(.body).multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.appAccent).frame(width: 28)
        }
    }
}
