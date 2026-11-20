import SwiftUI

struct CameraStatusView: View {
    let state: CameraState
    let lowVisionMode: Bool
    let isLargeText: Bool

    private var statusKey: LocalizedStringKey {
        LocalizedStringKey(state.statusLocalizationKey(lowVisionMode: lowVisionMode))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(tintColor)
                .symbolEffect(.variableColor.iterative, isActive: state.isBusy)
                .symbolEffect(.pulse, isActive: state == .running)
                .accessibilityHidden(true)

            Text(statusKey)
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
        .accessibilityValue(statusKey)
        .accessibilityIdentifier("cameraStatus")
    }

    private var iconName: String {
        switch state {
        case .running:
            return "figure.walk"
        case .permissionDenied, .unavailable:
            return "exclamationmark.triangle.fill"
        case .requestingPermission, .starting:
            return "ellipsis"
        case .idle:
            return "checkmark.circle.fill"
        }
    }

    private var tintColor: Color {
        switch state {
        case .permissionDenied, .unavailable:
            return .orange
        case .requestingPermission, .starting:
            return .yellow
        case .idle, .running:
            return Color(red: 0.25, green: 0.95, blue: 0.77)
        }
    }
}
