import SwiftUI

/// The vertical capsule slider look from iOS Control Center: brightness on the left, system volume on the right.
///
/// Placement: vertically centered on the left/right edges. Kept clear of the notch area with `safeAreaInsets`.
/// In a compact horizontal size class (iPhone) the slider is narrowed (52pt) so in portrait it does not
/// overlap the centerTransport horizontally; in a regular size class (iPad) it keeps its normal width.
struct PlayerControlCenterStyleEdgeSliders: View {
  @ObservedObject var player: VideoPlayerController
  @ObservedObject var systemVolume: SystemVolumeBridge
  var safeAreaInsets: EdgeInsets
  var isCompactWidth: Bool
  var onInteraction: () -> Void

  /// Round 19 (R19-1a): the ONE source for the capsule size — the
  /// rendered sliders and `PlayerView`'s gesture-exclusion rect both
  /// read this helper (round 9 rule), so the touch math can never
  /// drift from the visual. Round 9 measurements: slim track
  /// 40x150 pt compact / 48x170 pt regular.
  static func trackSize(isCompactWidth: Bool) -> CGSize {
    CGSize(width: isCompactWidth ? 40 : 48, height: isCompactWidth ? 150 : 170)
  }

  private var trackWidth: CGFloat { Self.trackSize(isCompactWidth: isCompactWidth).width }
  private var trackHeight: CGFloat { Self.trackSize(isCompactWidth: isCompactWidth).height }

  var body: some View {
    ZStack {
      PlayerCCVerticalSlider(
        value: Binding(
          get: { Double(player.screenBrightness) },
          set: { player.setScreenBrightness(CGFloat($0)) }
        ),
        symbolName: "sun.max.fill",
        accessibilityLabel: L("player.brightness"),
        accessibilityValueFormat: { "\(Int(round($0 * 100)))%" },
        trackWidth: trackWidth,
        trackHeight: trackHeight,
        onInteraction: onInteraction
      )
      .padding(.leading, 16 + safeAreaInsets.leading)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

      PlayerCCVerticalSlider(
        value: Binding(
          get: { Double(systemVolume.outputVolume) },
          set: { systemVolume.setOutputVolume(Float($0)) }
        ),
        symbolName: volumeSymbolName,
        accessibilityLabel: L("player.volume"),
        accessibilityValueFormat: { "\(Int(round($0 * 100)))%" },
        trackWidth: trackWidth,
        trackHeight: trackHeight,
        onInteraction: onInteraction
      )
      .padding(.trailing, 16 + safeAreaInsets.trailing)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
  }

  private var volumeSymbolName: String {
    let t = min(max(Double(systemVolume.outputVolume), 0), 1)
    if t < 0.001 { return "speaker.slash.fill" }
    if t < 0.34 { return "speaker.wave.1.fill" }
    if t < 0.67 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
  }
}

// MARK: - Vertical capsule

/// iOS Control Center style vertical slider: a wide capsule with an edge-to-edge flat white fill inside,
/// the SF Symbol at the bottom center **inside** the capsule; the icon color inverts with the fill level
/// (dark on the fill, white on the material) — matching the Control Center behavior.
private struct PlayerCCVerticalSlider: View {
  @Binding var value: Double
  var symbolName: String
  var accessibilityLabel: String
  var accessibilityValueFormat: (Double) -> String
  var trackWidth: CGFloat = 64
  var trackHeight: CGFloat = 180
  var onInteraction: () -> Void

  @State private var dragStartValue: Double? = nil

  private var cornerRadius: CGFloat { min(trackWidth, trackHeight) * 0.4 }

  private var fillHeight: CGFloat {
    let clamped = min(max(value, 0), 1)
    return CGFloat(clamped) * trackHeight
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      // Round 19 (R19-1a, round 9 restyle per the owner's Super X
      // photo): dark-blur track — ultraThinMaterial under a black
      // 0.45 wash — instead of the pre-restyle light capsule.
      Rectangle()
        .fill(.ultraThinMaterial)
      Rectangle()
        .fill(Color.black.opacity(0.45))

      // Level — Super X blue accent fill (0.92), edge-to-edge,
      // clipped to the rounded corners with `clipShape`. (Round 9 replaced
      // the original solid-white fill with the accent fill; round
      // 18's white-fill restore is superseded by the owner's photo.)
      Rectangle()
        .fill(AppTheme.accent.opacity(0.92))
        .frame(height: fillHeight)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.88), value: value)

      // SF Symbol — inside the capsule, at the bottom center; always white
      // (round 9: the fill-inversion logic is gone).
      Image(systemName: symbolName)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(.white)
        .shadow(
          color: .black.opacity(0.35),
          radius: 2,
          y: 0.5
        )
        .padding(.bottom, 18)
        .allowsHitTesting(false)
        .accessibilityHidden(true)

      // Drag area — the whole capsule surface.
      Color.clear
        .contentShape(Rectangle())
        .gesture(
          // Change the value only with a real drag, not an instant jump on tap.
          // Update with relative movement from the value at the start of the drag.
          DragGesture(minimumDistance: 8)
            .onChanged { g in
              onInteraction()
              if dragStartValue == nil {
                dragStartValue = value
              }
              let delta = Double(-CGFloat(g.translation.height) / trackHeight)
              value = min(max((dragStartValue ?? value) + delta, 0), 1)
            }
            .onEnded { _ in
              dragStartValue = nil
            }
        )
    }
    .frame(width: trackWidth, height: trackHeight)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
    )
    .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValueFormat(value))
    .accessibilityAdjustableAction { direction in
      onInteraction()
      let step = 0.05
      switch direction {
      case .increment:
        value = min(1, value + step)
      case .decrement:
        value = max(0, value - step)
      @unknown default:
        break
      }
    }
  }
}
