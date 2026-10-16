import AppKit

enum AppBrand {
    static var icon: NSImage {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "AppIcon"
        let filename = name.hasSuffix(".icns") ? name : "\(name).icns"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(filename),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }
}
