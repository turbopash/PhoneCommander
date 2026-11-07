import Foundation

/// Проверка движка на подключённом iPhone: работает только в своей временной папке /PhoneCommanderTest.
func runSelfTest() -> Int32 {
    var bad = 0
    func ok(_ c: Bool, _ s: String) { print((c ? "OK   " : "FAIL ") + s); if !c { bad += 1 } }
    let local = LocalFS()
    let tmp = NSTemporaryDirectory() + "pc_selftest_\(getpid())"
    try! FileManager.default.createDirectory(atPath: tmp + "/Папка с пробелом/вложенная", withIntermediateDirectories: true)
    let body = Data((0..<3_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let name = "Лёва фото 1.JPG"
    try! body.write(to: URL(fileURLWithPath: tmp + "/Папка с пробелом/вложенная/" + name))
    try! Data("x".utf8).write(to: URL(fileURLWithPath: tmp + "/Папка с пробелом/заметка.AAE"))
    let old = Date(timeIntervalSince1970: 1_600_000_000)
    local.setMTime(tmp + "/Папка с пробелом/вложенная/" + name, old)
    let srcDir = local.stat(tmp + "/Папка с пробелом")!

    // Mac -> Mac, фильтр медиа, пропуск повтора
    let d1 = tmp + "/out1"; try! local.mkdir(d1)
    var r = Transfer(src: local, dst: local, items: [srcDir], dstDir: d1, move: false, conflict: .skipSame, mediaOnly: true).run { _ in }
    ok(r.copied == 1 && r.failed.isEmpty, "Mac→Mac только медиа: \(r.copied)")
    ok(!FileManager.default.fileExists(atPath: d1 + "/Папка с пробелом/заметка.AAE"), "AAE отфильтрован")
    r = Transfer(src: local, dst: local, items: [srcDir], dstDir: d1, move: false, conflict: .skipSame, mediaOnly: true).run { _ in }
    ok(r.skipped == 1 && r.copied == 0, "повтор пропущен")
    r = Transfer(src: local, dst: local, items: [srcDir], dstDir: d1, move: false, conflict: .keepBoth, mediaOnly: true).run { _ in }
    ok(FileManager.default.fileExists(atPath: d1 + "/Папка с пробелом/вложенная/Лёва фото 1 (1).JPG"), "сохранить оба")

    // Маски и групповое переименование
    ok(matchesMask("IMG_1.JPG", "*.jpg;*.mov") && matchesMask("a.MOV", "*.jpg;*.mov") && !matchesMask("a.AAE", "*.jpg"), "маски")
    ok(matchesMask("Лёва 1.jpg", "лёва") && !matchesMask("x.jpg", ""), "маска как часть имени")
    let rdir = tmp + "/ren"; try! local.mkdir(rdir)
    for n in ["a.JPG", "b.JPG", "c.txt"] { try! Data("1".utf8).write(to: URL(fileURLWithPath: join(rdir, n))) }
    local.setMTime(join(rdir, "a.JPG"), old); local.setMTime(join(rdir, "b.JPG"), old)
    var rl = try! local.list(rdir).filter { $0.name.hasSuffix("JPG") }.sorted { $0.name < $1.name }
    var pl = renamePlan(rl, pattern: "Фото [C] [N]", find: "a", replace: "z", start: 5)
    ok(pl.map { $0.1 } == ["Фото 005 z.JPG", "Фото 006 b.JPG"], "шаблон \(pl.map { $0.1 })")
    ok(renameProblem(renamePlan(rl, pattern: "[D] [T]", find: "", replace: "", start: 1), existing: ["a.JPG", "b.JPG"])?.contains("[C]") == true, "одинаковая дата даёт отказ")
    ok(renameProblem(renamePlan([rl[0]], pattern: "c", find: "", replace: "", start: 1) + [(rl[1], "C.TXT")], existing: ["a.JPG", "b.JPG", "c.txt"]) != nil, "занятое имя не перезаписывается")
    ok(renameProblem([(rl[0], "x/y.JPG")], existing: []) != nil, "слэш в имени запрещён")
    ok(applyRenames(local, pl).isEmpty && local.stat(join(rdir, "Фото 005 z.JPG")) != nil, "групповое переименование на Mac")
    rl = try! local.list(rdir).filter { $0.name.hasPrefix("Фото 006") }
    pl = [(rl[0], "ФОТО 006 b.JPG")]
    ok(renameProblem(pl, existing: ["Фото 006 b.JPG"]) == nil && applyRenames(local, pl).isEmpty && (try! local.list(rdir)).contains { $0.name == "ФОТО 006 b.JPG" }, "смена регистра")
    ok(uniquePath(local, join(rdir, "c.txt"), word: "копия").hasSuffix("c копия.txt"), "имя копии")
    do {
        try zipItems(dir: rdir, names: ["c.txt", "ФОТО 006 b.JPG"], out: tmp + "/a.zip")
        let z = Process(); z.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); z.arguments = ["-tq", tmp + "/a.zip"]
        z.standardOutput = FileHandle.nullDevice; try z.run(); z.waitUntilExit()
        ok(z.terminationStatus == 0, "ZIP создан и читается")
    } catch { ok(false, "ZIP: \(error)") }

    guard let info = Phone.detect(), info.name != nil, let phone = try? PhoneFS(udid: info.udid) else {
        print("iPhone недоступен, тест телефона пропущен"); return 2
    }
    print("Устройство: \(info.name!)")
    ok(((try? phone.list("/DCIM")) ?? []).count > 0, "чтение /DCIM")
    let t0 = Date(); let dcim = folderSize(phone, "/DCIM")
    print("Размер /DCIM: \(dcim) байт за \(Int(Date().timeIntervalSince(t0))) с")
    ok(dcim > 0, "размер папки на iPhone")
    ok(folderSize(local, tmp + "/Папка с пробелом") == UInt64(body.count) + 1, "размер папки на Mac")
    // защита
    ok((try? phone.mkdir("/DCIM/pc_test")) == nil, "запись в DCIM запрещена")
    ok((try? phone.remove("/DCIM/176APPLE")) == nil, "удаление из DCIM запрещено")
    ok((try? phone.openWrite("/PhotoData/x")) == nil, "запись в PhotoData запрещена")
    ok((try? phone.remove("/")) == nil, "удаление корня запрещено")

    let base = "/PhoneCommanderTest"
    if phone.stat(base) != nil { try? phone.remove(base) }
    do {
        try phone.mkdir(base)
        r = Transfer(src: local, dst: phone, items: [srcDir], dstDir: base, move: false, conflict: .skipSame, mediaOnly: false).run { _ in }
        ok(r.copied == 2 && r.failed.isEmpty, "Mac→iPhone: \(r.copied) \(r.failed)")
        let up = phone.stat(base + "/Папка с пробелом/вложенная/" + name)
        ok(up?.size == UInt64(body.count), "размер на iPhone")
        ok(up?.mtime.map { abs($0.timeIntervalSince(old)) < 2 } == true, "дата на iPhone сохранена")
        ok(phone.stat(base + "/Папка с пробелом/вложенная/" + name + ".part") == nil, "нет .part")

        let d2 = tmp + "/out2"; try local.mkdir(d2)
        r = Transfer(src: phone, dst: local, items: [phone.stat(base + "/Папка с пробелом")!], dstDir: d2, move: false, conflict: .skipSame, mediaOnly: false).run { _ in }
        ok(r.copied == 2, "iPhone→Mac: \(r.copied) \(r.failed)")
        let back = d2 + "/Папка с пробелом/вложенная/" + name
        ok((try? Data(contentsOf: URL(fileURLWithPath: back))) == body, "содержимое совпало байт в байт")
        ok(local.stat(back)?.mtime.map { abs($0.timeIntervalSince(old)) < 2 } == true, "дата на Mac сохранена")

        // Переименование на iPhone
        let up2 = phone.stat(base + "/Папка с пробелом/заметка.AAE")!
        var pp = [(up2, "заметка новая.AAE")]
        ok(applyRenames(phone, pp).isEmpty && phone.stat(base + "/Папка с пробелом/заметка новая.AAE") != nil, "переименование на iPhone")
        pp = [(phone.stat(base + "/Папка с пробелом/заметка новая.AAE")!, "заметка.AAE")]
        ok(applyRenames(phone, pp).isEmpty, "переименование обратно")
        ok((try? phone.rename("/DCIM/176APPLE", "/DCIM/x")) == nil, "переименование в DCIM запрещено")

        // Перенос с iPhone удаляет источник и пустые папки
        let d3 = tmp + "/out3"; try local.mkdir(d3)
        r = Transfer(src: phone, dst: local, items: [phone.stat(base + "/Папка с пробелом")!], dstDir: d3, move: true, conflict: .skipSame, mediaOnly: false).run { _ in }
        ok(r.copied == 2 && phone.stat(base + "/Папка с пробелом") == nil, "перенос с iPhone \(r.failed)")

        // Настоящий снимок из DCIM
        var sample: FileItem? = nil
        for dir in try phone.list("/DCIM") where dir.isDir && dir.name.hasSuffix("APPLE") {
            sample = try phone.list(dir.path).first { isMedia($0.name) && $0.size > 0 }
            if sample != nil { break }
        }
        ok(sample != nil, "найден снимок в DCIM")
        if let f = sample {
            let d4 = tmp + "/out4"; try local.mkdir(d4)
            r = Transfer(src: phone, dst: local, items: [f], dstDir: d4, move: false, conflict: .skipSame, mediaOnly: false).run { _ in }
            ok(r.copied == 1 && local.stat(join(d4, f.name))?.size == f.size, "снимок из DCIM \(f.name) \(f.size)")
            ok(local.stat(join(d4, f.name))?.mtime.map { abs($0.timeIntervalSince(f.mtime!)) < 2 } == true, "дата снимка сохранена")
            ok(phone.stat(f.path) != nil, "оригинал в DCIM на месте")
        }
    } catch { ok(false, "\(error)") }
    try? phone.remove(base)
    ok(phone.stat(base) == nil, "тестовая папка удалена с iPhone")
    try? FileManager.default.removeItem(atPath: tmp)
    print(bad == 0 ? "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ" : "ОШИБОК: \(bad)")
    return bad == 0 ? 0 : 1
}
