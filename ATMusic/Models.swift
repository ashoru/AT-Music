import Foundation

/// 音质等级。
enum ATMusicAudioQuality: String, CaseIterable, Identifiable {
    case standard
    case higher
    case exhigh
    case lossless
    case hires

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return atmusicLocalized("标准", "Standard")
        case .higher: return atmusicLocalized("较高", "Higher")
        case .exhigh: return atmusicLocalized("极高", "Very High")
        case .lossless: return atmusicLocalized("无损", "Lossless")
        case .hires: return "Hi-Res"
        }
    }

    /// 网易云 songURL 的 level 参数
    var level: String { rawValue }

    /// 当前官方播放音质（默认 Hi-Res；不可用时由各平台接口自行降级）。
    static var current: ATMusicAudioQuality {
        let raw = UserDefaults.standard.string(forKey: "atmusic.audioQuality") ?? Self.hires.rawValue
        return ATMusicAudioQuality(rawValue: raw) ?? .hires
    }
}

/// 第三方音源音质。
enum ThirdPartyAudioQuality: String, CaseIterable, Identifiable, Sendable, Codable {
    case kb128 = "128k"
    case kb320 = "320k"
    case flac = "flac"
    case flac24bit = "flac24bit"
    case hires = "hires"
    case atmos = "atmos"
    case atmosPlus = "atmos_plus"
    case master = "master"

    static let storageKey = "atmusic.thirdPartyAudioQuality"
    static let downloadStorageKey = "atmusic.downloadAudioQuality"

    var id: String { rawValue }

    /// 兼容第三方脚本常见的音质别名（例如 24bit / lossless）。
    init?(sourceValue: String) {
        let normalized = sourceValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "128", "128k", "low", "standard": self = .kb128
        case "320", "320k", "high", "exhigh": self = .kb320
        case "flac", "lossless": self = .flac
        case "24bit", "flac24", "flac24bit", "hires24": self = .flac24bit
        case "hires", "highres", "high-resolution": self = .hires
        case "atmos", "dolby": self = .atmos
        case "atmosplus", "atmos_plus", "dolbyplus": self = .atmosPlus
        case "master", "masterquality": self = .master
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .kb128: return atmusicLocalized("128k", "128k")
        case .kb320: return atmusicLocalized("320k", "320k")
        case .flac: return atmusicLocalized("无损 FLAC", "FLAC")
        case .flac24bit: return atmusicLocalized("FLAC 24 位", "FLAC 24-bit")
        case .hires: return atmusicLocalized("Hi-Res", "Hi-Res")
        case .atmos: return atmusicLocalized("Atmos", "Atmos")
        case .atmosPlus: return atmusicLocalized("Atmos+", "Atmos+")
        case .master: return atmusicLocalized("Master", "Master")
        }
    }

    /// 当前第三方音源优先音质。
    static var current: ThirdPartyAudioQuality {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap { ThirdPartyAudioQuality(sourceValue: $0) } ?? .kb320
    }

    /// 下载使用的独立音质设置，默认保持 320k 以兼容旧版本。
    static var downloadCurrent: ThirdPartyAudioQuality {
        UserDefaults.standard.string(forKey: downloadStorageKey)
            .flatMap { ThirdPartyAudioQuality(sourceValue: $0) } ?? .kb320
    }

    /// 按第三方接口的平台代码返回可用档位。
    static func supported(providerCode: String) -> [ThirdPartyAudioQuality] {
        switch providerCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "kw", "mg":
            return [.kb128, .kb320, .flac, .flac24bit, .hires]
        case "kg":
            return [.kb128, .kb320, .flac, .flac24bit, .hires, .atmos, .master]
        case "tx":
            return allCases
        case "wy":
            return [.kb128, .kb320, .flac, .flac24bit, .hires, .atmos, .master]
        case "git":
            return [.kb128, .kb320, .flac]
        default:
            return allCases
        }
    }

    static func supported(for source: SongSource) -> [ThirdPartyAudioQuality] {
        switch source {
        case .netease: return supported(providerCode: "wy")
        case .qq: return supported(providerCode: "tx")
        case .kugou: return supported(providerCode: "kg")
        case .synology: return [.flac, .kb320]
        case .local: return [.flac, .kb320, .kb128]
        }
    }

    /// 从高到低的降级链。
    var fallbackChain: [ThirdPartyAudioQuality] {
        switch self {
        case .kb128:
            return [.kb128]
        case .kb320:
            return [.kb320, .kb128]
        case .flac:
            return [.flac, .kb320, .kb128]
        case .flac24bit:
            return [.flac24bit, .flac, .kb320, .kb128]
        case .hires:
            return [.hires, .flac24bit, .flac, .kb320, .kb128]
        case .atmos:
            return [.atmos, .hires, .flac24bit, .flac, .kb320, .kb128]
        case .atmosPlus:
            return [.atmosPlus, .atmos, .hires, .flac24bit, .flac, .kb320, .kb128]
        case .master:
            return [.master, .atmosPlus, .atmos, .hires, .flac24bit, .flac, .kb320, .kb128]
        }
    }

    /// 网易云 player/url 的 level 参数。
    var neteaseLevel: String {
        switch self {
        case .kb128: return "standard"
        case .kb320: return "exhigh"
        case .flac: return "lossless"
        case .flac24bit, .hires, .atmos, .atmosPlus, .master: return "hires"
        }
    }

    /// QQ vkey 的 br 参数。
    var qqBR: String {
        switch self {
        case .kb128: return "M500"
        case .kb320: return "M800"
        case .flac, .flac24bit, .hires, .atmos, .atmosPlus, .master: return "F000"
        }
    }

    /// 酷狗官方接口所能理解的质量档位。
    var atmusicQuality: ATMusicAudioQuality {
        switch self {
        case .kb128: return .standard
        case .kb320: return .exhigh
        case .flac: return .lossless
        case .flac24bit, .hires, .atmos, .atmosPlus, .master: return .hires
        }
    }
}

