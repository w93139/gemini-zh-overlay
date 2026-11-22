import AppKit
import ApplicationServices
import OSLog

let targetID = "com.google.GeminiMacOS"

func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
    return result
}

func nodes(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, "AXChildren") as? [AXUIElement] ?? []
}

func string(_ element: AXUIElement, _ key: String) -> String {
    attribute(element, key) as? String ?? ""
}

func name(_ element: AXUIElement) -> String {
    for key in ["AXTitle", "AXDescription", "AXValue"] {
        let value = string(element, key)
        if !value.isEmpty { return value }
    }
    return ""
}

func bounds(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, "AXPosition"), let s = attribute(element, "AXSize"),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
          size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}

func webArea(in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
    let role = string(root, "AXRole")
    if role == "AXWebArea" { return root }
    guard depth < 8, ["AXWindow","AXGroup","AXScrollArea","AXSplitGroup"].contains(role) else { return nil }
    for child in nodes(root) {
        if let found = webArea(in: child, depth: depth + 1) { return found }
    }
    return nil
}

let translations = [
    "New Conversation": "新建对话", "Conversation History": "对话历史", "Customizations": "自定义",
    "Projects": "项目", "Conversations": "对话", "No conversations yet": "暂无对话", "Settings": "设置",
    "Overview": "概览", "Review": "审查", "Files": "文件", "Terminal": "终端", "Plugins": "插件"
]
let navigation = ["New Conversation", "Conversation History", "Customizations"]
let overviewActions = ["Review", "Files", "Terminal", "Plugins"]

struct Label: Equatable {
    let key: String
    let rect: CGRect        // Quartz global coordinates, measured in points.
    let fontSize: CGFloat
    let bold: Bool
    let background: CGFloat
    let foreground: CGFloat
    var instance: String? = nil
    var translation: String? = nil
    var centered = false
    var id: String { instance ?? key }
    var displayed: String { translation ?? translations[key] ?? key }
}

func overviews(in group: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    let children = nodes(group)
    if children.contains(where: { string($0,"AXRole") == "AXPopUpButton" && name($0) == "Customize Sections" }) {
        return children
    }
    guard depth < 2 else { return [] }
    for child in children where string(child,"AXRole") == "AXGroup" {
        guard name(child).isEmpty, let r = bounds(child), r.width >= 150, r.height >= 72 else { continue }
        let result = overviews(in: child, depth: depth + 1)
        if !result.isEmpty { return result }
    }
    return []
}

