import Foundation

struct FileItem {
    var name: String
    var path: String
    var isDir: Bool
    var size: UInt64
    var mtime: Date?
    var isLink = false
    var isUp = false
}

struct FSError: LocalizedError {
    let text: String
    init(_ t: String) { text = t }
    var errorDescription: String? { text }
}

protocol ByteReader { func read(_ p: UnsafeMutableRawPointer, _ n: Int) throws -> Int; func close() }
protocol ByteWriter { func write(_ p: UnsafeRawPointer, _ n: Int) throws; func close() throws }

protocol FileSystem: AnyObject {
    var isPhone: Bool { get }
    var root: String { get }
    func list(_ path: String) throws -> [FileItem]
    func stat(_ path: String) -> FileItem?
    func mkdir(_ path: String) throws
    func remove(_ path: String) throws
    func removeEmptyDir(_ path: String)
    func rename(_ from: String, _ to: String) throws
    func openRead(_ path: String) throws -> ByteReader
    func openWrite(_ path: String) throws -> ByteWriter
    func setMTime(_ path: String, _ date: Date)
}

func join(_ a: String, _ b: String) -> String { (a as NSString).appendingPathComponent(b) }
func parent(_ p: String) -> String { (p as NSString).deletingLastPathComponent }

let mediaExts: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "gif", "webp", "tif", "tiff", "dng", "raw", "cr2", "cr3", "nef", "arw",
                              "mov", "mp4", "m4v", "avi", "mkv", "3gp", "mts", "hevc"]
func isMedia(_ name: String) -> Bool { mediaExts.contains((name as NSString).pathExtension.lowercased()) }

/// Суммарный размер папки со всем содержимым. Ссылки не учитываются.
func folderSize(_ fs: FileSystem, _ path: String) -> UInt64 {
    var sum: UInt64 = 0
    for c in (try? fs.list(path)) ?? [] where !c.isLink { sum += c.isDir ? folderSize(fs, c.path) : c.size }
    return sum
}

func uniquePath(_ fs: FileSystem, _ path: String, word: String = "") -> String {
    if fs.stat(path) == nil { return path }
    let d = parent(path), n = path as NSString
    let base = (n.lastPathComponent as NSString).deletingPathExtension, ext = n.pathExtension
    var i = 1
    while true {
        let stem = word.isEmpty ? "\(base) (\(i))" : (i == 1 ? "\(base) \(word)" : "\(base) \(word) \(i)")
        let c = join(d, ext.isEmpty ? stem : "\(stem).\(ext)")
        if fs.stat(c) == nil { return c }
        i += 1
    }
}

/// Маска вида `*.jpg;*.mov`. Текст без `*` и `?` ищется как часть имени.
func matchesMask(_ name: String, _ mask: String) -> Bool {
    // fnmatch не умеет регистр кириллицы, поэтому приводим к одному виду заранее.
    let norm: (String) -> String = { $0.precomposedStringWithCanonicalMapping.lowercased() }
    let n = norm(name)
    return mask.split(whereSeparator: { $0 == ";" || $0 == "," }).contains { raw in
        let m = norm(raw.trimmingCharacters(in: .whitespaces))
        if m.isEmpty { return false }
        return fnmatch(m.contains("*") || m.contains("?") ? m : "*\(m)*", n, 0) == 0
    }
}

// MARK: Групповое переименование

private func stamp(_ fmt: String, _ d: Date?) -> String {
    guard let d else { return "" }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = fmt
    return f.string(from: d)
}

/// Шаблон: [N] имя, [C] счётчик, [D] дата файла, [T] время файла. Расширение сохраняется.
func renamePlan(_ items: [FileItem], pattern: String, find: String, replace: String, start: Int) -> [(FileItem, String)] {
    items.enumerated().map { i, it in
        let ns = it.name as NSString
        var stem = it.isDir ? it.name : ns.deletingPathExtension
        let ext = it.isDir ? "" : ns.pathExtension
        if !find.isEmpty { stem = stem.replacingOccurrences(of: find, with: replace) }
        let out = pattern.replacingOccurrences(of: "[N]", with: stem)
            .replacingOccurrences(of: "[C]", with: String(format: "%03d", start + i))
            .replacingOccurrences(of: "[D]", with: stamp("yyyy-MM-dd", it.mtime))
            .replacingOccurrences(of: "[T]", with: stamp("HH.mm.ss", it.mtime))
        return (it, ext.isEmpty ? out : "\(out).\(ext)")
    }
}

