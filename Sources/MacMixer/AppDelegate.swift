import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MixerModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.prepareForQuit { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
