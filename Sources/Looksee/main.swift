import AppKit

let glanceNotification = Notification.Name("com.zaryab.looksee.glance")

// `Looksee --glance 2` tells the running app to act as if you looked at screen 2 (1-based, left to right).
// Handy for testing the window switching without moving your head.
if let i = CommandLine.arguments.firstIndex(of: "--glance"), i + 1 < CommandLine.arguments.count {
    DistributedNotificationCenter.default().postNotificationName(
        glanceNotification, object: nil, userInfo: ["screen": CommandLine.arguments[i + 1]], deliverImmediately: true
    )
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
