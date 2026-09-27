import AppKit
import UniformTypeIdentifiers

final class App: NSObject, NSApplicationDelegate {
    private var source: Source?
    private var options: Options
    private var sourceName = "img2text"
    private var exportButton: NSButton!
    private var copyButton: NSButton!

    private let queue = DispatchQueue(label: "img2text.render", qos: .userInitiated)
    private let rasterizer = Rasterizer(font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular))  // queue-only
    private var cache: [Int: (text: String, image: CGImage)] = [:]
    private var cacheBytes = 0
    private let cacheBudget = 256 << 20
    private var generation = 0
    private var inFlight = false
    private var waitingFor: Int?
    private var frameIndex = 0
    private var shownText = ""
    private var timer: Timer?
    private var exporting = false

    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
    private let canvas = NSImageView()
    private let message = NSTextField(labelWithString: "")
    private let modePopup = NSPopUpButton()
    private let widthSlider = NSSlider(value: 128, minValue: 20, maxValue: 300, target: nil, action: nil)
    private let widthLabel = NSTextField(labelWithString: "")
    private let thresholdSlider = NSSlider(value: 128, minValue: 0, maxValue: 255, target: nil, action: nil)
    private let thresholdLabel = NSTextField(labelWithString: "")
    private let invertCheck = NSButton(checkboxWithTitle: "Invert", target: nil, action: nil)
    private let colorCheck = NSButton(checkboxWithTitle: "Color", target: nil, action: nil)
    private let ditherPopup = NSPopUpButton()
    private let strengthSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let strengthLabel = NSTextField(labelWithString: "")
    private let charsField = NSTextField(string: "")
    private let flagsLabel = NSTextField(labelWithString: "")

    init(source: Source?, name: String?, options: Options) {
        self.source = source
        self.options = options
        if let name { sourceName = name }
    }

    private var launched = false
    private var pendingOpen: URL?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = mainMenu()
        buildUI()
        window.title = "img2text"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        launched = true
        if let url = pendingOpen { load(url) } else { rerender() }
    }

    /// Finder "Open With" and drops on the Dock icon arrive here, not in argv;
    /// they can come before launch finishes, when the controls don't exist yet.
    func application(_: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if launched { load(url) } else { pendingOpen = url }
    }

    /// Only a Quit item: without a main menu Cmd-Q does nothing.
    private func mainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit img2text", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let menu = NSMenu()
        menu.addItem(appItem)
        return menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    private func buildUI() {
        modePopup.addItems(withTitles: Mode.allCases.map(\.rawValue))
        modePopup.selectItem(withTitle: options.mode.rawValue)
        ditherPopup.addItems(withTitles: Dither.allCases.map(\.rawValue))
        ditherPopup.selectItem(withTitle: options.dither.rawValue)
        widthSlider.integerValue = options.width
        thresholdSlider.integerValue = options.threshold
        strengthSlider.doubleValue = options.strength
        invertCheck.state = options.invert ? .on : .off
        colorCheck.state = options.color ? .on : .off
        charsField.stringValue = options.chars
        charsField.placeholderString = "ascii ramp, light → dark"
        charsField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        charsField.delegate = self
        for c in [modePopup, widthSlider, thresholdSlider, invertCheck, colorCheck, ditherPopup, strengthSlider] as [NSControl] {
            c.target = self
            c.action = #selector(controlChanged)
            c.controlSize = .small
        }
        modePopup.toolTip = "-m mode"
        ditherPopup.toolTip = "-d dither"
        widthSlider.toolTip = "-w width in characters"
        thresholdSlider.toolTip = "-t ink cutoff 0–255"
        strengthSlider.toolTip = "-s dither strength 0–1"
        charsField.toolTip = "-c ascii ramp"
        let open = NSButton(title: "Open…", target: self, action: #selector(openImage))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyText))
        copyButton = copy
        copy.toolTip = "text + image on the clipboard; paste picks whichever fits"
        exportButton = NSButton(title: "Export", target: self, action: #selector(exportImage))
        let rotate = NSButton(title: "↻ 90°", target: self, action: #selector(rotateImage))
        rotate.toolTip = "-r rotate clockwise"
        for b in [open, copy, exportButton!, rotate, invertCheck, colorCheck] { b.controlSize = .small; b.font = .systemFont(ofSize: 11) }

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            return l
        }
        for l in [widthLabel, thresholdLabel, strengthLabel, flagsLabel] {
            l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            l.textColor = .secondaryLabelColor
        }
        flagsLabel.isSelectable = true
        widthLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        thresholdLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        strengthLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let row1 = NSStackView(views: [open, modePopup, ditherPopup, label("W"), widthSlider, widthLabel,
                                       invertCheck, colorCheck, rotate, copy, exportButton])
        let row2 = NSStackView(views: [label("T"), thresholdSlider, thresholdLabel,
                                       label("S"), strengthSlider, strengthLabel,
                                       label("chars"), charsField, flagsLabel])
        for r in [row1, row2] { r.orientation = .horizontal; r.spacing = 6 }
        widthSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        thresholdSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        strengthSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        charsField.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let bar = NSStackView(views: [row1, row2])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let rule = NSBox()
        rule.boxType = .separator

        canvas.imageScaling = .scaleNone
        canvas.imageAlignment = .alignTopLeft
        canvas.unregisterDraggedTypes()  // let drops fall through to the window-wide DropView
        let scroll = NSScrollView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        message.textColor = .secondaryLabelColor
        message.isSelectable = true

        let root = NSStackView(views: [bar, rule, message, scroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        for v in [bar, rule, scroll] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        let drop = DropView()
        drop.onDrop = { [weak self] url in self?.load(url) }
        drop.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: drop.topAnchor), root.bottomAnchor.constraint(equalTo: drop.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: drop.leadingAnchor), root.trailingAnchor.constraint(equalTo: drop.trailingAnchor),
        ])
        window.contentView = drop
    }

    @objc private func controlChanged() {
        options.mode = Mode(rawValue: modePopup.titleOfSelectedItem ?? "") ?? .braille
        options.width = widthSlider.integerValue
        options.threshold = thresholdSlider.integerValue
        options.invert = invertCheck.state == .on
        options.color = colorCheck.state == .on
        options.dither = Dither(rawValue: ditherPopup.titleOfSelectedItem ?? "") ?? .floyd
        options.strength = strengthSlider.doubleValue
        options.chars = charsField.stringValue
        rerender()
    }

    @objc private func rotateImage() {
        options.rotate = (options.rotate + 90) % 360
        rerender()
    }

    @objc private func openImage() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        do { source = try Source(url.path) } catch {
            source = nil
            rerender()
            show(message: "\(error)")
            return
        }
        frameIndex = 0
        sourceName = url.deletingPathExtension().lastPathComponent
        window.title = "img2text - \(url.lastPathComponent)"
        rerender()
    }

    private var isAnimated: Bool { (source?.count ?? 0) > 1 }

    private func show(message m: String) {
        message.stringValue = m
        message.isHidden = false
        canvas.image = nil
    }

    private func style(scale: CGFloat) -> Rasterizer.Style {
        var fg = CGColor(gray: 0, alpha: 1), bg = CGColor(gray: 1, alpha: 1)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            fg = NSColor.textColor.cgColor
            bg = NSColor.textBackgroundColor.cgColor
        }
        return Rasterizer.Style(fg: fg, bg: bg, scale: scale)
    }

    private func rerender() {
        widthLabel.stringValue = "\(options.width)"
        thresholdLabel.stringValue = "\(options.threshold)"
        strengthLabel.stringValue = String(format: "%.2f", options.strength)
        let binary = options.mode != .ascii
        ditherPopup.isEnabled = binary
        thresholdSlider.isEnabled = binary
        strengthSlider.isEnabled = binary && options.dither != .none
        charsField.isEnabled = !binary
        flagsLabel.stringValue = cliFlags()
        if !exporting { exportButton.title = isAnimated ? "Export GIF" : "Export PNG" }
        exportButton.isEnabled = source != nil && !exporting
        copyButton.isEnabled = source != nil

        generation += 1
        timer?.invalidate()
        cache = [:]
        cacheBytes = 0
        guard let source else { waitingFor = nil; show(message: "Drop image here, or Open"); return }
        message.isHidden = true
        frameIndex = min(frameIndex, source.count - 1)
        waitingFor = frameIndex
        request(frameIndex)
    }

    private func request(_ i: Int) {
        guard !inFlight, let source else { return }
        inFlight = true
        let gen = generation, o = options, st = style(scale: window.backingScaleFactor), raster = rasterizer
        queue.async { [weak self] in
            let out = source.render(i, o).flatMap { r in raster.draw(r, color: o.color, st).map { (r.plain, $0) } }
            DispatchQueue.main.async { self?.received(i, out, gen) }
        }
    }

    private func received(_ i: Int, _ out: (text: String, image: CGImage)?, _ gen: Int) {
        inFlight = false
        guard gen == generation else { if let w = waitingFor { request(w) }; return }
        guard let out else { show(message: "Could not decode frame \(i + 1)."); return }
        let bytes = out.image.bytesPerRow * out.image.height
        if cacheBytes + bytes <= cacheBudget {
            cache[i] = out
            cacheBytes += bytes
        }
        if waitingFor == i {
            waitingFor = nil
            display(i, out)
        }
    }

    private func display(_ i: Int, _ f: (text: String, image: CGImage)) {
        frameIndex = i
        shownText = f.text
        let img = f.image
        let scale = window.backingScaleFactor
        let size = NSSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
        canvas.image = NSImage(cgImage: img, size: size)
        if canvas.frame.size != size { canvas.setFrameSize(size) }
        guard let source, source.count > 1 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: source.delays[i], repeats: false) { [weak self] _ in self?.advance() }
    }

    private func advance() {
        guard let source else { return }
        let next = (frameIndex + 1) % source.count
        if let hit = cache[next] { display(next, hit) } else { waitingFor = next; request(next) }
    }

    @objc private func copyText() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(shownText, forType: .string)
        encode { data in
            guard let data else { return }
            pb.addTypes([self.isAnimated ? NSPasteboard.PasteboardType("com.compuserve.gif") : .png], owner: nil)
            pb.setData(data, forType: self.isAnimated ? NSPasteboard.PasteboardType("com.compuserve.gif") : .png)
        }
    }

    @objc private func exportImage() {
        let p = NSSavePanel()
        p.allowedContentTypes = [isAnimated ? .gif : .png]
        p.nameFieldStringValue = sourceName + (isAnimated ? ".gif" : ".png")
        guard p.runModal() == .OK, let url = p.url else { return }
        encode { data in
            guard let data else { self.show(message: "Export failed."); return }
            do { try data.write(to: url) } catch { self.show(message: "\(error)") }
        }
    }

    private func encode(_ done: @escaping (Data?) -> Void) {
        guard let source, !exporting else { return }
        exporting = true
        exportButton.isEnabled = false
        let animated = isAnimated, o = options, current = frameIndex
        let st = style(scale: animated ? 1 : window.backingScaleFactor)
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let raster = Rasterizer(font: font)
            let first = source.render(animated ? 0 : current, o).flatMap { raster.draw($0, color: o.color, st) }
            var data: Data? = nil
            if let first {
                let out = NSMutableData()
                let exportBudget = 512 << 20
                let perFrame = 2 * first.bytesPerRow * first.height  // measured: encoder keeps ~2× raw
                let keep = animated ? max(1, min(source.count, exportBudget / max(1, perFrame))) : 1
                let step = Double(source.count) / Double(keep)
                let type = (animated ? UTType.gif : UTType.png).identifier as CFString
                if let dest = CGImageDestinationCreateWithData(out, type, keep, nil) {
                    if animated {
                        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
                    }
                    var ok = true
                    for k in 0..<keep where ok {
                        autoreleasepool {
                            let lo = Int(Double(k) * step), hi = Int(Double(k + 1) * step)
                            let img = k == 0 ? first : source.render(lo, o).flatMap { raster.draw($0, color: o.color, st) }
                            guard let img else { ok = false; return }
                            let delay = source.delays[lo..<max(lo + 1, hi)].reduce(0, +)
                            let props = animated ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary : nil
                            CGImageDestinationAddImage(dest, img, props)
                            if animated {
                                DispatchQueue.main.async { self?.exportButton.title = "Exporting \(k + 1)/\(keep)" }
                            }
                        }
                    }
                    if ok && CGImageDestinationFinalize(dest) { data = out as Data }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.exporting = false
                self.exportButton.title = self.isAnimated ? "Export GIF" : "Export PNG"
                self.exportButton.isEnabled = self.source != nil
                done(data)
            }
        }
    }

    private func cliFlags() -> String {
        var f = ["-m \(options.mode.rawValue)", "-w \(options.width)"]
        if options.invert { f.append("--invert") }
        if !options.color { f.append("--no-color") }
        if options.rotate != 0 { f.append("-r \(options.rotate)") }
        if options.mode == .ascii {
            if options.chars != Options().chars { f.append("-c '\(options.chars)'") }
        } else {
            f.append("-d \(options.dither.rawValue)")
            if options.dither != .none { f.append("-s \(String(format: "%.2f", options.strength))") }
            f.append("-t \(options.threshold)")
        }
        return f.joined(separator: " ")
    }
}

extension App: NSTextFieldDelegate {
    func controlTextDidChange(_: Notification) { controlChanged() }
}

final class DropView: NSView {
    var onDrop: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func droppedURL(_ info: NSDraggingInfo) -> URL? {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
    }
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { droppedURL(info) == nil ? [] : .copy }
    override func prepareForDragOperation(_: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        guard let url = droppedURL(info) else { return false }
        onDrop?(url)
        return true
    }
}

func runGUI(_ args: Args) {
    let source = args.image.flatMap { try? Source($0) }
    let name = args.image.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    let app = NSApplication.shared
    let delegate = App(source: source, name: name, options: args.options)
    app.delegate = delegate
    app.run()
}