/// Возвращает текст проблемы или nil, если план безопасен. Ничего не перезаписывается.
func renameProblem(_ plan: [(FileItem, String)], existing: [String]) -> String? {
    let taken = Set(existing.map { $0.lowercased() })
    var seen = Set<String>()
    for (it, new) in plan {
        let l = new.lowercased()
        if new.trimmingCharacters(in: .whitespaces).isEmpty || new.hasPrefix(".") && !it.name.hasPrefix(".") || new.contains("/") || new.contains(":") {
            return "Недопустимое имя: «\(new)»"
        }
        if !seen.insert(l).inserted { return "Несколько файлов получат имя «\(new)». Добавьте в шаблон счётчик [C]." }
        if l != it.name.lowercased() && taken.contains(l) { return "Файл «\(new)» уже есть в этой папке." }
    }
    return nil
}

func applyRenames(_ fs: FileSystem, _ plan: [(FileItem, String)]) -> [String] {
    var errs: [String] = []
    for (it, new) in plan where new != it.name {
        do { try fs.rename(it.path, join(parent(it.path), new)) } catch { errs.append("\(it.name): \(error.localizedDescription)") }
    }
    return errs
}

/// Создаёт ZIP с выбранными файлами и папками из каталога dir.
func zipItems(dir: String, names: [String], out: String) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    p.arguments = ["-r", "-y", "-q", out] + names.map { "./" + $0 }
    try p.run(); p.waitUntilExit()
    if p.terminationStatus != 0 { try? FileManager.default.removeItem(atPath: out); throw FSError("Не удалось создать архив (код \(p.terminationStatus))") }
}

// MARK: Mac

final class LocalFS: FileSystem {
    let isPhone = false
    let root = "/"
    private let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]

    private func item(_ u: URL) -> FileItem? {
        guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
        let link = v.isSymbolicLink ?? false
        var dir = v.isDirectory ?? false
        if link { dir = (try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
        return FileItem(name: u.lastPathComponent, path: u.path, isDir: dir, size: UInt64(v.fileSize ?? 0),
                        mtime: v.contentModificationDate, isLink: link)
    }
    func list(_ path: String) throws -> [FileItem] {
        try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys).compactMap(item)
    }
    func stat(_ path: String) -> FileItem? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return item(URL(fileURLWithPath: path))
    }
    func mkdir(_ path: String) throws { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
    /// На Mac удаление всегда идёт в Корзину.
    func remove(_ path: String) throws { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
    func removeEmptyDir(_ path: String) { Foundation.rmdir(path) }
    func rename(_ from: String, _ to: String) throws {
        if from.lowercased() == to.lowercased() {  // смена только регистра на нечувствительном к регистру диске
            if Foundation.rename(from, to) != 0 { throw FSError(String(cString: strerror(errno))) }
        } else { try FileManager.default.moveItem(atPath: from, toPath: to) }
    }
    func setMTime(_ path: String, _ date: Date) { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path) }

    final class R: ByteReader {
        let fd: Int32; init(_ f: Int32) { fd = f }
        func read(_ p: UnsafeMutableRawPointer, _ n: Int) throws -> Int {
            let r = Foundation.read(fd, p, n)
            if r < 0 { throw FSError("Ошибка чтения: \(String(cString: strerror(errno)))") }
            return r
        }
        func close() { Foundation.close(fd) }
    }
    final class W: ByteWriter {
        let fd: Int32; init(_ f: Int32) { fd = f }
        func write(_ p: UnsafeRawPointer, _ n: Int) throws {
            var off = 0
            while off < n {
                let r = Foundation.write(fd, p + off, n - off)
                if r <= 0 { throw FSError("Ошибка записи: \(String(cString: strerror(errno)))") }
                off += r
            }
        }
        func close() throws { if Foundation.close(fd) != 0 { throw FSError("Ошибка записи на диск") } }
    }
    func openRead(_ path: String) throws -> ByteReader {
        let fd = open(path, O_RDONLY)
        if fd < 0 { throw FSError("Не открыть \(path): \(String(cString: strerror(errno)))") }
        return R(fd)
    }
    func openWrite(_ path: String) throws -> ByteWriter {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd < 0 { throw FSError("Не создать \(path): \(String(cString: strerror(errno)))") }
        return W(fd)
    }
}