/// 歌曲来源（网易云 / QQ音乐 / 酷狗音乐 / 群晖NAS）
enum SongSource: String, Codable, Sendable {
    case netease
    case qq
    case kugou
    case synology
    case local

    /// 兼容旧版本地收藏：未知或已下线来源统一回退为网易云
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SongSource(rawValue: raw) ?? .netease
    }
}

struct Song: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let artists: String
    let album: String
    let coverURL: URL?
    let duration: TimeInterval
    /// 歌曲来源（网易云 / QQ音乐 / 酷狗 / 群晖）
    let source: SongSource
    /// QQ 音乐 songmid（source == .qq 时用于获取播放地址与歌词）
    let qqMid: String?
    /// QQ 音乐音频文件 media_mid；部分歌曲与 songmid 不同，取 vkey 时必须优先使用
    let qqMediaMid: String?
    /// 酷狗音乐文件 hash 与专辑音频 id（source == .kugou 时用于获取播放地址与歌词）
    let kugouHash: String?
    let kugouAlbumAudioId: String?
    let kugouAlbumId: String?
    let kugouQualityHashes: [String: String]?
    /// 群晖 NAS 歌曲 ID
    let synologyId: String?
    /// 服务器协议、地址、端口与账号共同确定的作用域；旧数据缺失时不能猜测来源。
    let synologyServerScope: String?
    /// NAS 原文件的完整路径，仅用于用户确认后写回标签/封面/歌词。
    let synologyPath: String?
    /// 用户导入音频在 ATMusicAudio 目录下的相对路径。
    let localRelativePath: String?
    /// 本地/NAS 歌曲可选的扩展标签。旧版本记录没有这些字段时保持 nil。
    let albumArtist: String?
    let genre: String?
    let year: String?
    let comment: String?
    /// 付费/VIP 标记（网易云：0 免费、1 VIP、4 付费单曲；QQ：0 免费、非 0 付费）
    let fee: Int

    var formattedDuration: String {
        let total = max(0, Int(duration))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 跨平台唯一标识（避免网易云与 QQ 音乐歌曲 id 撞车）
    var identityKey: String {
        switch source {
        case .qq: return "qq-\(id)"
        case .kugou: return "kugou-\(id)"
        case .netease: return "netease-\(id)"
        case .synology:
            return "synology-\(synologyServerScope.map { $0 + ":" } ?? "")\(synologyId ?? "\(id)")"
        case .local:
            return "local-\(localRelativePath ?? "\(id)")"
        }
    }

    /// 是否为 VIP / 付费歌曲（用于列表与播放器角标）
    /// 网易云 fee：0 免费、1 VIP、4 付费单曲；8 为翻唱/免费资源，不视为 VIP
    /// QQ payplay：0 免费，非 0 需要会员/付费
    var isVIP: Bool {
        switch source {
        case .netease:
            return fee == 1 || fee == 4
        case .qq:
            return fee != 0
        case .kugou:
            return fee != 0
        case .synology:
            return false
        case .local:
            return false
        }
    }

    init(id: Int, name: String, artists: String, album: String, coverURL: URL?, duration: TimeInterval, source: SongSource = .netease, qqMid: String? = nil, qqMediaMid: String? = nil, kugouHash: String? = nil, kugouAlbumAudioId: String? = nil, kugouAlbumId: String? = nil, kugouQualityHashes: [String: String]? = nil, synologyId: String? = nil, synologyServerScope: String? = nil, synologyPath: String? = nil, localRelativePath: String? = nil, albumArtist: String? = nil, genre: String? = nil, year: String? = nil, comment: String? = nil, fee: Int = 0) {
        self.id = id
        self.name = name
        self.artists = artists
        self.album = album
        self.coverURL = coverURL
        self.duration = duration
        self.source = source
        self.qqMid = qqMid
        self.qqMediaMid = qqMediaMid
        self.kugouHash = kugouHash
        self.kugouAlbumAudioId = kugouAlbumAudioId
        self.kugouAlbumId = kugouAlbumId
        self.kugouQualityHashes = kugouQualityHashes
        self.synologyId = synologyId
        self.synologyServerScope = synologyServerScope
        self.synologyPath = synologyPath
        self.localRelativePath = localRelativePath
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.comment = comment
        self.fee = fee
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? Int else { return nil }
        self.id = id
        name = json["name"] as? String ?? ""
        let artistsArray = json["artists"] as? [[String: Any]] ?? (json["ar"] as? [[String: Any]]) ?? []
        artists = artistsArray.compactMap { $0["name"] as? String }.joined(separator: " / ")
        if let albumDict = json["album"] as? [String: Any] {
            album = albumDict["name"] as? String ?? ""
            let pic = albumDict["picUrl"] as? String ?? (albumDict["blurPicUrl"] as? String ?? "")
            coverURL = pic.isEmpty ? nil : URL(string: pic)
        } else if let al = json["al"] as? [String: Any] {
            album = al["name"] as? String ?? ""
            let pic = al["picUrl"] as? String ?? ""
            coverURL = pic.isEmpty ? nil : URL(string: pic)
        } else {
            album = ""
            coverURL = nil
        }
        let ms = json["duration"] as? Int ?? (json["dt"] as? Int) ?? 0
        duration = Double(ms) / 1000.0
        source = .netease
        qqMid = nil
        qqMediaMid = nil
        kugouHash = nil
        kugouAlbumAudioId = nil
        kugouAlbumId = nil
        kugouQualityHashes = nil
        synologyId = nil
        synologyServerScope = nil
        synologyPath = nil
        localRelativePath = nil
        albumArtist = nil
        genre = nil
        year = nil
        comment = nil
        fee = json["fee"] as? Int ?? 0
    }

    private enum CodingKeys: String, CodingKey { case id, name, artists, album, coverURL, duration, source, qqMid, qqMediaMid, kugouHash, kugouAlbumAudioId, kugouAlbumId, kugouQualityHashes, synologyId, synologyServerScope, synologyPath, localRelativePath, albumArtist, genre, year, comment, fee }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        artists = try c.decodeIfPresent(String.self, forKey: .artists) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        coverURL = try c.decodeIfPresent(URL.self, forKey: .coverURL)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        source = try c.decodeIfPresent(SongSource.self, forKey: .source) ?? .netease
        qqMid = try c.decodeIfPresent(String.self, forKey: .qqMid)
        qqMediaMid = try c.decodeIfPresent(String.self, forKey: .qqMediaMid)
        kugouHash = try c.decodeIfPresent(String.self, forKey: .kugouHash)
        kugouAlbumAudioId = try c.decodeIfPresent(String.self, forKey: .kugouAlbumAudioId)
        kugouAlbumId = try c.decodeIfPresent(String.self, forKey: .kugouAlbumId)
        kugouQualityHashes = try c.decodeIfPresent([String: String].self, forKey: .kugouQualityHashes)
        synologyId = try c.decodeIfPresent(String.self, forKey: .synologyId)
        synologyServerScope = try c.decodeIfPresent(String.self, forKey: .synologyServerScope)
        synologyPath = try c.decodeIfPresent(String.self, forKey: .synologyPath)
        localRelativePath = try c.decodeIfPresent(String.self, forKey: .localRelativePath)
        albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        year = try c.decodeIfPresent(String.self, forKey: .year)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        fee = try c.decodeIfPresent(Int.self, forKey: .fee) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(artists, forKey: .artists)
        try c.encode(album, forKey: .album)
        try c.encodeIfPresent(coverURL, forKey: .coverURL)
        try c.encode(duration, forKey: .duration)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(qqMid, forKey: .qqMid)
        try c.encodeIfPresent(qqMediaMid, forKey: .qqMediaMid)
        try c.encodeIfPresent(kugouHash, forKey: .kugouHash)
        try c.encodeIfPresent(kugouAlbumAudioId, forKey: .kugouAlbumAudioId)
        try c.encodeIfPresent(kugouAlbumId, forKey: .kugouAlbumId)
        try c.encodeIfPresent(kugouQualityHashes, forKey: .kugouQualityHashes)
        try c.encodeIfPresent(synologyId, forKey: .synologyId)
        try c.encodeIfPresent(synologyServerScope, forKey: .synologyServerScope)
        try c.encodeIfPresent(synologyPath, forKey: .synologyPath)
        try c.encodeIfPresent(localRelativePath, forKey: .localRelativePath)
        try c.encodeIfPresent(albumArtist, forKey: .albumArtist)
        try c.encodeIfPresent(genre, forKey: .genre)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(comment, forKey: .comment)
        try c.encode(fee, forKey: .fee)
    }
}

