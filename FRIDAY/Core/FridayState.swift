import Foundation

/// Every state the app can be in. The whole of FRIDAY is this machine:
///
///     idle → listening → thinking → speaking → idle
///     any state → error → idle
///
/// Later sessions add the transitions. Session 1 only ever holds `.idle`.
enum FridayState: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case speaking
    case error(String)
}
