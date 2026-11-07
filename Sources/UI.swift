import AppKit
import UniformTypeIdentifiers

let internalDrag = NSPasteboard.PasteboardType("local.phonecommander.rows")
let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"; return f }()
func human(_ n: UInt64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file; return f.string(fromByteCount: Int64(n))
}

final class KeyTable: NSTableView {
    weak var panel: Panel?
    override func becomeFirstResponder() -> Bool { panel?.activated(); return super.becomeFirstResponder() }
    override func menu(for e: NSEvent) -> NSMenu? {
        guard let p = panel else { return nil }
        window?.makeFirstResponder(self)
        let r = row(at: convert(e.locationInWindow, from: nil))
        if r >= 0 && !selectedRowIndexes.contains(r) { selectRowIndexes([r], byExtendingSelection: false) }
        return p.main?.contextMenu()
    }
    override func keyDown(with e: NSEvent) {
        guard let p = panel else { return super.keyDown(with: e) }
        if e.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch e.characters {
            case "+": p.main?.selectMask(); return
            case "-": p.main?.deselectMask(); return
            case "*": p.invertSelection(); return
            default: break
            }
        }
        switch e.keyCode {
        case 53: p.clearQuick()
        case 36, 76: p.openCurrent()
        case 51: p.goUp()
        case 48: p.main?.switchPanel()
        case 49: p.toggleCurrent()
        case 99: p.main?.view()
        case 120: p.main?.renameItem()
        case 96: p.main?.transfer(move: false)
        case 97: p.main?.transfer(move: true)
        case 98: p.main?.makeDir()
        case 100: p.main?.deleteItems()
        default: super.keyDown(with: e)
        }
    }
}