// MARK: iPhone (AFC)

struct PhoneInfo { let udid: String; let name: String? }

enum Phone {
    /// Системные папки медиа-раздела: писать и удалять в них нельзя, иначе медиатека iPhone может разойтись со своей базой.
    static let protectedRoots: Set<String> = ["DCIM", "PhotoData", "PhotoStreamsData", "iTunes_Control", "iTunesRestore", "MediaAnalysis",
                                              "Deferred", "Espresso", "EnhancedAudioSharedKeys", "Radio", "Music", "Books", "Purchases", "Recordings"]
    static func isProtected(_ path: String) -> Bool {
        guard let first = path.split(separator: "/").first else { return true }  // сам корень
        return protectedRoots.contains(String(first))
    }
    static func detect() -> PhoneInfo? {
        var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        var count: Int32 = 0
        guard idevice_get_device_list(&list, &count) == IDEVICE_E_SUCCESS, let l = list else { return nil }
        defer { idevice_device_list_free(l) }
        guard count > 0, let first = l[0] else { return nil }
        let udid = String(cString: first)
        var dev: idevice_t? = nil
        guard idevice_new_with_options(&dev, udid, IDEVICE_LOOKUP_USBMUX) == IDEVICE_E_SUCCESS else { return nil }
        defer { idevice_free(dev) }
        var ld: lockdownd_client_t? = nil
        guard lockdownd_client_new_with_handshake(dev, &ld, "PhoneCommander") == LOCKDOWN_E_SUCCESS else { return PhoneInfo(udid: udid, name: nil) }
        defer { lockdownd_client_free(ld) }
        var name: UnsafeMutablePointer<CChar>? = nil
        var res = "iPhone"
        if lockdownd_get_device_name(ld, &name) == LOCKDOWN_E_SUCCESS, let n = name { res = String(cString: n); free(n) }
        return PhoneInfo(udid: udid, name: res)
    }
}

final class PhoneFS: FileSystem {
    let isPhone = true
    let root = "/"
    private var dev: idevice_t?
    private var afc: afc_client_t?

    init(udid: String) throws {
        guard idevice_new_with_options(&dev, udid, IDEVICE_LOOKUP_USBMUX) == IDEVICE_E_SUCCESS else { throw FSError("iPhone не найден") }
        let e = afc_client_start_service(dev, &afc, "PhoneCommander")
        guard e == AFC_E_SUCCESS else {
            idevice_free(dev); dev = nil
            throw FSError("Нет доступа к iPhone. Разблокируйте его и нажмите «Доверять».")
        }
    }
    deinit { if let a = afc { afc_client_free(a) }; if let d = dev { idevice_free(d) } }

