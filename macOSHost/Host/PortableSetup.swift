import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import Darwin
import WDMacAudio

enum PortableSetup {
    static let bundleID = "org.autosidecar.companion.host"

    static func receiverDownloadURL(_ value: String?) -> URL? {
        guard let value, let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let pattern: String
        switch parts.host?.lowercased() {
        case "apps.apple.com": pattern = #"^/(?:[a-zA-Z]{2}/)?app/(?:[^/]+/)?id[1-9][0-9]*/?$"#
        case "testflight.apple.com": pattern = #"^/join/[a-zA-Z0-9]{8}/?$"#
        default: return nil
        }
        guard parts.percentEncodedPath.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return parts.url
    }

    static var receiverURL: URL? {
        receiverDownloadURL(Bundle.main.object(forInfoDictionaryKey: "AutoSidecarReceiverURL") as? String)
    }

    @MainActor
    static func receiverCode(_ url: URL) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }
        let background = CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -4, dy: -4))
        let scale = max(1, min(5, floor(220 / background.extent.width)))
        let image = code.composited(over: background).transformed(by: .init(scaleX: scale, y: scale))
        guard let bitmap = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: bitmap, size: image.extent.size)
    }

    @MainActor
    private static func codeView(_ image: NSImage) -> NSImageView {
        let view = NSImageView(image: image)
        view.setAccessibilityLabel("iPad 接收器下載碼")
        return view
    }

    @MainActor
    static func showReceiverDownload() {
        guard let url = receiverURL, let image = receiverCode(url) else { return }
        let alert = NSAlert()
        alert.messageText = "下載 iPad 接收器"
        alert.informativeText = "用 iPad 相機掃描下載碼。安裝後開啟接收器，將 iPad 以 USB-C 資料線接上這台 Mac。"
        alert.accessoryView = codeView(image)
        alert.addButton(withTitle: "完成")
        alert.runModal()
    }

    // Match the installed executable for this account. A staging copy or a
    // controller with the same name in a different directory is independent.
    static func legacyControllerIsRunning() -> Bool {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoSidecar/auto-sidecar")
            .resolvingSymlinksInPath().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "-u", String(getuid()), "auto-sidecar"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return false }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace).contains { field in
            guard let pid = pid_t(field) else { return false }
            var buffer = [CChar](repeating: 0, count: 4096)
            let size = UInt32(buffer.count)
            guard proc_pidpath(pid, &buffer, size) > 0 else { return false }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expected
        }
    }

    @MainActor
    static func printCheck() {
        let checks: [String: Bool] = [
            "hasBuiltInScreen": NSScreen.screens.contains {
                guard let id = $0.deviceDescription[.init("NSScreenNumber")] as? UInt32 else { return false }
                return CGDisplayIsBuiltin(id) != 0
            },
            "legacyControllerRunning": legacyControllerIsRunning(),
            "speakerDriverReady": (try? AudioDevices.speakerLoopback(preferBlackHole: false)) != nil,
            "postEventsGranted": CGPreflightPostEventAccess(),
            "screenCaptureGranted": CGPreflightScreenCaptureAccess(),
            "audioCaptureGranted": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        ]
        if let data = try? JSONEncoder().encode(checks) { print(String(decoding: data, as: UTF8.self)) }
    }

    @MainActor
    static func prepare() -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if legacyControllerIsRunning() {
            let alert = NSAlert()
            alert.messageText = "這台 Mac 已由 AutoSidecar 管理"
            alert.informativeText = "目前的控制器正在管理 iPad。請繼續使用原有的 AutoSidecar。要設定另一台 Mac，請在那台 Mac 開啟 AutoSidecar Companion。"
            alert.addButton(withTitle: "結束 Companion")
            app.activate(ignoringOtherApps: true)
            alert.runModal()
            return false
        }
        let key = "didPresentPortableSetup"
        guard !UserDefaults.standard.bool(forKey: key) else { return true }
        let alert = NSAlert()
        alert.messageText = "將 iPad 連到這台 Mac"
        let code = receiverURL.flatMap(receiverCode)
        let installation = code == nil
            ? "請在 iPad 開啟已安裝的 AutoSidecar 接收器。若尚未安裝，請先向此版本的提供者取得接收器。"
            : "請用 iPad 相機掃描下方的下載碼，安裝並開啟接收器。已安裝者直接開啟接收器即可。"
        alert.informativeText = """
        \(installation)

        用 USB-C 資料線接上並解鎖 iPad。若出現「信任這部電腦」，請確認。接著比對兩端的配對碼並在兩端同意。

        Mac 需要「螢幕錄製」權限來傳送桌面。「麥克風」權限供虛擬音訊裝置傳送 Mac 聲音。系統若要求重新開啟 App，請依提示操作。
        """
        let input = NSButton(checkboxWithTitle: "允許使用 iPad 的輸入裝置控制 Mac（需系統授權）", target: nil, action: nil)
        input.state = .off
        input.sizeToFit()
        if let code {
            let stack = NSStackView(views: [codeView(code), input])
            stack.orientation = .vertical
            stack.spacing = 12
            stack.setFrameSize(stack.fittingSize)
            alert.accessoryView = stack
        } else {
            alert.accessoryView = input
        }
        alert.addButton(withTitle: "開始設定")
        alert.addButton(withTitle: "稍後")
        app.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(input.state == .on, forKey: HostController.allowInputKey)
        UserDefaults.standard.set(true, forKey: key)
        return true
    }
}
