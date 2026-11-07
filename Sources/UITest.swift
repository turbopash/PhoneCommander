import AppKit

/// Прогон интерфейса в окне без диалогов: настоящие события клавиш и меню на временной папке.
func runUITest(_ m: MainController) {
    var bad = 0
    func ok(_ c: Bool, _ s: String) { print((c ? "OK   " : "FAIL ") + s); if !c { bad += 1 } }
    let fm = FileManager.default
    let raw = NSTemporaryDirectory() + "pc_ui_\(getpid())"
    try! fm.createDirectory(atPath: raw + "/Папка", withIntermediateDirectories: true)
    let tmp = String(cString: realpath(raw, nil))
    for n in ["a.jpg", "b.MOV", "c.txt", ".hid", "Папка/x.jpg"] { fm.createFile(atPath: join(tmp, n), contents: Data("12345".utf8)) }
    let p = m.left
    func key(_ code: UInt16, _ ch: String) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                 characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
        p.table.keyDown(with: e)
    }
    func menuKey(_ ch: String, _ mods: NSEvent.ModifierFlags) -> Bool {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: m.window.windowNumber, context: nil,
                                 characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: 0)!
        return NSApp.mainMenu!.performKeyEquivalent(with: e)
    }
    func names() -> [String] { p.rows.map { $0.name } }
    var steps: [() -> Void] = []
    steps.append { m.setActive(p); m.window.makeFirstResponder(p.table); p.navigate(tmp) }
    steps.append {
        ok(names() == ["..", "Папка", "a.jpg", "b.MOV", "c.txt"], "список \(names())")
        var seen = Set<String>(); var dup: [String] = []; var dead: [String] = []
        for top in NSApp.mainMenu!.items { for it in top.submenu?.items ?? [] where !it.isSeparatorItem {
            if let a = it.action, let t = it.target as? MainController, !t.responds(to: a) { dead.append(it.title) }
            if !it.keyEquivalent.isEmpty, !seen.insert("\(it.keyEquivalent)|\(it.keyEquivalentModifierMask.rawValue)").inserted { dup.append(it.title) }
        } }
        ok(dead.isEmpty, "у пунктов меню есть обработчики \(dead)")
        ok(dup.isEmpty, "сочетания не повторяются \(dup)")
        let cm = m.contextMenu()
        ok(cm.items.filter { !$0.isSeparatorItem }.allSatisfy { ($0.target as? NSObject)?.responds(to: $0.action!) == true }, "контекстное меню")
        key(67, "*"); ok(p.selected.count == 4, "инверсия * \(p.selected.count)")
        m.deselectAll(); ok(p.selected.isEmpty, "снять выделение")
        m.selectMedia(); ok(p.selected.map { $0.name }.sorted() == ["a.jpg", "b.MOV"], "выделить медиа")
        m.deselectAll()
        ok(menuKey("a", .command) && p.selected.count == 4, "⌘A из меню \(p.selected.count)")
        m.deselectAll()
        ok(menuKey(".", [.command, .shift]) && names().contains(".hid"), "⌘⇧. показывает скрытые")
        m.toggleHidden(); ok(!names().contains(".hid"), "скрытые выключены")
        p.quick.stringValue = "b"; p.refilter(); ok(names() == ["..", "b.MOV"], "фильтр \(names())")
        key(53, "\u{1b}"); ok(p.quick.stringValue.isEmpty && names().count == 5, "Esc сбрасывает фильтр")
        ok(menuKey("f", .command), "⌘F")
        ok(m.window.firstResponder === p.quick.currentEditor(), "⌘F ставит курсор в фильтр")
        p.clearQuick()
        p.table.selectRowIndexes([1], byExtendingSelection: false); key(36, "\r")
    }
    steps.append {
        ok(p.path == tmp + "/Папка" && names() == ["..", "x.jpg"], "Enter открывает папку")
        ok(menuKey("[", .command), "⌘[")
    }
    steps.append {
        ok(p.path == tmp, "назад \(p.path)")
        m.goForward()
    }
    steps.append {
        ok(p.path == tmp + "/Папка", "вперёд"); key(51, "\u{7f}")
    }
    steps.append {
        ok(p.path == tmp && p.currentItem?.name == "Папка", "Backspace вверх, курсор на папке")
        m.copyPath(); ok(NSPasteboard.general.string(forType: .string) == tmp + "/Папка", "копировать путь")
        key(49, " ")
    }
    steps.append {
        ok(p.dirSizes[tmp + "/Папка"] == 5, "Пробел считает папку \(p.dirSizes)")
        p.table.selectRowIndexes([2], byExtendingSelection: false); m.duplicate()
    }
    steps.append {
        ok(names().contains("a копия.jpg"), "дублировать \(names())")
        p.table.selectRowIndexes([2, 3], byExtendingSelection: false); m.makeZip()
    }
    steps.append {
        ok(names().contains("Архив.zip"), "ZIP \(names())")
        fm.createFile(atPath: tmp + "/new.txt", contents: nil); ok(menuKey("r", .command), "⌘R")
    }
    steps.append {
        ok(names().contains("new.txt"), "обновление")
        let before = (m.left.path, m.right.path, m.right.fs.isPhone)
        ok(menuKey("u", .command), "⌘U")
        ok(m.right.path == before.0 && m.left.path == before.1 && m.left.fs.isPhone == before.2, "панели поменялись")
        m.swapPanels()
    }
    steps.append {
        p.table.selectRowIndexes([2, 3], byExtendingSelection: false)
        let f = BatchForm(p.selected); f.pattern.stringValue = "z[C]"; f.update()
        ok(f.preview.stringValue.contains("→ z001"), "предпросмотр группового имени \(f.preview.stringValue)")
        ok(p.path == tmp, "панели вернулись")
        try? fm.removeItem(atPath: tmp)
        print(bad == 0 ? "ИНТЕРФЕЙС: ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ" : "ИНТЕРФЕЙС: ОШИБОК \(bad)")
        fflush(stdout); exit(bad == 0 ? 0 : 1)
    }
    func next(_ i: Int) {
        guard i < steps.count else { return }
        steps[i]()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { next(i + 1) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { next(0) }
}