func scan(_ app: AXUIElement) -> [Label] {
    guard let w = attribute(app,"AXFocusedWindow"), CFGetTypeID(w) == AXUIElementGetTypeID(),
          let web = webArea(in: w as! AXUIElement), let viewport = bounds(web),
          let url = attribute(web,"AXURL") as? URL, ["127.0.0.1","localhost","::1"].contains(url.host ?? ""),
          string(web,"AXDescription").contains("Antigravity") || string(web,"AXTitle").contains("Antigravity")
    else { return [] }
    let children = nodes(web)
    if URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.contains(where: {
        $0.name == "settingsOpen" && $0.value == "true"
    }) == true {
        return settingsLabels(in:web, viewport:viewport, url:url)
    }
    guard !children.contains(where: { ["AXSheet","AXMenu","AXDialog"].contains(string($0,"AXRole")) || string($0,"AXSubrole") == "AXApplicationDialog" }) else { return [] }
    let sidebar = children.first { string($0,"AXRole") == "AXGroup" && name($0) == "Sidebar" }
    var labels: [Label] = []
    let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
    let mouse = NSEvent.mouseLocation
    let pointer = CGPoint(x: mouse.x, y: screenTop - mouse.y)

    func add(_ key: String, _ control: CGRect, _ region: CGRect,
             scale: CGFloat, textFrame: CGRect? = nil, heading: Bool = false, right: Bool = false) {
        let small = heading || key == "Overview" || key == "No conversations yet"
        let size = (small ? 12.0 : 14.0) * scale
        let weight: NSFont.Weight = heading || key == "Overview" || key == "New Conversation" ? .semibold : .regular
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let englishWidth = ceil((key as NSString).size(withAttributes: [.font:font]).width)
        let height = (small ? 18.0 : 21.0) * scale
        let x = textFrame?.minX ?? (heading ? control.minX : control.minX + 30 * scale)
        let centerY = textFrame?.midY ?? (heading ? control.minY + 8 * scale : control.midY)
        let width = max(englishWidth + 5 * scale, textFrame?.width ?? 0)
        let rect = CGRect(x:x - scale, y:centerY - height/2, width:width + 2*scale, height:height)
            .intersection(region).intersection(viewport)
        guard !rect.isNull, rect.width >= size * 2, rect.height >= size else { return }
        let hover = control.contains(pointer) && !small
        let bg: CGFloat = hover ? 44 : (right || key == "New Conversation" ? 28 : 22)
        let fg: CGFloat = key == "No conversations yet" ? 126 : (small ? 142 : (key == "New Conversation" ? 204 : 175))
        labels.append(Label(key:key, rect:rect, fontSize:size, bold:weight == .semibold, background:bg, foreground:fg))
    }

    if let sidebar, let region = bounds(sidebar), region.width > 100 {
        let items = nodes(sidebar)
        let firstLinks = items.filter { string($0,"AXRole") == "AXLink" }.prefix(3)
        for item in firstLinks {
            let key = name(item)
            guard navigation.contains(key), let row = bounds(item), row.width > 80,
                  let leaf = nodes(item).first(where:{string($0,"AXRole") == "AXStaticText" && name($0) == key}),
                  let rect = bounds(leaf) else { continue }
            add(key,row,region,scale:row.height/32,textFrame:rect)
        }
        let scale = firstLinks.first.flatMap(bounds).map{$0.height/32} ?? 1
        guard scale >= 0.5, scale <= 3 else { return [] }
        for item in items {
            let role = string(item,"AXRole")
            guard ["AXHeading","AXButton","AXStaticText"].contains(role) else { continue }
            let key = name(item)
            if role == "AXHeading", ["Projects","Conversations"].contains(key),
               let button = nodes(item).first(where:{string($0,"AXRole") == "AXButton"}), let r = bounds(button) {
                add(key,r,region,scale:scale,heading:true)
            } else if role == "AXButton", key == "Settings", let row = bounds(item), row.width > 80 {
                add(key,row,region,scale:scale)
            } else if role == "AXStaticText", key == "No conversations yet", let r = bounds(item) {
                add(key,r,region,scale:scale,textFrame:r)
            }
        }
    }

    let rightItems = overviews(in:web)
    if let heading = rightItems.first(where:{string($0,"AXRole") == "AXStaticText" && name($0) == "Overview"}),
       let titleRect = bounds(heading) {
        let scale = titleRect.height / 16
        add("Overview", titleRect, viewport, scale:scale, textFrame:titleRect, right:true)
        for item in rightItems where ["AXButton","AXPopUpButton"].contains(string(item,"AXRole")) {
            let key = name(item)
            guard overviewActions.contains(key), let r = bounds(item), r.width > 80,
                  r.minY >= titleRect.minY, abs(r.minX - titleRect.minX) < 25 * scale else { continue }
            add(key,r,viewport,scale:scale,right:true)
        }
    }
    return labels
}