final class Panel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var main: MainController?
    var fs: FileSystem = LocalFS()
    var path = NSHomeDirectory()
    var all: [FileItem] = []
    var rows: [FileItem] = []
    var mediaOnly = false
    var dirSizes: [String: UInt64] = [:]
    var showHidden = false
    var back: [String] = [], forward: [String] = []
    private var loadID = 0

    let view = NSView()
    let drive = NSPopUpButton()
    let pathLabel = NSTextField(labelWithString: "")
    let quick = NSSearchField()
    let filter = NSButton(checkboxWithTitle: "Только фото и видео", target: nil, action: nil)
    let table = KeyTable()
    let scroll = NSScrollView()
    let status = NSTextField(labelWithString: "")
    private var icons: [String: NSImage] = [:]

    override init() {
        super.init()
        table.panel = self
        table.dataSource = self; table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.style = .plain
        table.doubleAction = #selector(doubleClick); table.target = self
        for (id, title, w) in [("name", "Имя", 300.0), ("size", "Размер", 85.0), ("date", "Дата", 125.0)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = w
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.registerForDraggedTypes([.fileURL, internalDrag])
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder

        drive.target = self; drive.action = #selector(driveChanged)
        filter.target = self; filter.action = #selector(filterChanged)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.drawsBackground = true
        pathLabel.font = .boldSystemFont(ofSize: 12)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        quick.placeholderString = "Фильтр"; quick.delegate = self
        quick.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let top = NSStackView(views: [drive, quick, filter]); top.orientation = .horizontal; top.distribution = .fill
        drive.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filter.setContentHuggingPriority(.required, for: .horizontal)
        let st = NSStackView(views: [top, pathLabel, scroll, status])
        st.orientation = .vertical; st.alignment = .leading; st.spacing = 4
        st.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(st)
        NSLayoutConstraint.activate([
            st.topAnchor.constraint(equalTo: view.topAnchor), st.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            st.leadingAnchor.constraint(equalTo: view.leadingAnchor), st.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top.widthAnchor.constraint(equalTo: st.widthAnchor), pathLabel.widthAnchor.constraint(equalTo: st.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: st.widthAnchor), status.widthAnchor.constraint(equalTo: st.widthAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    func setActive(_ a: Bool) {
        pathLabel.backgroundColor = a ? .selectedContentBackgroundColor : .clear
        pathLabel.textColor = a ? .white : .labelColor
    }
    func activated() { main?.setActive(self) }

    // Диски
    func rebuildDrives() {
        drive.removeAllItems()
        let add: (String, String) -> Void = { t, p in self.drive.addItem(withTitle: t); self.drive.lastItem?.representedObject = p }
        add("Домашняя папка", NSHomeDirectory())
        add("Рабочий стол", NSHomeDirectory() + "/Desktop")
        add("Загрузки", NSHomeDirectory() + "/Downloads")
        add("Macintosh HD", "/")
        for v in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] where v.path != "/" {
            add(v.lastPathComponent, v.path)
        }
        if let ph = main?.phone {
            add("📱 " + (ph.name ?? "iPhone: разблокируйте и нажмите «Доверять»"), "phone:")
            if fs.isPhone { drive.selectItem(at: drive.numberOfItems - 1) }
        }
        if !fs.isPhone, let i = drive.itemArray.firstIndex(where: { ($0.representedObject as? String) == path }) { drive.selectItem(at: i) }
    }
    @objc func driveChanged() {
        guard let p = drive.selectedItem?.representedObject as? String else { return }
        if p == "phone:" { connectPhone() } else { fs = LocalFS(); navigate(p); clearHistory() }
        main?.window.makeFirstResponder(table)
    }
    func connectPhone() {
        guard let ph = main?.phone else { return }
        do { fs = try PhoneFS(udid: ph.udid); navigate("/DCIM") }
        catch { main?.alert(error.localizedDescription); fs = LocalFS(); navigate(NSHomeDirectory()) }
        clearHistory()
    }
    func phoneGone() { if fs.isPhone { fs = LocalFS(); navigate(NSHomeDirectory()); clearHistory() } }
    func clearHistory() { back = []; forward = [] }
    func goBack() { if let p = back.popLast() { forward.append(path); navigate(p, record: false) } }
    func goForward() { if let p = forward.popLast() { back.append(path); navigate(p, record: false) } }

    // Навигация
    func navigate(_ p: String, select: String? = nil, record: Bool = true) {
        if p != path {
            if record { back.append(path); forward = [] }
            quick.stringValue = ""
        }
        path = p
        dirSizes = [:]
        pathLabel.stringValue = (fs.isPhone ? "iPhone: " : "") + p
        status.stringValue = "Загрузка…"
        loadID += 1; let id = loadID, f = fs
        DispatchQueue.global(qos: .userInitiated).async {
            let res = Result { try f.list(p) }
            DispatchQueue.main.async {
                guard id == self.loadID else { return }
                switch res {
                case .success(let l): self.all = l
                case .failure(let e): self.all = []; self.status.stringValue = e.localizedDescription
                }
                self.refilter(select: select)
                if case .failure(let e) = res { self.status.stringValue = e.localizedDescription }
            }
        }
    }
    func reload() {
        let keep = selected.first?.name ?? currentItem?.name
        navigate(path, select: keep)
    }
    func refilter(select: String? = nil) {
        let q = quick.stringValue
        var l = all.filter { (showHidden || !$0.name.hasPrefix(".")) && (!mediaOnly || $0.isDir || isMedia($0.name))
            && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
        let d = table.sortDescriptors.first
        let key = d?.key ?? "name", asc = d?.ascending ?? true
        l.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }
            let r: Bool
            switch key {
            case "size": r = a.size == b.size ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.size < b.size
            case "date": r = (a.mtime ?? .distantPast) < (b.mtime ?? .distantPast)
            default: r = a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return asc ? r : !r
        }
        if path != fs.root { l.insert(FileItem(name: "..", path: parent(path), isDir: true, size: 0, mtime: nil, isUp: true), at: 0) }
        rows = l
        table.reloadData()
        let i = select.flatMap { s in rows.firstIndex { $0.name == s } } ?? 0
        if !rows.isEmpty { table.selectRowIndexes([i], byExtendingSelection: false); table.scrollRowToVisible(i) }
        updateStatus()
    }
    @objc func filterChanged() { mediaOnly = filter.state == .on; refilter() }
    func controlTextDidChange(_ n: Notification) { refilter() }
    func controlTextDidBeginEditing(_ n: Notification) { activated() }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy s: Selector) -> Bool {
        switch s {
        case #selector(NSResponder.cancelOperation(_:)): clearQuick(); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)): main?.window.makeFirstResponder(table); return true
        default: return false
        }
    }
    func clearQuick() {
        if !quick.stringValue.isEmpty { quick.stringValue = ""; refilter(select: currentItem?.name) }
        main?.window.makeFirstResponder(table)
    }
    func select(where test: (FileItem) -> Bool, add: Bool) {
        var s = table.selectedRowIndexes
        for (i, it) in rows.enumerated() where !it.isUp && test(it) { if add { s.insert(i) } else { s.remove(i) } }
        table.selectRowIndexes(s, byExtendingSelection: false)
    }
    func invertSelection() {
        var s = IndexSet()
        for (i, it) in rows.enumerated() where !it.isUp && !table.selectedRowIndexes.contains(i) { s.insert(i) }
        table.selectRowIndexes(s, byExtendingSelection: false)
    }
    func updateStatus() {
        let s = selected
        let files = rows.filter { !$0.isUp }
        let total = files.reduce(0) { $0 + size(of: $1) }
        status.stringValue = "Выбрано \(s.count) (\(human(s.reduce(0) { $0 + size(of: $1) }))) из \(files.count), всего \(human(total))"
    }
    func size(of it: FileItem) -> UInt64 { it.isDir ? dirSizes[it.path] ?? 0 : it.size }

    /// Считает размер выбранных папок, а если выбранных нет, то всех папок в панели.
    func calcSizes() {
        var dirs = selected.filter { $0.isDir && !$0.isLink }
        if dirs.isEmpty { dirs = rows.filter { $0.isDir && !$0.isUp && !$0.isLink } }
        if dirs.isEmpty { return }
        var f = fs
        if fs.isPhone {
            guard let ph = main?.phone, let c = try? PhoneFS(udid: ph.udid) else { return }
            f = c  // отдельное подключение, чтобы панель не ждала подсчёта
        }
        let id = loadID, counter = f
        status.stringValue = "Подсчёт размера…"
        DispatchQueue.global(qos: .userInitiated).async {
            for (i, d) in dirs.enumerated() {
                let n = folderSize(counter, d.path)
                DispatchQueue.main.async {
                    guard id == self.loadID else { return }
                    self.dirSizes[d.path] = n
                    self.table.reloadData()
                    self.updateStatus()
                    if i + 1 < dirs.count { self.status.stringValue = "Подсчёт размера… \(i + 1) из \(dirs.count)" }
                }
                var stale = false
                DispatchQueue.main.sync { stale = id != self.loadID }
                if stale { return }
            }
        }
    }
    var selected: [FileItem] { table.selectedRowIndexes.compactMap { $0 < rows.count && !rows[$0].isUp ? rows[$0] : nil } }
    var currentItem: FileItem? { let r = table.selectedRow; return r >= 0 && r < rows.count ? rows[r] : nil }

    @objc func doubleClick() { if table.clickedRow >= 0 { openCurrent() } }
    func openCurrent() {
        guard let it = currentItem else { return }
        if it.isUp { goUp() } else if it.isDir { navigate(it.path) } else { main?.view() }
    }
    func goUp() {
        guard path != fs.root else { return }
        navigate(parent(path), select: (path as NSString).lastPathComponent)
    }
    func toggleCurrent() {
        if let it = currentItem, it.isDir, !it.isUp { return calcSizes() }
        let r = table.selectedRowIndexes.max() ?? 0
        if r + 1 < rows.count { table.selectRowIndexes([r + 1], byExtendingSelection: true); table.scrollRowToVisible(r + 1) }
    }

    // Таблица
    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let it = rows[row], id = col!.identifier
        let cell = t.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView(); c.identifier = id
            let tf = NSTextField(labelWithString: ""); tf.lineBreakMode = .byTruncatingMiddle
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf); c.textField = tf
            var lead = 2.0
            if id.rawValue == "name" {
                let iv = NSImageView(); iv.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(iv); c.imageView = iv; lead = 22
                NSLayoutConstraint.activate([iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                                             iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                                             iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16)])
            } else if id.rawValue == "size" { tf.alignment = .right }
            NSLayoutConstraint.activate([tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: lead),
                                         tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                                         tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
            return c
        }()
        switch id.rawValue {
        case "name": cell.textField?.stringValue = it.name; cell.imageView?.image = icon(it)
        case "size": cell.textField?.stringValue = it.isDir ? dirSizes[it.path].map(human) ?? "" : human(it.size)
        default: cell.textField?.stringValue = it.mtime.map(dateFmt.string) ?? ""
        }
        return cell
    }
    private func icon(_ it: FileItem) -> NSImage {
        let key = it.isDir ? "/" : (it.name as NSString).pathExtension.lowercased()
        if let i = icons[key] { return i }
        let ws = NSWorkspace.shared
        let i = it.isDir ? ws.icon(for: .folder) : ws.icon(for: UTType(filenameExtension: key) ?? .data)
        icons[key] = i
        return i
    }
    func tableViewSelectionDidChange(_ n: Notification) { updateStatus() }
    func tableView(_ t: NSTableView, typeSelectStringFor col: NSTableColumn?, row: Int) -> String? {
        col?.identifier.rawValue == "name" ? rows[row].name : nil
    }
    func tableView(_ t: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) { refilter() }

    // Перетаскивание
    func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard !rows[row].isUp else { return nil }
        let p = NSPasteboardItem()
        p.setString(rows[row].path, forType: internalDrag)
        if !fs.isPhone { p.setString(URL(fileURLWithPath: rows[row].path).absoluteString, forType: .fileURL) }
        return p
    }
    func tableView(_ t: NSTableView, validateDrop info: NSDraggingInfo, proposedRow r: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        if (info.draggingSource as? KeyTable) === table { return [] }
        t.setDropRow(-1, dropOperation: .on)
        return .copy
    }
    func tableView(_ t: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        if let other = (info.draggingSource as? KeyTable)?.panel {
            main?.setActive(other); main?.transfer(move: false); return true
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let local = LocalFS()
        let items = urls.compactMap { local.stat($0.path) }
        if items.isEmpty { return false }
        main?.startTransfer(src: local, items: items, dest: self, move: false)
        return true
    }
}

