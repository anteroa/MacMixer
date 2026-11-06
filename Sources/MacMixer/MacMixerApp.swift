import SwiftUI

@main
struct MacMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environmentObject(appDelegate.model)
        } label: {
            MenuBarIcon(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        Image(systemName: model.menuBarSymbol)
    }
}
