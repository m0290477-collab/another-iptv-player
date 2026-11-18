import SwiftUI
import UIKit

/// Gesture recognizers live below SwiftUI's edge sliders, so taps can leak through the
/// transparent SwiftUI drag surface. Reject only the actual capsule frames; excluding a
/// full-height edge strip creates large tap/long-press dead zones.
struct PlayerEdgeSliderGestureExclusion {
  static let hitSlop: CGFloat = 8

  static func contains(
    _ point: CGPoint,
    in bounds: CGRect,
    trackSize: CGSize,
    leadingInset: CGFloat,
    trailingInset: CGFloat
  ) -> Bool {
    guard bounds.width > 0, bounds.height > 0,
          trackSize.width > 0, trackSize.height > 0 else {
      return false
    }

    let originY = bounds.midY - trackSize.height / 2
    let leadingRect = CGRect(
      x: bounds.minX + leadingInset,
      y: originY,
      width: trackSize.width,
      height: trackSize.height
    ).insetBy(dx: -hitSlop, dy: -hitSlop)
    let trailingRect = CGRect(
      x: bounds.maxX - trailingInset - trackSize.width,
      y: originY,
      width: trackSize.width,
      height: trackSize.height
    ).insetBy(dx: -hitSlop, dy: -hitSlop)

    return leadingRect.contains(point) || trailingRect.contains(point)
  }
}

struct PlayerSpeedHoldGesturePolicy {
  static func recognizerEnabled(canBegin: Bool, isActive: Bool) -> Bool {
    canBegin || isActive
  }
}

/// media-kit style: show the controls with a single-finger `UITapGestureRecognizer` while they are **closed** (so it doesn't confuse drag-to-close
/// with `touchesBegan`). While **open**, hiding is again a tap; with `UILongPressGestureRecognizer` (2x)
/// the `require(toFail:)` ordering is used.
/// VOD skip ±15 sec, with the SwiftUI buttons next to play/pause.
/// All pinch + pan (while zoomed) is in this UIKit container; when a SwiftUI `.gesture` is attached to the scaled view,
/// its coordinate system breaks and it conflicts with the outer dismiss gesture.
/// `hitTest` always returns `super` — the gesture recognizers capture the touches; tap/pinch/pan
/// talk simultaneously via `shouldRecognizeSimultaneouslyWith`.
final class PlayerMediaKitTouchContainerView: UIView, UIGestureRecognizerDelegate {
  fileprivate weak var coordinator: PlayerMediaKitStyleTouchOverlay.Coordinator?

  var videoZoomScale: CGFloat = 1 {
    didSet { videoPan.isEnabled = videoZoomScale > 1.02 }
  }
  var enableSpeedHold: Bool = false
  var isSpeedHoldActive: Bool = false
  /// Round 14 (B3): vertical-swipe channel zapping is armed only
  /// for fullscreen live playback with a channel queue.
  var channelZapEnabled: Bool = false {
    didSet {
      zapUp.isEnabled = channelZapEnabled
      zapDown.isEnabled = channelZapEnabled
    }
  }
  var edgeSliderTrackSize: CGSize = .zero
  var edgeSliderLeadingInset: CGFloat = 0
  var edgeSliderTrailingInset: CGFloat = 0

  fileprivate let centerView = MediaKitCenterPanel()
  private let videoPinch = UIPinchGestureRecognizer()
  private let videoPan = UIPanGestureRecognizer()
  private let zapUp = UISwipeGestureRecognizer()
  private let zapDown = UISwipeGestureRecognizer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isMultipleTouchEnabled = true
    isOpaque = false
    backgroundColor = .clear

