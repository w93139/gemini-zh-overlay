import AppKit
import ApplicationServices

private let strings: [String:String] = {
    guard let url = Bundle.main.url(forResource:"Settings.zh-Hans",withExtension:"json"),
          let data = try? Data(contentsOf:url),
          let dictionary = try? JSONDecoder().decode([String:String].self,from:data) else { return [:] }
    return dictionary
}()

private func translate(_ source: String) -> String? {
    let text = source.trimmingCharacters(in:.whitespacesAndNewlines)
    if let value = strings[text] ?? strings[text.lowercased().capitalized] { return value }
    if text.hasPrefix("Your Plan: ") { return "当前方案：" + text.dropFirst(11) }
    for (limit, localized) in [("weekly","每周"),("5-hour","五小时")] {
        let prefix = "You have used some of your " + limit + " limit, it will fully refresh in "
        if text.hasPrefix(prefix) {
            var time = String(text.dropFirst(prefix.count).dropLast(text.hasSuffix(".") ? 1 : 0))
            for (unit,zh) in [("days","天"),("day","天"),("hours","小时"),("hour","小时"),("minutes","分钟"),("minute","分钟")] {
                time = time.replacingOccurrences(of:" " + unit, with:zh)
            }
            return localized + "额度已部分使用，将在" + time.replacingOccurrences(of:", ",with:"") + "后恢复。"
        }
    }
    if text.hasSuffix(" Weekly Limit") { return String(text.dropLast(13)) + " 每周额度" }
    return nil
}

private func findDialogs(_ node: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    let current = string(node,"AXSubrole") == "AXApplicationDialog" ? [node] : []
    guard depth < 6 else { return current }
    return current + nodes(node).filter { ["AXGroup","AXSheet"].contains(string($0,"AXRole")) }
        .flatMap { findDialogs($0,depth:depth+1) }
}

func settingsLabels(in web: AXUIElement, viewport: CGRect, url: URL) -> [Label] {
    let dialogs = findDialogs(web)
    guard let dialog = dialogs.last, let modal = bounds(dialog) else { return [] }
    let clip = modal.insetBy(dx:2,dy:2).intersection(viewport)
    let section = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?
        .first(where:{$0.name == "settingsScreen"})?.value
    var result: [Label] = []
    var popup: CGRect?
    var menuItems: [Label] = []
    func walk(_ e: AXUIElement, id: String, parentRole: String, parentFrame: CGRect, clip: CGRect, depth: Int) {
        guard depth < 12 else { return }
        let role = string(e,"AXRole")
        // Editable fields can contain paths, keys, and user-authored text.
        if string(e,"AXSubrole") == "AXSwitch" { return }
        if ["AXTextField","AXTextArea","AXWebArea","AXImage","AXSlider","AXColorWell"].contains(role) { return }
        guard let r = bounds(e) else { return }
        if role == "AXList", parentFrame.width > 60, parentFrame.height > 20 {
            let items = nodes(e)
            guard !items.isEmpty, parentFrame.height < modal.height else { return }
            popup = parentFrame.intersection(clip)
            for (i,item) in items.enumerated() {
                guard let row = bounds(item) else { continue }
                let raw = name(item)
                let nextTop = i+1 < items.count ? bounds(items[i+1])?.minY : nil
                let bottom = min(nextTop ?? parentFrame.maxY-4,parentFrame.maxY-4)
                let box = CGRect(x:parentFrame.minX+5,y:row.minY,width:parentFrame.width-10,height:bottom-row.minY)
                guard box.height >= 12, box.intersects(clip), let text = translate(raw) else { continue }
                menuItems.append(Label(key:raw,rect:box.intersection(clip),fontSize:13,bold:false,
                    background:34,foreground:208,instance:"menu/\(i)",translation:text))
            }
            return
        }
        if ["AXStaticText","AXButton","AXCheckBox","AXRadioButton"].contains(role) {
            let text = name(e)
            guard let zh = translate(text), !r.intersection(clip).isEmpty else { return }
            let isText = role == "AXStaticText"
            // Icon-only buttons have accessible names but no visible label.
            if !isText && (r.width < 36 || text == "Close" || text == "Copy path") { return }
            let inNav = r.minX < modal.minX + 25
            let isHeading = parentRole == "AXHeading"
            let isToggle = role == "AXCheckBox" || role == "AXRadioButton"
            let selected = (attribute(e,"AXValue") as? NSNumber)?.boolValue == true
            let activeNav = inNav && !isText && section?.lowercased() == text.lowercased()
            let bg: CGFloat = inNav ? (activeNav ? 49 : 22) :
                (isToggle ? (selected ? 46 : 23) : (parentRole == "AXComboBox" || !isText ? 44 : 16))
            let size: CGFloat = isText ? (r.height >= 22 && isHeading ? 20 : (r.height <= 16 ? 12 : (r.height > 26 ? 12 : 14))) : 14
            let font = NSFont.systemFont(ofSize:size, weight:isHeading ? .semibold : .regular)
            let translatedWidth = ceil((zh as NSString).size(withAttributes:[.font:font]).width)
            var rect = r
            if isText {
                // WebKit reports the glyph bounds for static labels, including wrapped text.
                rect.size.width = min(max(r.width+2,translatedWidth+3), max(r.width+2, parentFrame.maxX-r.minX))
                if rect.width > r.width+24 && text.count > 30 { rect.size.width = r.width+2 }
            } else {
                rect = r.insetBy(dx:inNav ? 8 : 3,dy:3)
            }
            // Leave rounded modal corners and clipped rows to the host application.
            guard clip.contains(CGPoint(x:rect.midX,y:rect.midY)) else { return }
            let visible = rect.intersection(clip)
            guard visible.width >= 15, visible.height >= 11 else { return }
            result.append(Label(key:text,rect:visible,fontSize:size,bold:isHeading,
                background:bg,foreground:isHeading || !isText || size >= 14 ? 207 : 155,
                instance:id,translation:zh,centered:!isText && !inNav))
            return
        }
        for (index,child) in nodes(e).enumerated() {
            let childClip = role == "AXScrollArea" ? clip.intersection(r) : clip
            walk(child,id:"\(id)/\(index)",parentRole:role,parentFrame:r,clip:childClip,depth:depth+1)
        }
    }
    walk(dialog,id:"settings",parentRole:"",parentFrame:modal,clip:clip,depth:0)
    if let popup { result.removeAll { $0.rect.intersects(popup) } }
    return result + menuItems
}
