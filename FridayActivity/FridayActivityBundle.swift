import WidgetKit
import SwiftUI

/// Entry point for the widget extension.
///
/// This bundle is the extension's `@main`. It carries the Live Activity from
/// Session 6, Session 7's Control Centre control and Lock Screen launcher, and
/// the Home Screen status widget — which is the only one of them that shows real
/// data, because it reads EventKit and CoreMotion directly rather than reading
/// anything the app wrote (D-52, D-69).
@main
struct FridayActivityBundle: WidgetBundle {
    var body: some Widget {
        FridayLiveActivity()
        FridayListenControl()
        FridayLockWidget()
        FridayStatusWidget()
        FridayTimerActivity()
    }
}
