import Foundation

/// All NSLog calls must go through this helper.
///
/// **Why:** in an `NSLog("foo \(bar)")` call, the whole interpolated string is interpreted as a format string.
/// If `bar` contains `%` (such as `%20`, `%2F` in URLs), NSLog
/// reads a garbage pointer from va_list and crashes with `EXC_BAD_ACCESS`.
///
/// `Log.info/error` always passes the message with `"%@"` → format-string injection is impossible.
nonisolated enum Log {
  static func info(_ tag: String, _ message: @autoclosure () -> String) {
    NSLog("%@", "[\(tag)] \(message())")
  }

  static func error(_ tag: String, _ message: @autoclosure () -> String) {
    NSLog("%@", "[\(tag)] ERROR: \(message())")
  }
}
