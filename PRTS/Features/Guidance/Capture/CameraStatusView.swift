import SwiftUI

struct CameraStatusView: View {
    let state: CameraState
    let isLargeText: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.iconName)
                .foregroundStyle(state.tintColor)
                .symbolEffect(.variableColor.iterative, isActive: state.isBusy)
                .symbolEffect(.pulse, isActive: state == .running)
                .accessibilityHidden(true)

            Text(LocalizedStringKey(state.statusLocalizationKey))
                .font(.headline)
                .lineLimit(3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, isLargeText ? 12 : 0)
        .frame(maxWidth: isLargeText ? .infinity : nil, minHeight: 50, alignment: .leading)
        .glassSurface(
            in: isLargeText ? AnyShape(RoundedRectangle(cornerRadius: 24)) : AnyShape(Capsule())
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("home.camera.status.label")
        .accessibilityValue(LocalizedStringKey(state.statusLocalizationKey))
        .accessibilityIdentifier("cameraStatus")
    }
}
