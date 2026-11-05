import AppKit
import ApplicationServices

/// Reading other apps' windows and raising them requires the user to grant Accessibility access.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Registers the app in Privacy & Security → Accessibility and takes the user there.
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) else { return }
        openSettings()
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Thin typed wrappers over the AXUIElement C API.
extension AXUIElement {
    static func application(pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    func attribute<T>(_ name: String, as type: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func element(_ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success, let array = value as? [AnyObject] else { return [] }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    func point(_ name: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success, let value else { return nil }
        var point = CGPoint.zero
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    func size(_ name: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success, let value else { return nil }
        var size = CGSize.zero
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Window frame in Quartz (top-left origin) coordinates.
    var quartzFrame: CGRect? {
        guard let origin = point(kAXPositionAttribute), let size = size(kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var title: String? { attribute(kAXTitleAttribute, as: String.self) }
    var isMinimized: Bool { attribute(kAXMinimizedAttribute, as: Bool.self) ?? false }
    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(self, &pid)
        return pid
    }

    @discardableResult
    func set(_ name: String, to value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(self, action as CFString) == .success
    }
}