/// 歌手搜索结果（网易云 / QQ音乐通用）
struct Artist: Identifiable, Hashable {
    let id: String
    let name: String
    let coverURL: URL?
    let source: SongSource

    /// 平台内 ID 不能直接作为聚合列表身份：不同平台可能返回相同数字 ID，
    /// 某些接口还会返回空 ID。把来源和内容兜底一并纳入，保证 SwiftUI 不会
    /// 将两个平台的歌手误复用为同一个视图。
    var identityKey: String {
        let remoteID = id.isEmpty
            ? name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : id
        return "\(source.rawValue)|\(remoteID)"
    }
}

/// 专辑搜索结果（网易云 / QQ音乐通用）
struct Album: Identifiable, Hashable {
    let id: String
    let name: String
    let artistName: String
    let coverURL: URL?
    let source: SongSource
    var trackCount: Int?

    /// 聚合列表使用跨平台稳定身份，避免专辑卡片在多音源回包时跳动或消失。
    var identityKey: String {
        let fallback = "\(name)|\(artistName)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let remoteID = id.isEmpty ? fallback : id
        return "\(source.rawValue)|\(remoteID)"
    }
}

struct Playlist: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    var coverURL: URL?
    let trackCount: Int
    var creatorName: String
    let specialType: Int
    /// 歌单来源（网易云 / QQ音乐），非网易云歌单用对应接口加载
    let source: SongSource
    /// 群晖 Audio Station 的原始歌单 ID。它可能是字符串路径，不能用 Swift 的 hashValue 代替。
    let synologyPlaylistId: String?
    /// 平台返回的热度值（播放量/收藏量等），用于聚合歌单搜索的次级排序。
    var popularity: Int? = nil
    /// 搜索/详情接口返回的歌单简介；缺失时保持 nil，兼容历史本地缓存。
    var descriptionText: String? = nil

    /// 聚合列表必须把平台纳入身份。不同平台的纯数字歌单 ID 经常重复，
    /// 直接使用 `id` 会让 SwiftUI 错误复用视图并产生闪烁。
    var identityKey: String {
        let remoteID = synologyPlaylistId ?? String(id)
        return "\(source.rawValue)|\(remoteID)"
    }

    init(id: Int, name: String, coverURL: URL?, trackCount: Int = 0, source: SongSource = .netease, synologyPlaylistId: String? = nil) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.trackCount = trackCount
        self.creatorName = ""
        self.specialType = 0
        self.source = source
        self.synologyPlaylistId = synologyPlaylistId
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? Int else { return nil }
        self.id = id
        name = json["name"] as? String ?? ""
        trackCount = json["trackCount"] as? Int ?? 0
        let pic = json["coverImgUrl"] as? String ?? json["picUrl"] as? String ?? ""
        coverURL = pic.isEmpty ? nil : URL(string: pic)
        creatorName = (json["creator"] as? [String: Any])?["nickname"] as? String ?? ""
        specialType = json["specialType"] as? Int ?? 0
        source = .netease
        synologyPlaylistId = nil
        descriptionText = (json["description"] as? String)
            ?? (json["copywriter"] as? String)
    }

    init?(personalizedJSON json: [String: Any]) {
        guard let id = json["id"] as? Int else { return nil }
        self.id = id
        name = json["name"] as? String ?? ""
        trackCount = 0
        let pic = json["picUrl"] as? String ?? ""
        coverURL = pic.isEmpty ? nil : URL(string: pic)
        creatorName = ""
        specialType = json["specialType"] as? Int ?? 0
        source = .netease
        synologyPlaylistId = nil
    }

    var isNetEaseLikedPlaylist: Bool {
        source == .netease && (specialType == 5 || name == "我喜欢的音乐" || name.localizedCaseInsensitiveContains("liked songs"))
    }
}

