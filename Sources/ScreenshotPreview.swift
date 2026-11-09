import AppKit

/// Keeps the original pixels, rather than copying the downscaled thumbnail.
struct ScreenshotAsset {
    let url: URL
    let image: NSImage
    let bitmap: NSBitmapImageRep
    let originalData: Data
    var pixelSize: NSSize { NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh) }

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
            throw NSError(domain: "ScreenshotPreview", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取这张截图，请检查原图片文件是否仍在本机。"])
        }
        self.url = url; originalData = data; self.bitmap = bitmap
        image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        image.addRepresentation(bitmap)
    }

    @MainActor func copy(to pasteboard: NSPasteboard = .general) throws {
        // Advertise image data, not a file URL: chat apps and editors should paste a picture.
        let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let png = originalData.starts(with: signature) ? originalData : bitmap.representation(using: .png, properties: [:])
        guard let png, let tiff = bitmap.tiffRepresentation else {
            throw NSError(domain: "ScreenshotPreview", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "图片未能复制，请重试或打开原图。"])
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw NSError(domain: "ScreenshotPreview", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法写入剪贴板，请重试。"])
        }
    }
}

@MainActor final class ScreenshotPreview {
    static let shared = ScreenshotPreview()
    private var windows: [URL: ScreenshotWindowController] = [:]

    func open(_ url: URL) throws {
        let key = url.standardizedFileURL
        if let existing = windows[key] {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = try ScreenshotWindowController(url: key)
        controller.didClose = { [weak self] in self?.windows.removeValue(forKey: key) }
        windows[key] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.fitImage(nil)
    }
}

/// Center a zoomed-out image without changing its document size or feeding layout back into SwiftUI.
private final class ScreenshotClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        if rect.width > documentView.frame.width { rect.origin.x = (documentView.frame.width - rect.width) / 2 }
        if rect.height > documentView.frame.height { rect.origin.y = (documentView.frame.height - rect.height) / 2 }
        return rect
    }
}

@MainActor final class ScreenshotWindowController: NSWindowController, NSWindowDelegate {
    let asset: ScreenshotAsset
    let scrollView = NSScrollView()
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let copyLabel = NSTextField(labelWithString: "")
    private var followsWindow = true
    private var magnificationObservation: NSKeyValueObservation?
    var didClose: (() -> Void)?

    init(url: URL) throws {
        asset = try ScreenshotAsset(url: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "会议截图 · \(url.lastPathComponent)"
        window.representedURL = url
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 660, height: 400)
        window.delegate = self
        if let screen = NSScreen.main {
            window.setContentSize(NSSize(width: min(1050, screen.visibleFrame.width * 0.9),
                                         height: min(760, screen.visibleFrame.height * 0.85)))
        }
        window.center()

        let root = NSView(); window.contentView = root
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal; toolbar.spacing = 10
        toolbar.addArrangedSubview(button("缩小", action: #selector(zoomOut(_:)), key: "-"))
        toolbar.addArrangedSubview(zoomLabel)
        toolbar.addArrangedSubview(button("放大", action: #selector(zoomIn(_:)), key: "+"))
        toolbar.addArrangedSubview(button("适应窗口", action: #selector(fitImage(_:)), key: "0"))
        toolbar.addArrangedSubview(button("100% 原图", action: #selector(actualSize(_:)), key: "1"))
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)
        toolbar.addArrangedSubview(button("复制图片", action: #selector(copyImage(_:)), key: "c"))
        toolbar.addArrangedSubview(button("打开原图", action: #selector(openOriginal(_:))))
        zoomLabel.alignment = .center
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        zoomLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true

        scrollView.contentView = ScreenshotClipView()
        scrollView.hasHorizontalScroller = true; scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01; scrollView.maxMagnification = 8
        scrollView.backgroundColor = .windowBackgroundColor
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: asset.pixelSize))
        imageView.image = asset.image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.setAccessibilityLabel("会议截图原图")
        let menu = NSMenu()
        let item = NSMenuItem(title: "复制图片", action: #selector(copyImage(_:)), keyEquivalent: "")
        item.target = self; menu.addItem(item); imageView.menu = menu
        scrollView.documentView = imageView
        let footer = NSStackView()
        let hint = NSTextField(labelWithString: "\(Int(asset.pixelSize.width)) × \(Int(asset.pixelSize.height)) · 双指缩放，滚动查看 · ⌘C 复制图片")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        copyLabel.font = .systemFont(ofSize: 11); copyLabel.textColor = .secondaryLabelColor
        footer.addArrangedSubview(hint); footer.addArrangedSubview(copyLabel); footer.spacing = 16
        for view in [toolbar, scrollView, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
        magnificationObservation = scrollView.observe(\.magnification, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateZoomLabel() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(userZoom(_:)),
                                               name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func button(_ title: String, action: Selector, key: String = "") -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded; b.keyEquivalent = key
        if !key.isEmpty { b.keyEquivalentModifierMask = .command }
        return b
    }
    private func updateZoomLabel() { zoomLabel.stringValue = "\(Int((scrollView.magnification * 100).rounded()))%" }
    private func zoom(to value: CGFloat) {
        scrollView.magnification = max(scrollView.minMagnification, min(scrollView.maxMagnification, value))
        updateZoomLabel()
    }
    @objc func fitImage(_ sender: Any?) {
        followsWindow = true
        window?.contentView?.layoutSubtreeIfNeeded()
        let size = scrollView.contentSize
        guard size.width > 0, size.height > 0 else { return }
        zoom(to: min(1, min(size.width / asset.pixelSize.width, size.height / asset.pixelSize.height)))
    }
    @objc func actualSize(_ sender: Any?) { followsWindow = false; zoom(to: 1) }
    @objc func zoomIn(_ sender: Any?) { followsWindow = false; zoom(to: scrollView.magnification * 1.25) }
    @objc func zoomOut(_ sender: Any?) { followsWindow = false; zoom(to: scrollView.magnification / 1.25) }
    @objc private func userZoom(_ notification: Notification) { followsWindow = false }
    @objc func copyImage(_ sender: Any?) {
        do { try asset.copy(); copyLabel.stringValue = "已复制，可在其他应用粘贴" }
        catch { NSApp.presentError(error) }
    }
    @objc private func openOriginal(_ sender: Any?) { NSWorkspace.shared.open(asset.url) }
    func windowDidResize(_ notification: Notification) { if followsWindow { fitImage(nil) } }
    func windowWillClose(_ notification: Notification) { didClose?() }
}