final class Surface: NSView {
    var label: Label? { didSet { if oldValue != label { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        guard let label else { return }
        let text = label.displayed
        NSColor(deviceWhite:label.background / 255, alpha:1).setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key:Any] = [
            .font: NSFont.systemFont(ofSize:label.fontSize, weight:label.bold ? .semibold : .regular),
            .foregroundColor: NSColor(deviceWhite:label.foreground / 255, alpha:1)
        ]
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.alignment = label.centered ? .center : .left
        var attrs = attributes
        attrs[.paragraphStyle] = style
        let area = bounds.insetBy(dx:1, dy:0)
        let size = (text as NSString).boundingRect(with:CGSize(width:area.width,height:.greatestFiniteMagnitude),
            options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attrs).size
        let height = min(bounds.height,ceil(size.height))
        let frame = CGRect(x:area.minX,y:(bounds.height-height)/2,width:area.width,height:height)
        (text as NSString).draw(with:frame,options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attrs)

    }
}

final class Controller: NSObject, NSApplicationDelegate {
    var panels: [String:NSPanel] = [:]
    var status: NSStatusItem!
    let info = NSMenuItem(title:"等待 Gemini",action:nil,keyEquivalent:"")
    var timer: Timer?
    var paused = false

    func applicationDidFinishLaunching(_ note: Notification) {
        status = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        status.button?.title = "译"
        status.button?.toolTip = "Gemini 中文侧栏"
        let menu = NSMenu()
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(withTitle:"暂停覆盖",action:#selector(toggle(_:)),keyEquivalent:"").target = self
        menu.addItem(withTitle:"退出中文覆盖",action:#selector(stop),keyEquivalent:"").target = self
        status.menu = menu
        let options = ["AXTrustedCheckOptionPrompt":true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector:#selector(frontChanged(_:)),
            name:NSWorkspace.didActivateApplicationNotification,object:nil)
        timer = Timer.scheduledTimer(withTimeInterval:0.4,repeats:true) { [weak self] _ in self?.tick() }
        tick()
    }

    @objc func toggle(_ sender:NSMenuItem) {
        paused.toggle()
        sender.title = paused ? "恢复覆盖" : "暂停覆盖"
        tick()
    }
    @objc func frontChanged(_ notification: Notification) { tick() }
    @objc func stop() { NSApp.terminate(nil) }
    private let logger = Logger(subsystem:"local.gemini.zh-sidebar", category:"status")
    func updateStatus(_ message:String) {
        if info.title != message { logger.info("\(message, privacy: .public)") }
        info.title = message
        status.button?.toolTip = message
    }
    func hide(_ message:String) {
        for panel in panels.values where panel.isVisible { panel.orderOut(nil) }
        updateStatus(message)
    }
    @objc func tick() {
        guard !paused else { hide("中文覆盖已暂停"); return }
        guard AXIsProcessTrusted() else { hide("等待辅助功能授权"); return }
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == targetID else {
            hide("等待 Gemini 切到前台"); return
        }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app,0.2)
        let labels = scan(app)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier else {
            hide("等待 Gemini 切到前台"); return
        }
        let active = Set(labels.map(\.id))
        for key in panels.keys.filter({ !active.contains($0) }) { panels.removeValue(forKey:key)?.orderOut(nil) }
        guard let top = NSScreen.screens.first?.frame.maxY else { return }
        for label in labels {
            let r = label.rect
            let frame = CGRect(x:r.minX,y:top-r.maxY,width:r.width,height:r.height)
            let panel: NSPanel
            if let existing = panels[label.id] { panel = existing }
            else {
                panel = NSPanel(contentRect:frame, styleMask:[.borderless,.nonactivatingPanel],
                                backing:.buffered, defer:false)
                panel.title = label.displayed
                panel.level = .floating
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.hasShadow = false
                panel.animationBehavior = .none
                panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
                panel.contentView = Surface(frame:CGRect(origin:.zero,size:frame.size))
                panels[label.id] = panel
            }
            if panel.title != label.displayed { panel.title = label.displayed }
            if panel.frame != frame { panel.setFrame(frame,display:false) }
            (panel.contentView as? Surface)?.label = label
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        updateStatus(labels.isEmpty ? "等待 Antigravity 界面" : "已覆盖 \(active.count) 个界面标签")
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = Controller()
application.delegate = controller
application.run()