    private func check(_ e: afc_error_t, _ what: String) throws {
        if e != AFC_E_SUCCESS { throw FSError("\(what): \(String(cString: afc_strerror(e)))") }
    }
    private func guardWrite(_ path: String) throws {
        if Phone.isProtected(path) { throw FSError("Папка iPhone защищена от изменений: \(path)") }
    }
    private func dict(_ raw: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> [String: String] {
        var d: [String: String] = [:]; var i = 0
        while let k = raw[i], let v = raw[i + 1] { d[String(cString: k)] = String(cString: v); i += 2 }
        return d
    }
    func stat(_ path: String) -> FileItem? {
        var info: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        guard afc_get_file_info(afc, path, &info) == AFC_E_SUCCESS, let raw = info else { return nil }
        defer { afc_dictionary_free(raw) }
        let d = dict(raw)
        let t = d["st_mtime"].flatMap { UInt64($0) }.map { Date(timeIntervalSince1970: Double($0) / 1e9) }
        return FileItem(name: (path as NSString).lastPathComponent, path: path, isDir: d["st_ifmt"] == "S_IFDIR",
                        size: d["st_size"].flatMap { UInt64($0) } ?? 0, mtime: t, isLink: d["st_ifmt"] == "S_IFLNK")
    }
    func list(_ path: String) throws -> [FileItem] {
        var raw: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        try check(afc_read_directory(afc, path, &raw), "Не прочитать папку")
        guard let l = raw else { return [] }
        defer { afc_dictionary_free(l) }
        var names: [String] = []; var i = 0
        while let n = l[i] { names.append(String(cString: n)); i += 1 }
        return names.filter { $0 != "." && $0 != ".." }.compactMap { stat(join(path, $0)) }
    }
    func mkdir(_ path: String) throws { try guardWrite(path); try check(afc_make_directory(afc, path), "Не создать папку") }
    func remove(_ path: String) throws { try guardWrite(path); try check(afc_remove_path_and_contents(afc, path), "Не удалить") }
    func removeEmptyDir(_ path: String) {
        if !Phone.isProtected(path), (try? list(path))?.isEmpty == true { _ = afc_remove_path(afc, path) }
    }
    func rename(_ from: String, _ to: String) throws {
        try guardWrite(from); try guardWrite(to)
        try check(afc_rename_path(afc, from, to), "Не переименовать")
    }
    func setMTime(_ path: String, _ date: Date) {
        if !Phone.isProtected(path) { _ = afc_set_file_time(afc, path, UInt64(date.timeIntervalSince1970 * 1e9)) }
    }

    final class R: ByteReader {
        let fs: PhoneFS; let h: UInt64
        init(_ f: PhoneFS, _ h: UInt64) { fs = f; self.h = h }
        func read(_ p: UnsafeMutableRawPointer, _ n: Int) throws -> Int {
            var got: UInt32 = 0
            try fs.check(afc_file_read(fs.afc, h, p.assumingMemoryBound(to: CChar.self), UInt32(n), &got), "Ошибка чтения с iPhone")
            return Int(got)
        }
        func close() { _ = afc_file_close(fs.afc, h) }
    }
    final class W: ByteWriter {
        let fs: PhoneFS; let h: UInt64
        init(_ f: PhoneFS, _ h: UInt64) { fs = f; self.h = h }
        func write(_ p: UnsafeRawPointer, _ n: Int) throws {
            var off = 0
            while off < n {
                var put: UInt32 = 0
                try fs.check(afc_file_write(fs.afc, h, (p + off).assumingMemoryBound(to: CChar.self), UInt32(n - off), &put), "Ошибка записи на iPhone")
                if put == 0 { throw FSError("iPhone не принимает данные") }
                off += Int(put)
            }
        }
        func close() throws { try fs.check(afc_file_close(fs.afc, h), "Ошибка записи на iPhone") }
    }
    func openRead(_ path: String) throws -> ByteReader {
        var h: UInt64 = 0
        try check(afc_file_open(afc, path, AFC_FOPEN_RDONLY, &h), "Не открыть файл")
        return R(self, h)
    }
    func openWrite(_ path: String) throws -> ByteWriter {
        try guardWrite(path)
        var h: UInt64 = 0
        try check(afc_file_open(afc, path, AFC_FOPEN_WRONLY, &h), "Не создать файл")
        return W(self, h)
    }
}

// MARK: Копирование

enum Conflict: Int { case skipSame = 0, replace, keepBoth }

struct TransferProgress { var name = ""; var doneBytes: UInt64 = 0; var totalBytes: UInt64 = 0; var doneFiles = 0; var totalFiles = 0 }

struct TransferReport {
    var copied = 0, skipped = 0, empty = 0, bytes: UInt64 = 0
    var cancelled = false
    var failed: [(String, String)] = []
}

final class Transfer {
    let src: FileSystem, dst: FileSystem, items: [FileItem], dstDir: String
    let move: Bool, conflict: Conflict, mediaOnly: Bool
    private let lock = NSLock(); private var stop = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stop }
    func cancel() { lock.lock(); stop = true; lock.unlock() }

    init(src: FileSystem, dst: FileSystem, items: [FileItem], dstDir: String, move: Bool, conflict: Conflict, mediaOnly: Bool) {
        self.src = src; self.dst = dst; self.items = items; self.dstDir = dstDir
        self.move = move; self.conflict = conflict; self.mediaOnly = mediaOnly
    }

