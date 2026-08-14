import WidgetKit
import SwiftUI

/// Entry point for the widget extension.
///
/// This bundle is the extension's `@main`, and the only thing it carries is the
/// Live Activity written in Session 6. Session 7's Lock Screen widget will be
/// added here alongside it.
@main
struct FridayActivityBundle: WidgetBundle {
    var body: some Widget {
        FridayLiveActivity()
        FridayListenControl()
    }
}
