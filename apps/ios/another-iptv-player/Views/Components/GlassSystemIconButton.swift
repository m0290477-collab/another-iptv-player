import SwiftUI

struct GlassSystemIconButton: View {
    var systemName: String
    var pointSize: CGFloat
    var weight: Font.Weight = .semibold
    var buttonSize: CGFloat
    /// Round 15 (C1): VoiceOver label, supplied by the caller with
    /// a translated key. Optional so existing icon-only call sites
    /// keep compiling; player call sites all pass one.
    var accessibilityLabel: String? = nil
    var action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)

                Circle()
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)

                Image(systemName: systemName)
                    .font(.system(size: pointSize, weight: weight))
                    .foregroundStyle(.white.opacity(0.96))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 0.5)
            }
            .frame(width: buttonSize, height: buttonSize)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        // Only override the label when the caller supplied one —
        // other call sites keep their existing VoiceOver behavior.
        if let accessibilityLabel {
            button.accessibilityLabel(accessibilityLabel)
        } else {
            button
        }
    }
}