    private struct Entry { let item: FileItem; let rel: String }

    private func scan(_ it: FileItem, _ rel: String, _ files: inout [Entry], _ dirs: inout [(String, String)], _ r: inout TransferReport) {
        if isCancelled { return }
        if it.isLink { r.failed.append((it.path, "ссылка пропущена")); return }
        if it.isDir {
            dirs.append((it.path, rel))
            do { for c in try src.list(it.path) { scan(c, join(rel, c.name), &files, &dirs, &r) } }
            catch { r.failed.append((it.path, error.localizedDescription)) }
        } else if !mediaOnly || isMedia(it.name) {
            files.append(Entry(item: it, rel: rel))
        }
    }

    private func uniqueName(_ path: String) -> String { uniquePath(dst, path) }

    private func copy(_ e: Entry, _ target: String, onBytes: (UInt64) -> Void) throws {
        let tmp = target + ".part"
        if dst.stat(tmp) != nil { try? dst.removeTemp(tmp) }
        let reader = try src.openRead(e.item.path)
        defer { reader.close() }
        let writer = try dst.openWrite(tmp)
        let cap = 1 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
        defer { buf.deallocate() }
        var total: UInt64 = 0
        do {
            while true {
                if isCancelled { throw CancellationError() }
                let n = try reader.read(buf, cap)
                if n == 0 { break }
                try writer.write(buf, n)
                total += UInt64(n); onBytes(UInt64(n))
            }
            try writer.close()
        } catch {
            try? writer.close(); try? dst.removeTemp(tmp)
            throw error
        }
        guard total == e.item.size, dst.stat(tmp)?.size == e.item.size else {
            try? dst.removeTemp(tmp)
            throw FSError("Размер не совпал после копирования")
        }
        if dst.stat(target) != nil { try dst.removeTemp(target) }
        try dst.rename(tmp, target)
        if let t = e.item.mtime { dst.setMTime(target, t) }
    }

    func run(progress: @escaping (TransferProgress) -> Void) -> TransferReport {
        var r = TransferReport(), files: [Entry] = [], dirs: [(String, String)] = []
        for it in items { scan(it, it.name, &files, &dirs, &r) }
        var p = TransferProgress()
        p.totalFiles = files.count; p.totalBytes = files.reduce(0) { $0 + $1.item.size }
        progress(p)
        for (_, rel) in dirs {
            let d = join(dstDir, rel)
            if dst.stat(d) == nil { do { try dst.mkdir(d) } catch { r.failed.append((d, error.localizedDescription)) } }
        }
        var last = Date.distantPast
        for e in files {
            if isCancelled { break }
            var target = join(dstDir, e.rel)
            p.name = e.item.name
            let startBytes = p.doneBytes
            defer { p.doneFiles += 1; p.doneBytes = startBytes + e.item.size; progress(p) }
            if src.isPhone && e.item.size == 0 && isMedia(e.item.name) { r.empty += 1; continue }  // заглушка: содержимое только в iCloud
            if let ex = dst.stat(target) {
                switch conflict {
                case .skipSame:
                    if ex.size == e.item.size { r.skipped += 1; continue }
                    target = uniqueName(target)
                case .replace: break
                case .keepBoth: target = uniqueName(target)
                }
            }
            do {
                try copy(e, target) { n in
                    p.doneBytes += n
                    if Date().timeIntervalSince(last) > 0.1 { last = Date(); progress(p) }
                }
                r.copied += 1; r.bytes += e.item.size
                if move { do { try src.remove(e.item.path) } catch { r.failed.append((e.item.path, "скопирован, но не удалён: \(error.localizedDescription)")) } }
            } catch is CancellationError {
                break
            } catch {
                r.failed.append((e.item.path, error.localizedDescription))
            }
        }
        r.cancelled = isCancelled
        if move && !r.cancelled { for (d, _) in dirs.reversed() { src.removeEmptyDir(d) } }
        return r
    }
}

extension FileSystem {
    /// Удаляет временный или заменяемый файл насовсем, минуя Корзину.
    func removeTemp(_ path: String) throws {
        if isPhone { try remove(path) } else { try FileManager.default.removeItem(atPath: path) }
    }
}
