import SwiftUI

struct GlassSystemIconButton: View {
    var systemName: String
    var pointSize: CGFloat
    var weight: Font.Weight = .regular
    var buttonSize: CGFloat
    /// Round 15 (C1): VoiceOver label, supplied by the caller with
    /// a translated key. Optional so existing icon-only call sites
    /// keep compiling; player call sites all pass one.
    var accessibilityLabel: String? = nil
    var action: () -> Void

    var body: some View {
        // Build 80 (item 7, player-style-flat): the glass circle is
        // gone — a bare thin-line icon on the same hit frame. (This
        // component is used only by the player's chrome.)
        let button = Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: pointSize, weight: weight))
                .foregroundStyle(.white.opacity(0.96))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 0.5)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
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
