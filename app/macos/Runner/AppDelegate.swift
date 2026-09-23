import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Closing the window keeps Flomsi running in the Dock, so new mail is still fetched and
  // announced; ⌘Q quits.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // A click on the Dock icon brings the window back.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag { showWindow() }
    return true
  }

  // So does a click on a notification, which activates the app.
  override func applicationDidBecomeActive(_ notification: Notification) {
    if !NSApp.windows.contains(where: { $0.isVisible }) { showWindow() }
  }

  private func showWindow() {
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
