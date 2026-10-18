import Foundation

/// 统一歌词加载与缓存协调器：
/// 1. 优先读取磁盘与内存缓存；
/// 2. 分源读取本地 .lrc / NAS / 酷狗 / QQ / 网易云官方歌词；
/// 3. 当未匹配到歌词时，跨平台智能模糊匹配补全并写入离线缓存；
/// 4. 供播放器主页与播放器布局编辑器实时联动。
enum SongLyricsLoader {
    private static var inFlightTasks: [String: Task<[LyricLine], Never>] = [:]
    private static let taskLock = NSLock()

    static func loadLyrics(for song: Song) async -> [LyricLine] {
        let identity = song.identityKey

        // 1. 优先检查本地歌词磁盘缓存
        if let cached = await ATMusicCacheCoordinator.shared.cachedLyric(for: song), !cached.isEmpty {
            let parsed = LyricParser.parse(cached)
            if !parsed.isEmpty { return parsed }
        }

        taskLock.lock()
        if let existing = inFlightTasks[identity] {
            taskLock.unlock()
            return await existing.value
        }
        let task = Task<[LyricLine], Never> {
            defer {
                taskLock.lock()
                inFlightTasks.removeValue(forKey: identity)
                taskLock.unlock()
            }
            return await fetchAndParseLyrics(for: song)
        }
        inFlightTasks[identity] = task
        taskLock.unlock()
        return await task.value
    }

    private static func fetchAndParseLyrics(for song: Song) async -> [LyricLine] {
        var rawLyrics: String?
        var translationRaw: String?

        // 2. 根据音源获取
        if song.source == .local, let relativePath = song.localRelativePath {
            let lrcPath = (relativePath as NSString).deletingPathExtension + ".lrc"
            if let lrcURL = try? ManagedAudioPath.resolve(lrcPath),
               let raw = try? String(contentsOf: lrcURL, encoding: .utf8) {
                rawLyrics = raw
            }
        } else if let localFile = LocalAudioFileManager.shared.file(forSongId: song.identityKey) {
            let lrcPath = (localFile.relativePath as NSString).deletingPathExtension + ".lrc"
            if let lrcURL = try? ManagedAudioPath.resolve(lrcPath),
               let raw = try? String(contentsOf: lrcURL, encoding: .utf8) {
                rawLyrics = raw
            }
        } else if song.source == .synology {
            if let raw = try? await SynologyAPI.shared.lyrics(song: song) {
                rawLyrics = raw
            }
        } else if song.source == .kugou, let hash = song.kugouHash {
            let raw = await KugouMusicAPI.shared.lyric(hash: hash, duration: song.duration)
            if !raw.isEmpty { rawLyrics = raw }
        } else if song.source == .qq, let mid = song.qqMid {
            if let raw = try? await QQMusicAPI.shared.lyric(songmid: mid) {
                rawLyrics = raw
            }
        } else if song.source == .netease {
            if let (lrc, tlyric) = try? await NetEaseAPI.shared.lyricWithTranslation(id: song.id) {
                rawLyrics = lrc
                translationRaw = tlyric
            }
        }

        if let rawLyrics, !rawLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = LyricParser.parse(rawLyrics, translationRaw: translationRaw)
            if !parsed.isEmpty {
                await ATMusicCacheCoordinator.shared.cacheLyric(for: song, content: rawLyrics)
                return parsed
            }
        }

        // 3. 跨源自动匹配
        if let raw = await autoMatchedLyrics(for: song) {
            let parsed = LyricParser.parse(raw)
            if !parsed.isEmpty {
                await ATMusicCacheCoordinator.shared.cacheLyric(for: song, content: raw)
                return parsed
            }
        }

