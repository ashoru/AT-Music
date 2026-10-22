import Foundation

/// 归档要写进音频文件本体的标签集合。
struct AudioTagSet {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: String?
    var comment: String?
    var track: Int = 0
    var disc: Int = 0
    var coverData: Data?
}

/// 把标签直接写进音频文件本体（MP3 = ID3v2.3，FLAC = Vorbis Comment + PICTURE）。
///
/// 归档上传 NAS 前调用：产物是临时目录里的副本，原文件不动；失败/格式不支持返回 nil，
/// 调用方回退为上传原文件。历史上归档只依赖上传后经 Audio Station 回写标签，
/// 回写一旦在入口校验失败（且被 try? 吞掉），归档文件就只剩源文件自带标签——
/// 第三方音源的源文件常常几乎没有标签，于是归档后歌手/专辑全丢。文件本体带标签后，
/// 任何播放器与索引读到的都是完整信息，不再依赖回写这一步成败。
enum AudioTagEmbedder {

    static func embed(tags: AudioTagSet, into sourceURL: URL) -> URL? {
        let ext = sourceURL.pathExtension.lowercased()
        guard ext == "mp3" || ext == "flac" else { return nil }
        guard let data = try? Data(contentsOf: sourceURL), !data.isEmpty else { return nil }
        let out = ext == "mp3" ? embedID3(tags: tags, data: data) : embedFLAC(tags: tags, data: data)
        guard let out else { return nil }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("atm-archive-\(UUID().uuidString).\(ext)")
        do {
            try out.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    // MARK: - ID3v2.3 (MP3)

    private static let id3ManagedFrames: Set<String> = ["TIT2", "TPE1", "TALB", "TPE2", "TCON", "TYER", "COMM", "TRCK", "TPOS", "APIC"]

    private static func embedID3(tags: AudioTagSet, data: Data) -> Data? {
        var audioStart = 0
        var preserved: [(id: String, body: Data)] = []

        if data.count >= 10, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 {
            let major = data[3]
            let flags = data[5]
            var tagSize = 0
            for i in 6..<10 { tagSize = (tagSize << 7) | Int(data[i] & 0x7F) }
            audioStart = 10 + tagSize + ((flags & 0x10) != 0 ? 10 : 0)
            var pos = 10
            let tagEnd = min(10 + tagSize, data.count)
            while pos + 10 <= tagEnd {
                let fid = String(decoding: data[pos..<(pos + 4)], as: UTF8.self)
                guard fid.count == 4, fid.allSatisfy({ $0.isLetter || $0.isNumber }) else { break }
                let frameSize: Int
                if major == 4 {
                    var v = 0
                    for i in 0..<4 { v = (v << 7) | Int(data[pos + 4 + i] & 0x7F) }
                    frameSize = v
                } else {
                    frameSize = Int(data[pos + 4]) << 24 | Int(data[pos + 5]) << 16 | Int(data[pos + 6]) << 8 | Int(data[pos + 7])
                }
                guard frameSize > 0, pos + 10 + frameSize <= data.count else { break }
                if !id3ManagedFrames.contains(fid) {
                    preserved.append((fid, Data(data[(pos + 10)..<(pos + 10 + frameSize)])))
                }
                pos += 10 + frameSize
            }
        }
        guard audioStart < data.count else { return nil }

        var frames = Data()
        func appendFrame(id: String, body: Data) {
            frames.append(id.data(using: .ascii) ?? Data())
            var sizeBE = UInt32(body.count).bigEndian
            frames.append(Data(bytes: &sizeBE, count: 4))
            frames.append(Data(count: 2))
            frames.append(body)
        }
        func textBody(_ value: String) -> Data {
            var body = Data([0x01, 0xFF, 0xFE])
            body.append(value.data(using: .utf16LittleEndian) ?? Data())
            return body
        }
        func textFrame(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            appendFrame(id: id, body: textBody(value))
        }

        textFrame("TIT2", tags.title)
        textFrame("TPE1", tags.artist)
        textFrame("TALB", tags.album)
        textFrame("TPE2", tags.albumArtist)
        textFrame("TCON", tags.genre)
        if let year = tags.year, let y = firstFourDigitYear(year) { textFrame("TYER", y) }
        if tags.track > 0 { textFrame("TRCK", String(tags.track)) }
        if tags.disc > 0 { textFrame("TPOS", String(tags.disc)) }
        if let comment = tags.comment, !comment.isEmpty {
            // COMM: 编码(1) + 语言 eng + 描述符(空, UTF-16 BOM+终止符) + 正文
            var body = Data([0x01])
            body.append("eng".data(using: .ascii) ?? Data())
            body.append(contentsOf: [UInt8(0xFF), UInt8(0xFE), UInt8(0x00), UInt8(0x00)])
            body.append(contentsOf: [UInt8(0xFF), UInt8(0xFE)])
            body.append(comment.data(using: .utf16LittleEndian) ?? Data())
            appendFrame(id: "COMM", body: body)
        }
        if let cover = tags.coverData, !cover.isEmpty {
            // APIC: 编码 0 + mime + 终止符 + 类型 3(封面) + 描述(空) + 图片数据
            var body = Data([0x00])
            body.append("image/jpeg".data(using: .ascii) ?? Data())
            body.append(contentsOf: [UInt8(0x00), UInt8(0x03), UInt8(0x00)])
            body.append(cover)
            appendFrame(id: "APIC", body: body)
        }
        for old in preserved {
            appendFrame(id: old.id, body: old.body)
        }
        frames.append(Data(count: 1024))

        var header = Data("ID3".utf8)
        header.append(contentsOf: [UInt8(0x03), UInt8(0x00), UInt8(0x00)])
        var remaining = frames.count
        var syncsafe = [UInt8](repeating: 0, count: 4)
        for i in stride(from: 3, through: 0, by: -1) {
            syncsafe[i] = UInt8(remaining & 0x7F)
            remaining >>= 7
        }
        header.append(contentsOf: syncsafe)

        var out = header
        out.append(frames)
        out.append(data[audioStart...])
        return out
    }

    private static func firstFourDigitYear(_ value: String) -> String? {
        var run = ""
        for ch in value {
            if ch.isNumber {
                run.append(ch)
                if run.count == 4 { return run }
            } else {
                run = ""
            }
        }
        return nil
    }

    // MARK: - FLAC (Vorbis Comment)

    private static let flacManagedKeys: Set<String> = ["TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "GENRE", "DATE", "TRACKNUMBER", "DISCNUMBER", "COMMENT"]

    private static func embedFLAC(tags: AudioTagSet, data: Data) -> Data? {
        guard data.count > 4,
              data[0] == 0x66, data[1] == 0x4C, data[2] == 0x61, data[3] == 0x43 else { return nil }

        struct Block { let type: UInt8; let payload: Data }
        var blocks: [Block] = []
        var pos = 4
        var audioStart: Int?
        while pos + 4 <= data.count {
            let head = data[pos]
            let isLast = (head & 0x80) != 0
            let type = head & 0x7F
            let len = Int(data[pos + 1]) << 16 | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
            guard pos + 4 + len <= data.count else { return nil }
            blocks.append(Block(type: type, payload: Data(data[(pos + 4)..<(pos + 4 + len)])))
            pos += 4 + len
            if isLast { audioStart = pos; break }
        }
        guard let audioStart, let streamInfo = blocks.first, streamInfo.type == 0 else { return nil }

        // 解析旧注释：保留未托管键，托管键以新值覆盖
        var vendor = "AT Music"
        var keptEntries: [String] = []
        var oldPicture: Data?
        for block in blocks where block.type == 4 {
            let p = block.payload
            guard p.count >= 8 else { continue }
            func le32(_ off: Int) -> Int { Int(p[off]) | Int(p[off + 1]) << 8 | Int(p[off + 2]) << 16 | Int(p[off + 3]) << 24 }
            let vendorLen = le32(0)
            guard 4 + vendorLen + 4 <= p.count else { continue }
            if vendorLen > 0, let v = String(data: p[4..<(4 + vendorLen)], encoding: .utf8), !v.isEmpty { vendor = v }
            var off = 4 + vendorLen
            let count = le32(off); off += 4
            for _ in 0..<count {
                guard off + 4 <= p.count else { break }
                let l = le32(off); off += 4
                guard off + l <= p.count else { break }
                if let entry = String(data: p[off..<(off + l)], encoding: .utf8) {
                    let key = entry.split(separator: "=", maxSplits: 1).first.map { $0.uppercased() } ?? ""
                    if !flacManagedKeys.contains(key) { keptEntries.append(entry) }
                }
                off += l
            }
        }
        for block in blocks where block.type == 6 { oldPicture = block.payload }

        var entries = keptEntries
        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            entries.append("\(key)=\(value)")
        }
        add("TITLE", tags.title)
        add("ARTIST", tags.artist)
        add("ALBUM", tags.album)
        add("ALBUMARTIST", tags.albumArtist)
        add("GENRE", tags.genre)
        add("DATE", tags.year)
        if tags.track > 0 { add("TRACKNUMBER", String(tags.track)) }
        if tags.disc > 0 { add("DISCNUMBER", String(tags.disc)) }
        add("COMMENT", tags.comment)

        var commentPayload = Data()
        func appendLE32(_ v: Int) {
            commentPayload.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }
        let vendorData = vendor.data(using: .utf8) ?? Data()
        appendLE32(vendorData.count); commentPayload.append(vendorData)
        appendLE32(entries.count)
        for entry in entries {
            let d = entry.data(using: .utf8) ?? Data()
            appendLE32(d.count); commentPayload.append(d)
        }

        var picturePayload: Data?
        if let cover = tags.coverData, !cover.isEmpty {
            var p = Data()
            func ple(_ v: Int) { p.append(contentsOf: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
            ple(3)
            let mime = "image/jpeg".data(using: .ascii) ?? Data()
            ple(mime.count); p.append(mime)
            ple(0)
            ple(0); ple(0); ple(0); ple(0)
            ple(cover.count); p.append(cover)
            picturePayload = p
        }

        var outBlocks: [(type: UInt8, payload: Data)] = [(0, streamInfo.payload)]
        for block in blocks.dropFirst() where block.type != 4 && block.type != 6 && block.type != 7 {
            outBlocks.append((block.type, block.payload))
        }
        outBlocks.append((4, commentPayload))
        if let picturePayload {
            outBlocks.append((6, picturePayload))
        } else if let oldPicture {
            outBlocks.append((6, oldPicture))
        }
        outBlocks.append((7, Data(count: 4096)))

        var out = Data("fLaC".utf8)
        for (index, block) in outBlocks.enumerated() {
            let isLast = index == outBlocks.count - 1
            out.append(contentsOf: [UInt8(isLast ? 0x80 : 0x00) | block.type])
            let len = block.payload.count
            out.append(contentsOf: [UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
            out.append(block.payload)
        }
        out.append(data[audioStart...])
        return out
    }
}
