import AppKit
import SwiftUI

@available(macOS 14.2, *)
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            model?.teardown()
        }
    }
}

@available(macOS 14.2, *)
@main
struct SoundBoostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
                .onAppear {
                    appDelegate.model = model
                }
        } label: {
            Image(systemName: model.menuBarSymbolName)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
    }
}