struct TopList: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let coverURL: URL?
    let updateFrequency: String

    init?(json: [String: Any]) {
        guard let id = json["id"] as? Int else { return nil }
        self.id = id
        name = json["name"] as? String ?? ""
        let pic = json["coverImgUrl"] as? String ?? ""
        coverURL = pic.isEmpty ? nil : URL(string: pic)
        updateFrequency = json["updateFrequency"] as? String ?? ""
    }
}

/// QQ 峰尖榜总览项
struct QQTopInfo: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let subTitle: String
    let topSongNames: [String]
    let coverURL: URL?
}

/// 酷狗官方排行榜总览项
struct KugouTopInfo: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let updateFrequency: String
    let coverURL: URL?
}

struct LyricLine: Identifiable, Hashable {
    let id: UUID
    let time: Double
    let text: String
    /// 歌词翻译（网易云 tlyric，可空）
    var translation: String?

    init(time: Double, text: String, translation: String? = nil) {
        self.id = UUID()
        self.time = time
        self.text = text
        self.translation = translation
    }
}

enum LyricParser {
    /// 解析歌词；可选传入翻译歌词（网易云 tlyric），按时间戳合并到对应行
    static func parse(_ raw: String, translationRaw: String? = nil) -> [LyricLine] {
        var lines = parseCore(raw, offset: declaredOffsetSeconds(in: raw))
        if let translationRaw, !translationRaw.isEmpty {
            let trans = parseCore(translationRaw, offset: declaredOffsetSeconds(in: translationRaw))
            var byTime: [Double: String] = [:]
            for t in trans where !t.text.isEmpty {
                byTime[t.time] = t.text
            }
            for i in lines.indices {
                if let tr = byTime[lines[i].time], !tr.isEmpty {
                    lines[i].translation = tr
                }
            }
        }
        return lines
    }

