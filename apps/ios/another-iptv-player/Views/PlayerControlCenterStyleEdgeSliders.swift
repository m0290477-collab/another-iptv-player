import SwiftUI

/// Dikey kenar kaydırıcıları: sol parlaklık, sağ sistem sesi. (Build 80, item 7: düz/flat stil — ince çizgi + içi boş halka; eskiden Kontrol Merkezi kapsülü.)
///
/// Yerleşim: sol/sağ kenarlarda dikey ortada. `safeAreaInsets` ile çentik alanından uzak tutulur.
/// Compact horizontal size class'ta (iPhone) slider daraltılıp (52pt) portrait'te centerTransport
/// ile yatayda çakışması önlenir; regular size class'ta (iPad) normal genişlik.
struct PlayerControlCenterStyleEdgeSliders: View {
  @ObservedObject var player: VideoPlayerController
  @ObservedObject var systemVolume: SystemVolumeBridge
  var safeAreaInsets: EdgeInsets
  var isCompactWidth: Bool
  var onInteraction: () -> Void

  private var trackWidth: CGFloat { isCompactWidth ? 52 : 64 }
  private var trackHeight: CGFloat { isCompactWidth ? 160 : 180 }

  var body: some View {
    ZStack {
      PlayerCCVerticalSlider(
        value: Binding(
          get: { Double(player.screenBrightness) },
          set: { player.setScreenBrightness(CGFloat($0)) }
        ),
        symbolName: "sun.max",
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
    if t < 0.001 { return "speaker.slash" }
    if t < 0.34 { return "speaker.wave.1" }
    if t < 0.67 { return "speaker.wave.2" }
    return "speaker.wave.3"
  }
}

// MARK: - Vertical flat slider
private struct PlayerCCVerticalSlider: View {
  @Binding var value: Double
  var symbolName: String
  var accessibilityLabel: String
  var accessibilityValueFormat: (Double) -> String
  var trackWidth: CGFloat = 64
  var trackHeight: CGFloat = 180
  var onInteraction: () -> Void

  @State private var dragStartValue: Double? = nil

  // Build 80 (item 7, player-style-flat): the Control-Center fat
  // capsule is replaced by the flat style — a 3pt vertical line,
  // a white fill up to the current value, a small hollow-circle
  // thumb on the fill's top edge, and the thin outline icon above
  // the line. The hit frame, drag math (relative drag over
  // `trackHeight`), bindings and accessibility are UNCHANGED.
  private var lineHeight: CGFloat { max(40, trackHeight - 36) }

  private var fillHeight: CGFloat {
    let clamped = min(max(value, 0), 1)
    return CGFloat(clamped) * lineHeight
  }

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbolName)
        .font(.system(size: 15, weight: .light))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 0.5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)

      ZStack(alignment: .bottom) {
        Capsule()
          .fill(Color.white.opacity(0.28))
          .frame(width: 3, height: lineHeight)

        Capsule()
          .fill(Color.white)
          .frame(width: 3, height: fillHeight)
          .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.88), value: value)

        Circle()
          .strokeBorder(Color.white, lineWidth: 2)
          .background(Circle().fill(Color.black.opacity(0.25)))
          .frame(width: 15, height: 15)
          .padding(.bottom, min(max(fillHeight - 7.5, 0), lineHeight - 15))
          .allowsHitTesting(false)
      }
      .frame(width: trackWidth, height: lineHeight)
      .contentShape(Rectangle())
      .gesture(
        // Tap ile anlık sıçrama yerine yalnızca gerçek sürükleme ile değer değiştir.
        // Sürükleme başlangıcındaki değerden itibaren göreceli hareketle güncelle.
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
