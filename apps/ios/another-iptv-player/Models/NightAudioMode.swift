import Foundation

/// Build 61 (B10, Q5): dialogue / night audio mode.
///
/// REAL mechanism (investigated in the KSPlayer source, per the
/// brief): `KSOptions.audioFilters` is KSPlayer's public list of
/// FFmpeg audio filters, applied by the FFmpeg (KSMEPlayer) decode
/// path through its MEFilter graph. Night mode here is dynamic
/// range compression — the classic night-mode DSP: loud peaks are
/// pulled down and quiet dialogue stays intelligible at low
/// speaker volume. The filter is `acompressor` with a 4:1 ratio
/// above a -21 dB threshold.
///
/// Coordination with B9's Q1 (loudness normalization): there is
/// ONE `audioFilters` array, so both features APPEND their filter
/// instead of assigning the array — whichever lands second in
/// `KSPlayerEngine.makeOptions` must keep this append discipline,
/// and the two compose (normalization + compression can coexist
/// in one FFmpeg filter chain).
///
/// Honest limits: the filter exists only on the FFmpeg decode
/// path; content the engine plays through the native AVPlayer
/// path (HLS/mp4 family) has no FFmpeg filter graph and is
/// unaffected. KSOptions are consumed when a stream loads, so
/// toggling applies from the NEXT stream start — the settings
/// sheet's footer says exactly that.
enum NightAudioMode {
    static let defaultsKey = "player.nightAudioMode"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }

    /// The FFmpeg filter appended to `KSOptions.audioFilters`
    /// when the mode is on.
    static let ffmpegFilter = "acompressor=threshold=-21dB:ratio=4:attack=20:release=250"
}