    private static func parseCore(_ raw: String, offset: Double) -> [LyricLine] {
        var lines: [LyricLine] = []
        for line in raw.components(separatedBy: .newlines) {
            parseTimes(in: line).forEach { time in
                let text = line.replacingOccurrences(of: #"\[\d{2}:\d{2}(\.\d{1,3})?\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(LyricLine(time: max(0, time + offset), text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    private static func declaredOffsetSeconds(in raw: String) -> Double {
        let pattern = #"\[offset:([+-]?\d+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw),
              let milliseconds = Double(raw[range]) else {
            return 0
        }
        return milliseconds / 1000.0
    }

    private static func parseTimes(in line: String) -> [Double] {
        var times: [Double] = []
        let pattern = #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..., in: line)
        regex?.enumerateMatches(in: line, options: [], range: range) { match, _, _ in
            guard let match else { return }
            guard let minuteRange = Range(match.range(at: 1), in: line),
                  let secondRange = Range(match.range(at: 2), in: line) else { return }
            let minutes = Double(line[minuteRange]) ?? 0
            let seconds = Double(line[secondRange]) ?? 0
            var fraction = 0.0
            if match.numberOfRanges > 3, let fracRange = Range(match.range(at: 3), in: line) {
                let raw = String(line[fracRange])
                fraction = (Double(raw) ?? 0) / pow(10, Double(max(raw.count, 1)))
            }
            times.append(minutes * 60 + seconds + fraction)
        }
        return times
    }
}

enum LyricTiming {
    static let userOffsetKey = "atmusic.lyricOffset"

    static func effectiveProgress(_ progress: Double, userOffset: Double? = nil) -> Double {
        let offset = userOffset ?? UserDefaults.standard.double(forKey: userOffsetKey)
        return max(0, progress + offset)
    }

    static func seekTime(for line: LyricLine, userOffset: Double? = nil) -> Double {
        let offset = userOffset ?? UserDefaults.standard.double(forKey: userOffsetKey)
        return max(0, line.time - offset)
    }
}

struct NetEaseUser: Identifiable, Hashable, Codable {
    let uid: Int
    let nickname: String
    let avatarURL: URL?
    /// 网易云会员类型：0 无会员；非 0 有 VIP；>= 11 为黑胶 SVIP（接口字段 profile.vipType）
    let vipType: Int

    var id: Int { uid }

    /// VIP 标识：nil 表示无会员
    var vipBadge: String? {
        if vipType >= 11 { return "SVIP" }
        if vipType > 0 { return "VIP" }
        return nil
    }

    init?(json: [String: Any]) {
        guard let id = json["userId"] as? Int ?? (json["id"] as? Int) else { return nil }
        uid = id
        nickname = json["nickname"] as? String ?? ""
        let pic = json["avatarUrl"] as? String ?? ""
        avatarURL = pic.isEmpty ? nil : URL(string: pic)
        vipType = json["vipType"] as? Int ?? 0
    }

    enum CodingKeys: String, CodingKey { case uid, nickname, avatarURL, vipType }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decode(Int.self, forKey: .uid)
        nickname = try c.decode(String.self, forKey: .nickname)
        avatarURL = try c.decodeIfPresent(URL.self, forKey: .avatarURL)
        vipType = try c.decodeIfPresent(Int.self, forKey: .vipType) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uid, forKey: .uid)
        try c.encode(nickname, forKey: .nickname)
        try c.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try c.encode(vipType, forKey: .vipType)
    }
}
/// 听歌排行条目（网易云听歌记录）
struct PlayRecordItem: Identifiable, Hashable {
    let song: Song
    let playCount: Int
    var id: Int { song.id }
}

/// 听歌排行结果（列表 + 真实总数，避免被接口单次上限截断）
struct PlayRecordResult {
    let items: [PlayRecordItem]
    let totalCount: Int
}

// MARK: - 歌曲评论

struct SongComment: Identifiable, Hashable {
    let id: Int
    let content: String
    let nickname: String
    let avatarURL: URL?
    let time: Date
    let likedCount: Int
    let isHot: Bool