final class MainController: NSObject, NSWindowDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let left = Panel(), right = Panel()
    var active: Panel!
    var phone: PhoneInfo?
    private var inactive: Panel { active === left ? right : left }
    private var watching = false

    override init() {
        super.init()
        left.main = self; right.main = self; active = left
        window.title = "Phone Commander"
        window.minSize = NSSize(width: 800, height: 420)
        window.setFrameAutosaveName("main")
        window.delegate = self
        let split = NSStackView(views: [left.view, right.view])
        split.orientation = .horizontal; split.distribution = .fillEqually; split.spacing = 8

        let btns: [(String, Selector)] = [("F2 Имя", #selector(renameItem)), ("F3 Просмотр", #selector(view)), ("F5 Копия", #selector(copyBtn)),
                                          ("F6 Перенос", #selector(moveBtn)), ("F7 Папка", #selector(makeDir)), ("F8 Удалить", #selector(deleteItems)),
                                          ("Размер папок", #selector(sizesBtn)), ("AirDrop на iPhone", #selector(airDrop))]
        let bar = NSStackView(views: btns.map { NSButton(title: $0.0, target: self, action: $0.1) })
        bar.orientation = .horizontal; bar.distribution = .fillEqually
        let root = NSStackView(views: [split, bar])
        root.orientation = .vertical; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        root.alignment = .centerX
        split.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -16).isActive = true
        bar.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -16).isActive = true
        window.contentView = root

        left.path = NSHomeDirectory(); right.path = NSHomeDirectory()
        for p in [left, right] { p.rebuildDrives(); p.navigate(p.path) }
        setActive(left)
        window.makeFirstResponder(left.table)
        window.center(); window.makeKeyAndOrderFront(nil)
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.left.rebuildDrives(); self?.right.rebuildDrives() }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    private func poll() {
        guard !watching else { return }
        watching = true
        DispatchQueue.global(qos: .utility).async {
            let p = Phone.detect()
            DispatchQueue.main.async {
                self.watching = false
                let wasConnected = self.phone?.name != nil
                let changed = p?.udid != self.phone?.udid || p?.name != self.phone?.name
                self.phone = p
                guard changed else { return }
                if p == nil { self.left.phoneGone(); self.right.phoneGone() }
                self.left.rebuildDrives(); self.right.rebuildDrives()
                if !wasConnected, p?.name != nil, !self.left.fs.isPhone, !self.right.fs.isPhone {
                    self.right.connectPhone(); self.right.rebuildDrives()
                }
            }
        }
    }
    func setActive(_ p: Panel) { active = p; left.setActive(p === left); right.setActive(p === right) }
    func switchPanel() { window.makeFirstResponder(inactive.table) }

    func alert(_ text: String, info: String = "") {
        let a = NSAlert(); a.messageText = text; a.informativeText = info; a.beginSheetModal(for: window)
    }
    private func ask(_ text: String, info: String = "", ok: String, accessory: NSView? = nil) -> Bool {
        let a = NSAlert(); a.messageText = text; a.informativeText = info
        a.addButton(withTitle: ok); a.addButton(withTitle: "Отмена"); a.accessoryView = accessory
        return a.runModal() == .alertFirstButtonReturn
    }
    private func prompt(_ text: String, value: String, ok: String, allowSlash: Bool = false) -> String? {
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); tf.stringValue = value
        let a = NSAlert(); a.messageText = text; a.addButton(withTitle: ok); a.addButton(withTitle: "Отмена"); a.accessoryView = tf
        a.window.initialFirstResponder = tf
        let stem = (value as NSString).deletingPathExtension as NSString
        RunLoop.main.perform(inModes: [.modalPanel, .default]) {  // как в Finder: выделено имя без расширения
            tf.currentEditor()?.selectedRange = NSRange(location: 0, length: stem.length)
        }
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let s = tf.stringValue.trimmingCharacters(in: .whitespaces)
        return s.isEmpty || (!allowSlash && s.contains("/")) ? nil : s
    }
    @objc func sizesBtn() { active.calcSizes() }
    @objc func refresh() { active.reload() }
    @objc func openItem() { active.openCurrent() }
    @objc func toggleHidden() { active.showHidden.toggle(); active.refilter(select: active.currentItem?.name) }
    @objc func focusFilter() { window.makeFirstResponder(active.quick) }
    @objc func goBack() { active.goBack() }
    @objc func goForward() { active.goForward() }
    @objc func goUp() { active.goUp() }
    @objc func goHome() {
        if active.fs.isPhone { active.fs = LocalFS(); active.navigate(NSHomeDirectory()); active.clearHistory(); active.rebuildDrives() }
        else { active.navigate(NSHomeDirectory()) }
    }
    @objc func goToPath() {
        guard var p = prompt("Перейти к папке", value: active.path, ok: "Перейти", allowSlash: true) else { return }
        p = (p as NSString).expandingTildeInPath
        guard active.fs.stat(p)?.isDir == true else { return alert("Папка не найдена", info: p) }
        active.navigate(p)
    }
    @objc func swapPanels() {
        let (f, p) = (left.fs, left.path)
        left.fs = right.fs; right.fs = f
        let rp = right.path
        for (x, np) in [(left, rp), (right, p)] { x.navigate(np); x.clearHistory(); x.rebuildDrives() }
    }
    @objc func sameFolder() {
        let o = inactive
        o.fs = active.fs; o.navigate(active.path); o.clearHistory(); o.rebuildDrives()
    }
    @objc func selectAllRows() { active.select(where: { _ in true }, add: true) }
    @objc func deselectAll() { active.table.deselectAll(nil) }
    @objc func invert() { active.invertSelection() }
    @objc func selectMedia() { active.select(where: { !$0.isDir && isMedia($0.name) }, add: true) }
    @objc func selectMask() { if let m = prompt("Выделить по маске", value: "*.jpg;*.heic;*.mov", ok: "Выделить") { active.select(where: { matchesMask($0.name, m) }, add: true) } }
    @objc func deselectMask() { if let m = prompt("Снять выделение по маске", value: "*.aae", ok: "Снять") { active.select(where: { matchesMask($0.name, m) }, add: false) } }
    @objc func copyPath() {
        let l = active.selected.map { $0.path }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((l.isEmpty ? [active.path] : l).joined(separator: "\n"), forType: .string)
    }
    private func macOnly() -> Bool {
        if active.fs.isPhone { alert("Эта команда работает только с файлами на Mac") }
        return !active.fs.isPhone
    }
    @objc func revealInFinder() {
        guard macOnly() else { return }
        let l = active.selected.map { URL(fileURLWithPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(l.isEmpty ? [URL(fileURLWithPath: active.path)] : l)
    }
    @objc func openTerminal() {
        guard macOnly() else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: active.path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
    @objc func showInfo() {
        guard let it = active.currentItem, !it.isUp else { return }
        let f = active.fs
        var s = "Путь: \(it.path)\nТип: \(it.isDir ? "папка" : (it.name as NSString).pathExtension.uppercased())"
        s += "\nИзменён: \(it.mtime.map(dateFmt.string) ?? "нет данных")"
        if !it.isDir { return alert(it.name, info: s + "\nРазмер: \(human(it.size)) (\(it.size) байт)") }
        let id = ph(f)
        DispatchQueue.global(qos: .userInitiated).async {
            let n = folderSize(id, it.path)
            DispatchQueue.main.async { self.alert(it.name, info: s + "\nРазмер: \(human(n)) (\(n) байт)") }
        }
    }
    /// Для долгих операций на iPhone нужно отдельное подключение, чтобы панель не ждала.
    private func ph(_ f: FileSystem) -> FileSystem {
        if f.isPhone, let p = phone, let c = try? PhoneFS(udid: p.udid) { return c }
        return f
    }
    @objc func duplicate() {
        guard macOnly() else { return }
        let items = active.selected, p = active!, f = active.fs
        if items.isEmpty { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var errs: [String] = []; var last: String?
            for it in items {
                let t = uniquePath(f, it.path, word: "копия")
                do { try FileManager.default.copyItem(atPath: it.path, toPath: t); last = (t as NSString).lastPathComponent } catch { errs.append(error.localizedDescription) }
            }
            DispatchQueue.main.async {
                p.navigate(p.path, select: last)
                if !errs.isEmpty { self.alert("Не всё скопировано", info: errs.prefix(5).joined(separator: "\n")) }
            }
        }
    }
    @objc func makeZip() {
        guard macOnly() else { return }
        let items = active.selected, p = active!
        if items.isEmpty { return alert("Сначала выберите файлы") }
        let base = items.count == 1 ? items[0].name : "Архив"
        let out = uniquePath(p.fs, join(p.path, base + ".zip"))
        p.status.stringValue = "Создаю архив…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try zipItems(dir: p.path, names: items.map { $0.name }, out: out)
                DispatchQueue.main.async { p.navigate(p.path, select: (out as NSString).lastPathComponent) }
            } catch { DispatchQueue.main.async { self.alert(error.localizedDescription); p.updateStatus() } }
        }
    }
    func contextMenu() -> NSMenu {
        let m = NSMenu()
        let add: (String, Selector) -> Void = { t, s in m.addItem(withTitle: t, action: s, keyEquivalent: "").target = self }
        add("Открыть", #selector(openItem)); add("Просмотр", #selector(view)); add("Свойства", #selector(showInfo))
        m.addItem(.separator())
        add("Копировать в другую панель", #selector(copyBtn)); add("Перенести в другую панель", #selector(moveBtn))
        add("AirDrop на iPhone", #selector(airDrop))
        m.addItem(.separator())
        add("Переименовать", #selector(renameItem)); add("Групповое переименование", #selector(batchRename))
        add("Дублировать", #selector(duplicate)); add("Сжать в ZIP", #selector(makeZip)); add("Удалить", #selector(deleteItems))
        m.addItem(.separator())
        add("Посчитать размер папок", #selector(sizesBtn)); add("Новая папка", #selector(makeDir))
        add("Показать в Finder", #selector(revealInFinder)); add("Копировать путь", #selector(copyPath))
        return m
    }
    @objc func copyBtn() { transfer(move: false) }
    @objc func moveBtn() { transfer(move: true) }

    func transfer(move: Bool) {
        let items = active.selected
        if items.isEmpty { return alert("Сначала выберите файлы") }
        startTransfer(src: active.fs, items: items, dest: inactive, move: move, source: active)
    }

    func startTransfer(src: FileSystem, items: [FileItem], dest: Panel, move: Bool, source: Panel? = nil) {
        if src.isPhone && dest.fs.isPhone { return alert("Копирование внутри iPhone не поддерживается") }
        if !src.isPhone && !dest.fs.isPhone {
            for it in items where dest.path == it.path || dest.path.hasPrefix(it.path + "/") || parent(it.path) == dest.path {
                return alert("Источник и папка назначения совпадают")
            }
        }
        if move && src.isPhone, let bad = items.first(where: { Phone.isProtected($0.path) }) {
            return alert("С iPhone можно только копировать эту папку", info: "Удаление из \(bad.path) напрямую сломало бы медиатеку. Скопируйте файлы (F5), а лишнее удалите в приложении «Фото» на телефоне.")
        }
        if dest.fs.isPhone {
            let a = NSAlert()
            a.messageText = "Как отправить на iPhone?"
            a.informativeText = "В приложение «Фото» файлы попадают только через AirDrop. Запись по кабелю сохранит их в память iPhone, но они будут видны только в Phone Commander."
            a.addButton(withTitle: "AirDrop в «Фото»")
            if !Phone.isProtected(dest.path) { a.addButton(withTitle: "Записать в папку") }
            a.addButton(withTitle: "Отмена")
            let r = a.runModal()
            if r == .alertFirstButtonReturn { return sendAirDrop(items) }
            if Phone.isProtected(dest.path) || r != .alertSecondButtonReturn { return }
        }
        let box = NSStackView(); box.orientation = .vertical; box.alignment = .leading
        box.frame = NSRect(x: 0, y: 0, width: 340, height: 58)
        let pop = NSPopUpButton(); pop.addItems(withTitles: ["Такой же файл есть: пропустить", "Заменить существующие", "Сохранить оба"])
        let chk = NSButton(checkboxWithTitle: "Только фото и видео (без .AAE и прочего)", target: nil, action: nil)
        chk.state = src.isPhone ? .on : .off
        box.addArrangedSubview(pop); box.addArrangedSubview(chk)
        let what = items.count == 1 ? "«\(items[0].name)»" : "объектов: \(items.count)"
        let where_ = (dest.fs.isPhone ? "iPhone: " : "") + dest.path
        guard ask((move ? "Перенести " : "Скопировать ") + what, info: "В \(where_)", ok: move ? "Перенести" : "Копировать", accessory: box) else { return }
        let t = Transfer(src: src, dst: dest.fs, items: items, dstDir: dest.path, move: move,
                         conflict: Conflict(rawValue: pop.indexOfSelectedItem) ?? .skipSame, mediaOnly: chk.state == .on)
        run(t, srcPanel: source, dest: dest)
    }

    /// Для копирования панели держат своё подключение, поэтому передаче нужно отдельное.
    private func run(_ t0: Transfer, srcPanel: Panel?, dest: Panel) {
        var t = t0
        if t.src.isPhone || t.dst.isPhone, let ph = phone {
            do {
                let conn = try PhoneFS(udid: ph.udid)
                t = Transfer(src: t.src.isPhone ? conn : t.src, dst: t.dst.isPhone ? conn : t.dst, items: t.items, dstDir: t.dstDir,
                             move: t.move, conflict: t.conflict, mediaOnly: t.mediaOnly)
            } catch { return alert(error.localizedDescription) }
        }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
        let title = NSTextField(labelWithString: "Подготовка…"); title.lineBreakMode = .byTruncatingMiddle
        let bar = NSProgressIndicator(); bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1; bar.style = .bar
        let info = NSTextField(labelWithString: "")
        let handler = CancelTarget { t.cancel() }
        let cancel = NSButton(title: "Отмена", target: handler, action: #selector(CancelTarget.fire))
        let st = NSStackView(views: [title, bar, info, cancel]); st.orientation = .vertical; st.alignment = .leading
        st.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        sheet.contentView = st
        for v in [title, bar, info] { v.widthAnchor.constraint(equalTo: st.widthAnchor, constant: -32).isActive = true }
        window.beginSheet(sheet)
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let rep = t.run { p in
                DispatchQueue.main.async {
                    _ = handler
                    title.stringValue = p.name.isEmpty ? "Подсчёт файлов…" : p.name
                    let frac = p.totalBytes > 0 ? Double(p.doneBytes) / Double(p.totalBytes) : 0
                    bar.doubleValue = frac
                    let sec = Date().timeIntervalSince(started)
                    let speed = sec > 0.5 ? Double(p.doneBytes) / sec : 0
                    let left = speed > 0 ? Int(Double(p.totalBytes - min(p.doneBytes, p.totalBytes)) / speed) : 0
                    info.stringValue = "\(p.doneFiles) из \(p.totalFiles) · \(human(p.doneBytes)) из \(human(p.totalBytes)) · \(human(UInt64(speed)))/с · осталось \(left / 60) мин \(left % 60) с"
                }
            }
            DispatchQueue.main.async {
                self.window.endSheet(sheet); sheet.orderOut(nil)
                srcPanel?.reload(); dest.reload()
                self.report(rep)
            }
        }
    }
    private func report(_ r: TransferReport) {
        var s = "Скопировано: \(r.copied) (\(human(r.bytes)))"
        if r.skipped > 0 { s += "\nПропущено, уже есть: \(r.skipped)" }
        if r.empty > 0 { s += "\nПустых файлов на iPhone (оригинал в iCloud): \(r.empty)" }
        if !r.failed.isEmpty {
            s += "\nОшибок: \(r.failed.count)\n" + r.failed.prefix(8).map { "• \(($0.0 as NSString).lastPathComponent): \($0.1)" }.joined(separator: "\n")
        }
        alert(r.cancelled ? "Копирование остановлено" : (r.failed.isEmpty ? "Готово" : "Готово, но с ошибками"), info: s)
    }

    @objc func view() {
        guard let it = active.currentItem else { return }
        if it.isDir { return active.openCurrent() }
        if !active.fs.isPhone { NSWorkspace.shared.open(URL(fileURLWithPath: it.path)); return }
        guard let ph = phone else { return }
        let dir = NSTemporaryDirectory() + "PhoneCommanderView"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let local = LocalFS()
            do {
                let conn = try PhoneFS(udid: ph.udid)
                let r = Transfer(src: conn, dst: local, items: [it], dstDir: dir, move: false, conflict: .replace, mediaOnly: false).run { _ in }
                DispatchQueue.main.async {
                    if r.copied == 1 { NSWorkspace.shared.open(URL(fileURLWithPath: join(dir, it.name))) }
                    else { self.alert("Файл не открыть", info: r.empty > 0 ? "Файл пустой: его оригинал хранится в iCloud." : r.failed.first?.1 ?? "") }
                }
            } catch { DispatchQueue.main.async { self.alert(error.localizedDescription) } }
        }
    }
    @objc func renameItem() {
        if active.selected.count > 1 { return batchRename() }
        guard let it = active.currentItem, !it.isUp, let n = prompt("Новое имя", value: it.name, ok: "Переименовать"), n != it.name else { return }
        doRename([(it, n)])
    }
    private func doRename(_ plan: [(FileItem, String)]) {
        if let p = renameProblem(plan, existing: active.all.map { $0.name }) { return alert("Переименование отменено", info: p) }
        let errs = applyRenames(active.fs, plan)
        active.navigate(active.path, select: plan.last?.1)
        if !errs.isEmpty { alert("Не всё переименовано", info: errs.prefix(6).joined(separator: "\n")) }
    }
    @objc func batchRename() {
        let items = active.selected
        if items.isEmpty { return alert("Сначала выберите файлы") }
        let form = BatchForm(items)
        let a = NSAlert()
        a.messageText = "Групповое переименование: \(items.count)"
        a.informativeText = "[N] имя, [C] счётчик, [D] дата, [T] время. Например, «[D] [T]» даст имя вида 2026-11-06 21.07.30. Расширение сохраняется."
        a.addButton(withTitle: "Переименовать"); a.addButton(withTitle: "Отмена")
        a.accessoryView = form.view
        a.window.initialFirstResponder = form.pattern
        guard a.runModal() == .alertFirstButtonReturn else { return }
        doRename(form.plan)
    }
    @objc func makeDir() {
        guard let n = prompt("Новая папка", value: "", ok: "Создать") else { return }
        do { try active.fs.mkdir(join(active.path, n)); active.navigate(active.path, select: n) }
        catch { alert(error.localizedDescription) }
    }
    @objc func deleteItems() {
        let items = active.selected
        if items.isEmpty { return }
        let phoneFS = active.fs.isPhone
        if phoneFS, items.contains(where: { Phone.isProtected($0.path) }) {
            return alert("Эта папка iPhone защищена", info: "Фото удаляйте в приложении «Фото» на телефоне, иначе медиатека может повредиться.")
        }
        let what = items.count == 1 ? "«\(items[0].name)»" : "объектов: \(items.count)"
        guard ask("Удалить \(what)?", info: phoneFS ? "С iPhone файлы удаляются безвозвратно." : "Файлы будут перемещены в Корзину.", ok: "Удалить") else { return }
        var errs: [String] = []
        for it in items { do { try active.fs.remove(it.path) } catch { errs.append(error.localizedDescription) } }
        active.reload()
        if !errs.isEmpty { alert("Не всё удалено", info: errs.prefix(5).joined(separator: "\n")) }
    }
    @objc func airDrop() {
        if active.fs.isPhone { return alert("AirDrop отправляет файлы с Mac", info: "Перейдите в панель с папкой на Mac и выберите фото или видео.") }
        sendAirDrop(active.selected)
    }
    private func sendAirDrop(_ items: [FileItem]) {
        var urls: [URL] = []
        for it in items {
            if it.isDir, let e = FileManager.default.enumerator(at: URL(fileURLWithPath: it.path), includingPropertiesForKeys: nil) {
                for case let u as URL in e where isMedia(u.lastPathComponent) { urls.append(u) }
            } else if !it.isDir { urls.append(URL(fileURLWithPath: it.path)) }
        }
        guard !urls.isEmpty else { return alert("Выберите фото или видео") }
        guard let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else {
            return alert("AirDrop недоступен", info: "Включите Wi-Fi и Bluetooth на Mac и iPhone.")
        }
        s.perform(withItems: urls)
    }
    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }
}

final class BatchForm: NSObject, NSTextFieldDelegate {
    let items: [FileItem]
    let pattern = NSTextField(string: "[N]"), find = NSTextField(string: ""), repl = NSTextField(string: ""), start = NSTextField(string: "1")
    let preview = NSTextField(wrappingLabelWithString: "")
    let view: NSView
    var plan: [(FileItem, String)] { renamePlan(items, pattern: pattern.stringValue, find: find.stringValue, replace: repl.stringValue, start: Int(start.stringValue) ?? 1) }
    init(_ i: [FileItem]) {
        items = i
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Шаблон"), pattern], [NSTextField(labelWithString: "Найти"), find],
                                      [NSTextField(labelWithString: "Заменить на"), repl], [NSTextField(labelWithString: "Счётчик с"), start]])
        grid.column(at: 1).width = 300
        let st = NSStackView(views: [grid, preview]); st.orientation = .vertical; st.alignment = .leading
        st.frame = NSRect(x: 0, y: 0, width: 400, height: 215)
        preview.preferredMaxLayoutWidth = 400; preview.font = .systemFont(ofSize: 11)
        view = st
        super.init()
        for f in [pattern, find, repl, start] { f.delegate = self }
        update()
    }
    func controlTextDidChange(_ n: Notification) { update() }
    func update() {
        let p = plan
        let rows = p.prefix(4).map { "\($0.0.name) → \($0.1)" }.joined(separator: "\n")
        preview.stringValue = rows + (p.count > 4 ? "\n…и ещё \(p.count - 4)" : "")
    }
}

final class CancelTarget: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func fire() { f() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var main: MainController!
    func applicationDidFinishLaunching(_ n: Notification) {
        let bar = NSMenu()
        main = MainController()
        let fk: (Int) -> String = { String(UnicodeScalar(UInt32($0))!) }
        let cmd: NSEvent.ModifierFlags = .command, sh: NSEvent.ModifierFlags = [.command, .shift], opt: NSEvent.ModifierFlags = [.command, .option]
        let sep = ("", nil as Selector?, "", NSEvent.ModifierFlags())
        let table: [(String, [(String, Selector?, String, NSEvent.ModifierFlags)])] = [
            ("Файл", [("Открыть", #selector(MainController.openItem), "o", cmd), ("Просмотр", #selector(MainController.view), fk(NSF3FunctionKey), []),
                      ("Свойства", #selector(MainController.showInfo), "i", cmd), sep,
                      ("Копировать в другую панель", #selector(MainController.copyBtn), fk(NSF5FunctionKey), []),
                      ("Перенести в другую панель", #selector(MainController.moveBtn), fk(NSF6FunctionKey), []),
                      ("AirDrop на iPhone", #selector(MainController.airDrop), "", []), sep,
                      ("Новая папка", #selector(MainController.makeDir), "n", sh),
                      ("Переименовать", #selector(MainController.renameItem), fk(NSF2FunctionKey), []),
                      ("Групповое переименование", #selector(MainController.batchRename), "m", sh),
                      ("Дублировать", #selector(MainController.duplicate), "d", cmd), ("Сжать в ZIP", #selector(MainController.makeZip), "z", sh),
                      ("Удалить", #selector(MainController.deleteItems), "\u{8}", cmd)]),
            ("Выделение", [("Выделить все", #selector(MainController.selectAllRows), "a", cmd), ("Снять выделение", #selector(MainController.deselectAll), "a", sh),
                           ("Инвертировать", #selector(MainController.invert), "i", sh), sep,
                           ("Выделить по маске…", #selector(MainController.selectMask), "=", cmd), ("Снять по маске…", #selector(MainController.deselectMask), "-", cmd),
                           ("Выделить фото и видео", #selector(MainController.selectMedia), "p", sh)]),
            ("Вид", [("Обновить", #selector(MainController.refresh), "r", cmd), ("Фильтр по имени", #selector(MainController.focusFilter), "f", cmd),
                     ("Скрытые файлы", #selector(MainController.toggleHidden), ".", sh), ("Посчитать размер папок", #selector(MainController.sizesBtn), "s", sh), sep,
                     ("Поменять панели местами", #selector(MainController.swapPanels), "u", cmd), ("Та же папка в другой панели", #selector(MainController.sameFolder), "=", sh)]),
            ("Переход", [("Назад", #selector(MainController.goBack), "[", cmd), ("Вперёд", #selector(MainController.goForward), "]", cmd),
                         ("На уровень вверх", #selector(MainController.goUp), fk(NSUpArrowFunctionKey), cmd), ("Домашняя папка", #selector(MainController.goHome), "h", sh),
                         ("Перейти к папке…", #selector(MainController.goToPath), "l", cmd), sep,
                         ("Показать в Finder", #selector(MainController.revealInFinder), "r", sh), ("Открыть в Терминале", #selector(MainController.openTerminal), "t", sh),
                         ("Копировать путь", #selector(MainController.copyPath), "c", opt)]),
        ]
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let m = NSMenu(); appItem.submenu = m
        m.addItem(withTitle: "Скрыть", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        m.addItem(withTitle: "Выйти из Phone Commander", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); bar.addItem(editItem)
        let e = NSMenu(title: "Правка"); editItem.submenu = e
        e.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        e.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        e.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        for (title, rows) in table {
            let holder = NSMenuItem(); bar.addItem(holder)
            let menu = NSMenu(title: title); holder.submenu = menu
            for (t, s, k, mods) in rows {
                if s == nil { menu.addItem(.separator()); continue }
                let it = menu.addItem(withTitle: t, action: s, keyEquivalent: k)
                it.keyEquivalentModifierMask = mods; it.target = main
            }
        }
        NSApp.mainMenu = bar
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--uitest") { runUITest(main) }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                let v = self.main.window.contentView!
                let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                print("left:", self.main.left.pathLabel.stringValue, self.main.left.rows.count, "| right:", self.main.right.pathLabel.stringValue, self.main.right.rows.count, "|", self.main.right.status.stringValue)
                NSApp.terminate(nil)
            }
        }
    }
}