        return []
    }

    private static func autoMatchedLyrics(for song: Song) async -> String? {
        let candidates: [Song]
        if song.source == .synology {
            let matches = await SynologyAPI.shared.metadataCandidates(for: song)
            candidates = matches.map(\.song)
        } else if song.source == .netease {
            candidates = (try? await NetEaseAPI.shared.search(keyword: "\(song.name) \(song.artists)", limit: 12)) ?? []
        } else if song.source == .qq {
            candidates = (try? await QQMusicAPI.shared.searchSongs(keyword: "\(song.name) \(song.artists)", limit: 12)) ?? []
        } else if song.source == .kugou {
            candidates = (try? await KugouMusicAPI.shared.searchSongs(keyword: "\(song.name) \(song.artists)", limit: 12)) ?? []
        } else {
            async let netease = (try? await NetEaseAPI.shared.search(keyword: "\(song.name) \(song.artists)", limit: 8)) ?? []
            async let qq = (try? await QQMusicAPI.shared.searchSongs(keyword: "\(song.name) \(song.artists)", limit: 8)) ?? []
            async let kugou = (try? await KugouMusicAPI.shared.searchSongs(keyword: "\(song.name) \(song.artists)", limit: 8)) ?? []
            let all = await (netease, qq, kugou)
            candidates = all.0 + all.1 + all.2
        }

        for candidate in candidates.sorted(by: { lyricMatchScore($0, to: song) > lyricMatchScore($1, to: song) }).prefix(8) {
            if let raw = await fetchLyrics(for: candidate), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return raw
            }
        }
        return nil
    }

    private static func fetchLyrics(for song: Song) async -> String? {
        switch song.source {
        case .netease:
            guard let result = try? await NetEaseAPI.shared.lyricWithTranslation(id: song.id) else { return nil }
            return result.lrc
        case .qq:
            guard let mid = song.qqMid else { return nil }
            return try? await QQMusicAPI.shared.lyric(songmid: mid)
        case .kugou:
            guard let hash = song.kugouHash else { return nil }
            return await KugouMusicAPI.shared.lyric(hash: hash, duration: song.duration)
        case .synology, .local:
            return nil
        }
    }

    private static func lyricMatchScore(_ candidate: Song, to target: Song) -> Int {
        func normalize(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let targetName = normalize(target.name)
        let candidateName = normalize(candidate.name)
        var score = 0
        if candidateName == targetName { score += 100 } else if candidateName.contains(targetName) || targetName.contains(candidateName) { score += 60 }
        let targetArtists = normalize(target.artists)
        let candidateArtists = normalize(candidate.artists)
        if !targetArtists.isEmpty, candidateArtists == targetArtists { score += 45 } else if !targetArtists.isEmpty && (candidateArtists.contains(targetArtists) || targetArtists.contains(candidateArtists)) { score += 25 }
        let targetAlbum = normalize(target.album)
        let candidateAlbum = normalize(candidate.album)
        if !targetAlbum.isEmpty, candidateAlbum == targetAlbum { score += 20 } else if !targetAlbum.isEmpty && candidateAlbum.contains(targetAlbum) { score += 8 }
        if target.duration > 0, candidate.duration > 0, abs(target.duration - candidate.duration) < 3 { score += 12 }
        return score
    }

    /// 获取原始歌词纯文本（用于保存本地 .lrc 或上传到群晖 NAS 同步）
    static func rawLyricString(for song: Song) async -> String? {
        if song.source == .local, let relativePath = song.localRelativePath {
            let lrcPath = (relativePath as NSString).deletingPathExtension + ".lrc"
            if let lrcURL = try? ManagedAudioPath.resolve(lrcPath),
               let raw = try? String(contentsOf: lrcURL, encoding: .utf8) {
                return raw
            }
        }
        if let localFile = LocalAudioFileManager.shared.file(forSongId: song.identityKey) {
            let lrcPath = (localFile.relativePath as NSString).deletingPathExtension + ".lrc"
            if let lrcURL = try? ManagedAudioPath.resolve(lrcPath),
               let raw = try? String(contentsOf: lrcURL, encoding: .utf8) {
                return raw
            }
        }
        if song.source == .synology {
            if let raw = try? await SynologyAPI.shared.lyrics(song: song) {
                return raw
            }
        } else if song.source == .kugou, let hash = song.kugouHash {
            let raw = await KugouMusicAPI.shared.lyric(hash: hash, duration: song.duration)
            if !raw.isEmpty { return raw }
        } else if song.source == .qq, let mid = song.qqMid {
            if let raw = try? await QQMusicAPI.shared.lyric(songmid: mid) {
                return raw
            }
        } else if song.source == .netease {
            if let (lrc, _) = try? await NetEaseAPI.shared.lyricWithTranslation(id: song.id) {
                return lrc
            }
        }
        return await autoMatchedLyrics(for: song)
    }

}