    videoPinch.addTarget(self, action: #selector(handleVideoPinch(_:)))
    videoPinch.cancelsTouchesInView = false
    videoPinch.delegate = self
    addGestureRecognizer(videoPinch)

    videoPan.addTarget(self, action: #selector(handleVideoPan(_:)))
    videoPan.cancelsTouchesInView = false
    videoPan.delegate = self
    videoPan.minimumNumberOfTouches = 1
    videoPan.maximumNumberOfTouches = 1
    videoPan.isEnabled = false  // only active while zoomed
    addGestureRecognizer(videoPan)

    // Round 14 (B3): swipe up = next channel, swipe down =
    // previous channel (TV-remote direction). Disabled unless the
    // SwiftUI side arms them (live + fullscreen + queue exists).
    zapUp.direction = .up
    zapUp.addTarget(self, action: #selector(handleZapUp(_:)))
    zapUp.cancelsTouchesInView = false
    zapUp.delegate = self
    zapUp.isEnabled = false
    addGestureRecognizer(zapUp)

    zapDown.direction = .down
    zapDown.addTarget(self, action: #selector(handleZapDown(_:)))
    zapDown.cancelsTouchesInView = false
    zapDown.delegate = self
    zapDown.isEnabled = false
    addGestureRecognizer(zapDown)

    addSubview(centerView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    centerView.frame = bounds
  }

  func bindToCoordinator(_ c: PlayerMediaKitStyleTouchOverlay.Coordinator) {
    coordinator = c
    centerView.coordinator = c
    syncPanels()
  }

  /// Round 14 (B12): double-tap seek is armed only for seekable,
  /// actually-playing content (set from the SwiftUI side).
  var seekEnabled: Bool = false

  func syncPanels() {
    let show = coordinator?.showControls.wrappedValue ?? true
    centerView.configureRecognizers(
      showControls: show,
      enableSpeedHold: enableSpeedHold,
      isSpeedHoldActive: isSpeedHoldActive,
      seekEnabled: seekEnabled,
      edgeSliderTrackSize: edgeSliderTrackSize,
      edgeSliderLeadingInset: edgeSliderLeadingInset,
      edgeSliderTrailingInset: edgeSliderTrailingInset
    )
  }

  @objc private func handleVideoPinch(_ g: UIPinchGestureRecognizer) {
    switch g.state {
    case .began:
      let loc = g.location(in: self)
      coordinator?.onVideoPinchBegan(loc, bounds.size)
    case .changed:
      coordinator?.onVideoPinchChanged(g.scale)
    case .ended, .cancelled, .failed:
      coordinator?.onVideoPinchEnded()
    default:
      break
    }
  }

  @objc private func handleVideoPan(_ g: UIPanGestureRecognizer) {
    switch g.state {
    case .changed:
      let t = g.translation(in: self)
      coordinator?.onVideoPanChanged(CGSize(width: t.x, height: t.y))
    case .ended, .cancelled, .failed:
      let t = g.translation(in: self)
      coordinator?.onVideoPanEnded(CGSize(width: t.x, height: t.y))
    default:
      break
    }
  }

  @objc private func handleZapUp(_: UISwipeGestureRecognizer) {
    coordinator?.requestChannelZapFromUIKit(1)
  }

  @objc private func handleZapDown(_: UISwipeGestureRecognizer) {
    coordinator?.requestChannelZapFromUIKit(-1)
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }
}

private final class MediaKitCenterPanel: UIView, UIGestureRecognizerDelegate {
  fileprivate weak var coordinator: PlayerMediaKitStyleTouchOverlay.Coordinator?

  private let showTap = UITapGestureRecognizer()
  private let hideTap = UITapGestureRecognizer()
  private let doubleTap = UITapGestureRecognizer()
  private let speedHold = UILongPressGestureRecognizer()
  private var controlsVisible = true
  private var seekEnabled = false
  private var edgeSliderTrackSize: CGSize = .zero
  private var edgeSliderLeadingInset: CGFloat = 0
  private var edgeSliderTrailingInset: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: .zero)
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = true

    showTap.addTarget(self, action: #selector(showTapRecognized))
    showTap.numberOfTapsRequired = 1
    showTap.cancelsTouchesInView = false
    showTap.delegate = self
    addGestureRecognizer(showTap)

    hideTap.addTarget(self, action: #selector(hideTapRecognized))
    hideTap.numberOfTapsRequired = 1
    hideTap.cancelsTouchesInView = false
    hideTap.delegate = self
    addGestureRecognizer(hideTap)

    // Round 14 (B12): double-tap seek — left half −10 s, right
    // half +10 s (the same jumps the center transport buttons
    // make). Single taps must wait for the double-tap to fail,
    // the standard streaming-player tradeoff; the speed-hold
    // failure requirement already imposed the same wait.
    doubleTap.addTarget(self, action: #selector(doubleTapRecognized(_:)))
    doubleTap.numberOfTapsRequired = 2
    doubleTap.cancelsTouchesInView = false
    doubleTap.delegate = self
    addGestureRecognizer(doubleTap)

    speedHold.addTarget(self, action: #selector(speedHoldRecognized(_:)))
    speedHold.minimumPressDuration = 0.42
    speedHold.allowableMovement = 80
    speedHold.cancelsTouchesInView = false
    speedHold.delegate = self
    addGestureRecognizer(speedHold)

    showTap.require(toFail: speedHold)
    hideTap.require(toFail: speedHold)
    showTap.require(toFail: doubleTap)
    hideTap.require(toFail: doubleTap)
    doubleTap.require(toFail: speedHold)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configureRecognizers(
    showControls: Bool,
    enableSpeedHold: Bool,
    isSpeedHoldActive: Bool,
    seekEnabled: Bool,
    edgeSliderTrackSize: CGSize,
    edgeSliderLeadingInset: CGFloat,
    edgeSliderTrailingInset: CGFloat
  ) {
    controlsVisible = showControls
    self.seekEnabled = seekEnabled
    self.edgeSliderTrackSize = edgeSliderTrackSize
    self.edgeSliderLeadingInset = edgeSliderLeadingInset
    self.edgeSliderTrailingInset = edgeSliderTrailingInset
    showTap.isEnabled = !showControls && !isSpeedHoldActive
    hideTap.isEnabled = showControls && !isSpeedHoldActive
    doubleTap.isEnabled = seekEnabled && !isSpeedHoldActive
    // Once the hold has begun, transient buffering must not disable (and therefore
    // cancel) the recognizer. The user's finger-up remains the single end condition.
    speedHold.isEnabled = PlayerSpeedHoldGesturePolicy.recognizerEnabled(
      canBegin: enableSpeedHold,
      isActive: isSpeedHoldActive
    )
  }

  @objc private func doubleTapRecognized(_ g: UITapGestureRecognizer) {
    guard seekEnabled, bounds.width > 0 else { return }
    let point = g.location(in: self)
    coordinator?.requestDoubleTapSeekFromUIKit(forward: point.x >= bounds.midX)
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    // The 2x speed-hold must work from EVERY point, including over the edge sliders.
    // The sliders are drag-only (minimumDistance 8), so a stationary hold can never be
    // mistaken for a slider adjustment — there is nothing to exclude it from.
    if gestureRecognizer === speedHold { return true }
    // The edge sliders only exist while the chrome is visible; with controls hidden,
    // every point must remain a valid video gesture target. While visible, a single tap
    // over a slider capsule is still swallowed so it doesn't fight the slider drag.
    guard controlsVisible else { return true }
    return !PlayerEdgeSliderGestureExclusion.contains(
      touch.location(in: self),
      in: bounds,
      trackSize: edgeSliderTrackSize,
      leadingInset: edgeSliderLeadingInset,
      trailingInset: edgeSliderTrailingInset
    )
  }

  @objc private func showTapRecognized() {
    coordinator?.requestShowChromeFromUIKit()
  }

  @objc private func hideTapRecognized() {
    coordinator?.requestHideChromeFromUIKit()
  }

  @objc private func speedHoldRecognized(_ g: UILongPressGestureRecognizer) {
    switch g.state {
    case .began:
      coordinator?.requestSpeedHoldBeganFromUIKit()
    case .ended, .cancelled, .failed:
      coordinator?.requestSpeedHoldEndedFromUIKit()
    default:
      break
    }
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }
}

struct PlayerMediaKitStyleTouchOverlay: UIViewRepresentable {
  @Binding var showControls: Bool
  let isSeekDisabled: Bool
  let videoZoomScale: CGFloat
  let isSpeedHoldActive: Bool
  let isSpeedHoldEnabled: Bool
  /// Round 14 (B12): arms the double-tap ±10 s seek recognizers.
  var seekEnabled: Bool = false
  var onDoubleTapSeek: ((Bool) -> Void)? = nil
  /// Round 14 (B3): arms the vertical-swipe channel zap.
  var channelZapEnabled: Bool = false
  var onChannelZap: ((Int) -> Void)? = nil
  let edgeSliderTrackSize: CGSize
  let edgeSliderLeadingInset: CGFloat
  let edgeSliderTrailingInset: CGFloat
  /// Disabled while the player is shrinking into / sitting in the mini card, so the
  /// UIKit tap/pinch/pan recognizers don't intercept touches meant for the mini chrome.
  var interactionEnabled: Bool = true
  let onResetTimer: () -> Void
  let onInvalidateTimer: () -> Void
  let onSpeedHoldBegan: () -> Void
  let onSpeedHoldEnded: () -> Void
  let onVideoPinchBegan: (CGPoint, CGSize) -> Void
  let onVideoPinchChanged: (CGFloat) -> Void
  let onVideoPinchEnded: () -> Void
  let onVideoPanChanged: (CGSize) -> Void
  let onVideoPanEnded: (CGSize) -> Void
  var onVideoSurfaceTap: (() -> Void)? = nil

  func makeCoordinator() -> Coordinator {
    Coordinator(
      showControls: $showControls,
      onResetTimer: onResetTimer,
      onInvalidateTimer: onInvalidateTimer,
      onSpeedHoldBegan: onSpeedHoldBegan,
      onSpeedHoldEnded: onSpeedHoldEnded,
      onVideoPinchBegan: onVideoPinchBegan,
      onVideoPinchChanged: onVideoPinchChanged,
      onVideoPinchEnded: onVideoPinchEnded,
      onVideoPanChanged: onVideoPanChanged,
      onVideoPanEnded: onVideoPanEnded,
      onDoubleTapSeek: onDoubleTapSeek,
      onChannelZap: onChannelZap,
      onVideoSurfaceTap: onVideoSurfaceTap
    )
  }

  func makeUIView(context: Context) -> PlayerMediaKitTouchContainerView {
    let v = PlayerMediaKitTouchContainerView()
    v.bindToCoordinator(context.coordinator)
    return v
  }

  func updateUIView(_ uiView: PlayerMediaKitTouchContainerView, context: Context) {
    context.coordinator.showControls = $showControls
    context.coordinator.onResetTimer = onResetTimer
    context.coordinator.onInvalidateTimer = onInvalidateTimer
    context.coordinator.onSpeedHoldBegan = onSpeedHoldBegan
    context.coordinator.onSpeedHoldEnded = onSpeedHoldEnded
    context.coordinator.onVideoPinchBegan = onVideoPinchBegan
    context.coordinator.onVideoPinchChanged = onVideoPinchChanged
    context.coordinator.onVideoPinchEnded = onVideoPinchEnded
    context.coordinator.onVideoPanChanged = onVideoPanChanged
    context.coordinator.onVideoPanEnded = onVideoPanEnded
    context.coordinator.onDoubleTapSeek = onDoubleTapSeek
    context.coordinator.onChannelZap = onChannelZap
    context.coordinator.onVideoSurfaceTap = onVideoSurfaceTap
    uiView.videoZoomScale = videoZoomScale
    uiView.enableSpeedHold = isSpeedHoldEnabled && !isSeekDisabled && videoZoomScale <= 1.02
    uiView.isSpeedHoldActive = isSpeedHoldActive
    uiView.seekEnabled = seekEnabled && !isSeekDisabled && videoZoomScale <= 1.02
    uiView.channelZapEnabled = channelZapEnabled && videoZoomScale <= 1.02
    uiView.edgeSliderTrackSize = edgeSliderTrackSize
    uiView.edgeSliderLeadingInset = edgeSliderLeadingInset
    uiView.edgeSliderTrailingInset = edgeSliderTrailingInset
    uiView.isUserInteractionEnabled = interactionEnabled
    uiView.syncPanels()
    uiView.setNeedsLayout()
  }

  final class Coordinator: NSObject {
    var showControls: Binding<Bool>
    var onResetTimer: () -> Void
    var onInvalidateTimer: () -> Void
    var onSpeedHoldBegan: () -> Void
    var onSpeedHoldEnded: () -> Void
    var onVideoPinchBegan: (CGPoint, CGSize) -> Void
    var onVideoPinchChanged: (CGFloat) -> Void
    var onVideoPinchEnded: () -> Void
    var onVideoPanChanged: (CGSize) -> Void
    var onVideoPanEnded: (CGSize) -> Void
    var onDoubleTapSeek: ((Bool) -> Void)?
    var onChannelZap: ((Int) -> Void)?
    var onVideoSurfaceTap: (() -> Void)?

    init(
      showControls: Binding<Bool>,
      onResetTimer: @escaping () -> Void,
      onInvalidateTimer: @escaping () -> Void,
      onSpeedHoldBegan: @escaping () -> Void,
      onSpeedHoldEnded: @escaping () -> Void,
      onVideoPinchBegan: @escaping (CGPoint, CGSize) -> Void,
      onVideoPinchChanged: @escaping (CGFloat) -> Void,
      onVideoPinchEnded: @escaping () -> Void,
      onVideoPanChanged: @escaping (CGSize) -> Void,
      onVideoPanEnded: @escaping (CGSize) -> Void,
      onDoubleTapSeek: ((Bool) -> Void)? = nil,
      onChannelZap: ((Int) -> Void)? = nil,
      onVideoSurfaceTap: (() -> Void)? = nil
    ) {
      self.showControls = showControls
      self.onResetTimer = onResetTimer
      self.onInvalidateTimer = onInvalidateTimer
      self.onSpeedHoldBegan = onSpeedHoldBegan
      self.onSpeedHoldEnded = onSpeedHoldEnded
      self.onVideoPinchBegan = onVideoPinchBegan
      self.onVideoPinchChanged = onVideoPinchChanged
      self.onVideoPinchEnded = onVideoPinchEnded
      self.onVideoPanChanged = onVideoPanChanged
      self.onVideoPanEnded = onVideoPanEnded
      self.onDoubleTapSeek = onDoubleTapSeek
      self.onChannelZap = onChannelZap
      self.onVideoSurfaceTap = onVideoSurfaceTap
    }

    private func runOnMain(_ body: @escaping () -> Void) {
      if Thread.isMainThread {
        body()
      } else {
        DispatchQueue.main.async(execute: body)
      }
    }

    private func setShowControlsAnimated(_ newValue: Bool) {
      // Cross-fade the chrome like the native player. Previously this was a hard cut
      // (Transaction.disablesAnimations) which made the `.opacity` transition inert.
      withAnimation(.easeInOut(duration: 0.28)) {
        showControls.wrappedValue = newValue
      }
    }

    func requestShowChromeFromUIKit() {
      runOnMain { [weak self] in
        guard let self else { return }
        self.onVideoSurfaceTap?()
        guard !self.showControls.wrappedValue else { return }
        self.setShowControlsAnimated(true)
        self.onResetTimer()
      }
    }

    func requestHideChromeFromUIKit() {
      runOnMain { [weak self] in
        guard let self else { return }
        self.onVideoSurfaceTap?()
        guard self.showControls.wrappedValue else { return }
        self.setShowControlsAnimated(false)
        self.onInvalidateTimer()
      }
    }

    func requestDoubleTapSeekFromUIKit(forward: Bool) {
      runOnMain { [weak self] in
        self?.onDoubleTapSeek?(forward)
      }
    }

    func requestChannelZapFromUIKit(_ direction: Int) {
      runOnMain { [weak self] in
        self?.onChannelZap?(direction)
      }
    }

    func requestSpeedHoldBeganFromUIKit() {
      runOnMain { [weak self] in
        self?.onSpeedHoldBegan()
      }
    }

    func requestSpeedHoldEndedFromUIKit() {
      runOnMain { [weak self] in
        self?.onSpeedHoldEnded()
      }
    }
  }
}