    init(id: Int, content: String, nickname: String, avatarURL: URL?, time: Date, likedCount: Int, isHot: Bool = false) {
        self.id = id
        self.content = content
        self.nickname = nickname
        self.avatarURL = avatarURL
        self.time = time
        self.likedCount = likedCount
        self.isHot = isHot
    }

    init?(json: [String: Any], isHot: Bool = false) {
        guard let id = json["commentId"] as? Int else { return nil }
        self.id = id
        content = json["content"] as? String ?? ""
        let user = json["user"] as? [String: Any]
        nickname = user?["nickname"] as? String ?? ""
        let avatar = user?["avatarUrl"] as? String ?? ""
        avatarURL = avatar.isEmpty ? nil : URL(string: avatar)
        let ms = json["time"] as? Int ?? 0
        time = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        likedCount = json["likedCount"] as? Int ?? 0
        self.isHot = isHot
    }
}

// MARK: - 搜索提供方

enum SearchProvider: String, CaseIterable, Identifiable, Hashable, Sendable {
    case netease = "网易云音乐"
    case qq = "QQ音乐"
    case kugou = "酷狗音乐"
    case synology = "群晖 NAS"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .netease: return "cloud.fill"
        case .qq: return "play.rectangle.fill"
        case .kugou: return "music.note"
        case .synology: return "externaldrive.fill"
        }
    }

    var brandImageName: String? {
        switch self {
        case .netease: return "BrandNetease"
        case .qq: return "BrandQQ"
        case .kugou: return "BrandKugou"
        case .synology: return nil
        }
    }
}
