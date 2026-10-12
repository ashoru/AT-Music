import Foundation

/// 第三方解锁源配置。
/// kind：音源类型标识，用于兼容不同导入格式。
/// template：请求 URL 模板，支持 {id}、{source}、{quality} 占位符。
/// headers：可选的请求头与内置元数据。
/// quality：默认音质选择。
/// script：LX / Baka 风格 JS 脚本内容。
struct ThirdPartySource: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var name: String
    var kind: String = "keyword"
    var template: String
    var urlPath: String = "url"
    var headers: [String: String] = [:]
    var quality: String = "320k"
    var script: String?
    var enabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, kind, template, urlPath, headers, quality, script, enabled
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        kind: String = "keyword",
        template: String,
        urlPath: String = "url",
        headers: [String: String] = [:],
        quality: String = "320k",
        script: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.template = template
        self.urlPath = urlPath
        self.headers = headers
        self.quality = quality
        self.script = script
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名音源"
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "keyword"
        template = try container.decodeIfPresent(String.self, forKey: .template) ?? ""
        urlPath = try container.decodeIfPresent(String.self, forKey: .urlPath) ?? "url"
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        quality = try container.decodeIfPresent(String.self, forKey: .quality) ?? headers["quality"] ?? "320k"
        script = try container.decodeIfPresent(String.self, forKey: .script)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// 第三方音源管理：只保存用户导入的音源配置。
final class UnblockSourceStore: ObservableObject {
    static let shared = UnblockSourceStore()
    private static let removedBuiltInSourceIDs: Set<String> = [
        "atmusic.preset.shiqianjiang.lx.v7",
        "atmusic.preset.shiqianjiang.cr.v7",
        "atmusic.preset.shiqianjiang.qt.v7",
        "atmusic.preset.legacy.guoyue.qq.v1",
        "atmusic.preset.legacy.guoyue.netease.v1",
        "atmusic.preset.cerumusic.free.v1",
        "atmusic.preset.quandouyao.free.v1",
        "atmusic.special.cr.v1"
    ]
    @Published var sources: [ThirdPartySource] {
        didSet { save() }
    }

    var managementVisibleSources: [ThirdPartySource] {
        sources
    }

    private let defaults = UserDefaults.standard
    private let presetsKey = "atmusic.unblock.presets"
    private let legacyCustomKey = "atmusic.unblock.custom"
    private let legacyLXKey = "atmusic.unblock.lxScripts"

    private init() {
        let savedSources: [ThirdPartySource]
        if let data = defaults.data(forKey: presetsKey),
           let list = try? JSONDecoder().decode([ThirdPartySource].self, from: data) {
            savedSources = list
        } else if let data = defaults.data(forKey: legacyCustomKey),
                  let list = try? JSONDecoder().decode([ThirdPartySource].self, from: data) {
            savedSources = list
        } else {
            savedSources = []
        }

        // 旧版本的内置预设全部丢弃，只保留用户导入的配置。
        var seen = Set<String>()
        sources = savedSources.compactMap { source in
            guard !Self.removedBuiltInSourceIDs.contains(source.id),
                  seen.insert(source.id).inserted else { return nil }
            return source
        }

        // 无任何启用音源时，自动注入内置洛雪音源，恢复开箱即用的第三方 VIP 兜底
        // （用户已导入并启用的音源保持优先，不被内置源覆盖）
        if !sources.contains(where: { $0.enabled }) {
            let builtIn = BuiltInLXSources.makeSources()
            for source in builtIn where !sources.contains(where: { $0.name == source.name }) {
                sources.append(source)
            }
        }
        defaults.removeObject(forKey: legacyCustomKey)
        defaults.removeObject(forKey: legacyLXKey)
        defaults.removeObject(forKey: "atmusic.thirdPartyAPIKeys")
        defaults.removeObject(forKey: "atmusic.paidAudioSource.usageRecorded")
        defaults.removeObject(forKey: "atmusic.enableUnblock")
        defaults.removeObject(forKey: "atmusic.useFreeAudioSource")
        defaults.removeObject(forKey: "atmusic.showThirdPartyKeys")
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: presetsKey)
        }
    }

    func addSource(_ source: ThirdPartySource) {
        upsert(source)
    }

    func addSources(_ newSources: [ThirdPartySource]) {
        guard !newSources.isEmpty else { return }
        var merged = sources
        for source in newSources {
            if let index = merged.firstIndex(where: { $0.id == source.id }) {
                merged[index] = source
            } else {
                merged.append(source)
            }
        }
        sources = merged
        save()
    }

    func upsert(_ source: ThirdPartySource) {
        var merged = sources
        if let index = merged.firstIndex(where: { $0.id == source.id }) {
            merged[index] = source
        } else {
            merged.append(source)
        }
        sources = merged
        save()
    }

    func moveSource(id: String, by offset: Int) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index + offset), max(0, sources.count - 1))
        guard target != index else { return }
        var reordered = sources
        let item = reordered.remove(at: index)
        reordered.insert(item, at: target)
        sources = reordered
        save()
    }

    func moveManagementSource(id: String, by offset: Int) {
        let visibleIDs = managementVisibleSources.map(\.id)
        guard let visibleIndex = visibleIDs.firstIndex(of: id) else { return }
        let targetVisibleIndex = visibleIndex + offset
        guard visibleIDs.indices.contains(targetVisibleIndex) else { return }
        let targetID = visibleIDs[targetVisibleIndex]
        guard let sourceIndex = sources.firstIndex(where: { $0.id == id }) else { return }

        var reordered = sources
        let item = reordered.remove(at: sourceIndex)
        guard let adjustedTargetIndex = reordered.firstIndex(where: { $0.id == targetID }) else { return }
        let insertionIndex = targetVisibleIndex > visibleIndex
            ? adjustedTargetIndex + 1
            : adjustedTargetIndex
        reordered.insert(item, at: min(insertionIndex, reordered.count))
        sources = reordered
        save()
    }

    func updateEnabled(id: String, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        var updated = sources
        updated[index].enabled = enabled
        sources = updated
        save()
    }

    @discardableResult
    func removeSource(id: String) -> Bool {
        let originalCount = sources.count
        sources.removeAll { $0.id == id }
        save()
        return sources.count != originalCount
    }

}

extension UnblockSourceStore {
    func availableThirdPartyQualities() -> [ThirdPartyAudioQuality] {
        let options = sources
            .filter(\.enabled)
            .flatMap { Self.supportedQualities(for: $0) }
            .uniquePreservingOrder()
        return options.isEmpty ? ThirdPartyAudioQuality.allCases : options
    }

    static func supportedQualities(
        for source: ThirdPartySource,
        providerCode: String? = nil
    ) -> [ThirdPartyAudioQuality] {
        let explicit = explicitQualities(
            from: source.headers["qualities"] ?? source.headers["qualityOptions"] ?? source.headers["qualitys"]
        )
        if !explicit.isEmpty {
            if let providerCode {
                let platform = Set(ThirdPartyAudioQuality.supported(providerCode: providerCode))
                return explicit.filter { platform.contains($0) }
            }
            return explicit
        }

        if let script = source.script,
           let explicit = scriptQualities(from: script),
           !explicit.isEmpty {
            if let providerCode {
                let platform = Set(ThirdPartyAudioQuality.supported(providerCode: providerCode))
                return explicit.filter { platform.contains($0) }
            }
            return explicit
        }

        if let providerCode {
            return ThirdPartyAudioQuality.supported(providerCode: providerCode)
        }

        if let sourceProvider = source.headers["source"] ?? source.headers["platform"] {
            return ThirdPartyAudioQuality.supported(providerCode: sourceProvider)
        }

        return ThirdPartyAudioQuality.allCases
    }

    private static func explicitQualities(from raw: String?) -> [ThirdPartyAudioQuality] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|/[]\"'"))
        return raw
            .components(separatedBy: separators)
            .compactMap { ThirdPartyAudioQuality(sourceValue: $0) }
            .uniquePreservingOrder()
    }

    private static func scriptQualities(from script: String) -> [ThirdPartyAudioQuality]? {
        let pattern = #"(?i)(?:qualitys?|qualityOptions)\s*[:=]\s*\[([^\]]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: script,
                options: [],
                range: NSRange(script.startIndex..<script.endIndex, in: script)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: script) else {
            return nil
        }
        return explicitQualities(from: String(script[range]))
    }
}

private extension Array where Element: Hashable {
    func uniquePreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
// MARK: - 内置洛雪音源（随 App 打包，开箱即用：无用户导入源时自动注入，恢复第三方 VIP 兜底）

enum BuiltInLXSources {
    static let bundled: [(name: String, base64: String)] = [
        ("AT-Music 终极极速音源", "LyohCiAqIEBuYW1lIEFULU11c2ljIOe7iOaegeaegemAn+iBmuWQiOmfs+a6kAogKiBAZGVzY3JpcHRpb24g5LiT5Li6IEFULU11c2ljIOaJk+mAoOeahOaegemAn+eos+WumumrmOWPr+eUqOmfs+a6kO+8muaVtOWQiOWumOaWueebtOmTvuOAgei9puacuuS4k+e6v+OAgeafs+S6keS4k+e6v+OAgUdEU3R1ZGlvIOetieS8mOi0qOiKgueCue+8jOavq+enkue6p+WHuuWjsOS4juWkmue6p+W5s+a7keWuueeBvuOAggogKiBAdmVyc2lvbiA1LjAuMAogKiBAYXV0aG9yIEFULU11c2ljICYgR2VtaW5pCiAqLwoKY29uc3QgeyBFVkVOVF9OQU1FUywgcmVxdWVzdCwgb24sIHNlbmQsIHV0aWxzLCBlbnYsIHZlcnNpb24sIGN1cnJlbnRTY3JpcHRJbmZvIH0gPSBnbG9iYWxUaGlzLmx4OwoKLy8gSFRUUCBHRVQg6K+35rGC5bCB6KOFCmNvbnN0IGh0dHBHZXQgPSAodXJsLCBoZWFkZXJzID0ge30sIHRpbWVvdXQgPSAzNTAwKSA9PiB7CiAgcmV0dXJuIG5ldyBQcm9taXNlKChyZXNvbHZlLCByZWplY3QpID0+IHsKICAgIHJlcXVlc3QodXJsLCB7CiAgICAgIG1ldGhvZDogJ0dFVCcsCiAgICAgIGhlYWRlcnM6IE9iamVjdC5hc3NpZ24oewogICAgICAgICdVc2VyLUFnZW50JzogJ01vemlsbGEvNS4wIChpUGhvbmU7IENQVSBpUGhvbmUgT1MgMTdfNSBsaWtlIE1hYyBPUyBYKSBBcHBsZVdlYktpdC82MDUuMS4xNSAoS0hUTUwsIGxpa2UgR2Vja28pIE1vYmlsZS8xNUUxNDgnLAogICAgICAgICdBY2NlcHQnOiAnKi8qJwogICAgICB9LCBoZWFkZXJzKSwKICAgICAgdGltZW91dDogdGltZW91dAogICAgfSwgKGVyciwgcmVzcCkgPT4gewogICAgICBpZiAoZXJyKSByZXR1cm4gcmVqZWN0KGVycik7CiAgICAgIGlmICghcmVzcCkgcmV0dXJuIHJlamVjdChuZXcgRXJyb3IoJ+aXoOWTjeW6lCcpKTsKICAgICAgY29uc3QgYm9keSA9IHJlc3AuYm9keTsKICAgICAgaWYgKHR5cGVvZiBib2R5ID09PSAnb2JqZWN0JyAmJiBib2R5ICE9PSBudWxsKSByZXR1cm4gcmVzb2x2ZShib2R5KTsKICAgICAgaWYgKHR5cGVvZiBib2R5ID09PSAnc3RyaW5nJykgewogICAgICAgIHRyeSB7CiAgICAgICAgICByZXR1cm4gcmVzb2x2ZShKU09OLnBhcnNlKGJvZHkpKTsKICAgICAgICB9IGNhdGNoIChlKSB7CiAgICAgICAgICByZXR1cm4gcmVzb2x2ZShib2R5KTsKICAgICAgICB9CiAgICAgIH0KICAgICAgcmVzb2x2ZShib2R5KTsKICAgIH0pOwogIH0pOwp9OwoKLy8gSFRUUCBQT1NUIOivt+axguWwgeijhQpjb25zdCBodHRwUG9zdCA9ICh1cmwsIGRhdGEsIGhlYWRlcnMgPSB7fSwgdGltZW91dCA9IDM1MDApID0+IHsKICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUsIHJlamVjdCkgPT4gewogICAgY29uc3QgaXNKc29uID0gdHlwZW9mIGRhdGEgPT09ICdvYmplY3QnOwogICAgY29uc3QgcG9zdEhlYWRlcnMgPSBPYmplY3QuYXNzaWduKHsKICAgICAgJ1VzZXItQWdlbnQnOiAnTW96aWxsYS81LjAgKGlQaG9uZTsgQ1BVIGlQaG9uZSBPUyAxN181IGxpa2UgTWFjIE9TIFgpIEFwcGxlV2ViS2l0LzYwNS4xLjE1JywKICAgICAgJ0NvbnRlbnQtVHlwZSc6IGlzSnNvbiA/ICdhcHBsaWNhdGlvbi9qc29uJyA6ICdhcHBsaWNhdGlvbi94LXd3dy1mb3JtLXVybGVuY29kZWQnCiAgICB9LCBoZWFkZXJzKTsKICAgIHJlcXVlc3QodXJsLCB7CiAgICAgIG1ldGhvZDogJ1BPU1QnLAogICAgICBoZWFkZXJzOiBwb3N0SGVhZGVycywKICAgICAgYm9keTogaXNKc29uID8gSlNPTi5zdHJpbmdpZnkoZGF0YSkgOiBkYXRhLAogICAgICB0aW1lb3V0OiB0aW1lb3V0CiAgICB9LCAoZXJyLCByZXNwKSA9PiB7CiAgICAgIGlmIChlcnIpIHJldHVybiByZWplY3QoZXJyKTsKICAgICAgaWYgKCFyZXNwKSByZXR1cm4gcmVqZWN0KG5ldyBFcnJvcign5peg5ZON5bqUJykpOwogICAgICBjb25zdCBib2R5ID0gcmVzcC5ib2R5OwogICAgICBpZiAodHlwZW9mIGJvZHkgPT09ICdvYmplY3QnICYmIGJvZHkgIT09IG51bGwpIHJldHVybiByZXNvbHZlKGJvZHkpOwogICAgICBpZiAodHlwZW9mIGJvZHkgPT09ICdzdHJpbmcnKSB7CiAgICAgICAgdHJ5IHsKICAgICAgICAgIHJldHVybiByZXNvbHZlKEpTT04ucGFyc2UoYm9keSkpOwogICAgICAgIH0gY2F0Y2ggKGUpIHsKICAgICAgICAgIHJldHVybiByZXNvbHZlKGJvZHkpOwogICAgICAgIH0KICAgICAgfQogICAgICByZXNvbHZlKGJvZHkpOwogICAgfSk7CiAgfSk7Cn07CgovLyDov4fmu6Tml6DmlYgv5Y2g5L2N6Z+z6aKRIFVSTApjb25zdCBpc1ZhbGlkQXVkaW9VcmwgPSAodXJsKSA9PiB7CiAgaWYgKCF1cmwgfHwgdHlwZW9mIHVybCAhPT0gJ3N0cmluZycpIHJldHVybiBmYWxzZTsKICBjb25zdCB0cmltbWVkID0gdXJsLnRyaW0oKTsKICBpZiAoIXRyaW1tZWQuc3RhcnRzV2l0aCgnaHR0cDovLycpICYmICF0cmltbWVkLnN0YXJ0c1dpdGgoJ2h0dHBzOi8vJykpIHJldHVybiBmYWxzZTsKICBpZiAodHJpbW1lZC5pbmNsdWRlcygnMjAyNi0wNi0xNy0xOTU3MjJfMTA0NTk1JykpIHJldHVybiBmYWxzZTsgLy8g6L+H5ruk5p+z5LqRIFRUUyDmiqXplJnljaDkvY3pn7PpopEKICBpZiAodHJpbW1lZC5pbmNsdWRlcygnbXVzaWMuMTYzLmNvbS80MDQnKSkgcmV0dXJuIGZhbHNlOyAvLyDov4fmu6TnvZHmmJPkupEgNDA0IOi3s+i9rAogIGlmICh0cmltbWVkLmluY2x1ZGVzKCdlcnJvci5waHAnKSB8fCB0cmltbWVkLmluY2x1ZGVzKCdlcnJvcl91cmwnKSkgcmV0dXJuIGZhbHNlOwogIHJldHVybiB0cnVlOwp9OwoKLy8g5o+Q5Y+W5q2M5puy5qCH6K+GCmNvbnN0IGdldFNvbmdJZGVudGlmaWVyID0gKHNvdXJjZSwgaW5mbykgPT4gewogIGNvbnN0IG11c2ljSW5mbyA9IGluZm8ubXVzaWNJbmZvIHx8IHt9OwogIGlmIChzb3VyY2UgPT09ICd0eCcpIHsKICAgIHJldHVybiBtdXNpY0luZm8uc29uZ21pZCB8fCBtdXNpY0luZm8ubWlkIHx8IG11c2ljSW5mby5pZCB8fCAnJzsKICB9CiAgaWYgKHNvdXJjZSA9PT0gJ2tnJykgewogICAgcmV0dXJuIG11c2ljSW5mby5oYXNoIHx8IG11c2ljSW5mby5pZCB8fCAnJzsKICB9CiAgcmV0dXJuIG11c2ljSW5mby5pZCB8fCBtdXNpY0luZm8uc29uZ21pZCB8fCAnJzsKfTsKCi8vID09PT09PT09PT09PT09PT09IOWQhOW5s+WPsOS4k+e6v+ino+aekCA9PT09PT09PT09PT09PT09PQoKLy8gMS4g5p+z5LqR6auY6YCf5LiT57q/ICjmlK/mjIEgd3ksIHR4LCBrZywga3cpCmNvbnN0IGZldGNoTGl1WXVuID0gYXN5bmMgKHNvdXJjZSwgaWQsIHF1YWxpdHkpID0+IHsKICBjb25zdCBxTWFwID0gewogICAgJzEyOGsnOiAnMTI4aycsCiAgICAnMzIwayc6ICczMjBrJywKICAgICdmbGFjJzogJ2ZsYWMnLAogICAgJ2ZsYWMyNGJpdCc6ICdtYXN0ZXInLAogICAgJ2hpcmVzJzogJ21hc3RlcicsCiAgICAnbWFzdGVyJzogJ21hc3RlcicKICB9OwogIGNvbnN0IHEgPSBxTWFwW3F1YWxpdHldIHx8ICczMjBrJzsKICBjb25zdCB1cmwgPSAnaHR0cHM6Ly9hcGkubGl1eXVuaWRjLmNuL2JhaW11c2ljL211c2ljdXJsLnBocD9zb3VyY2U9JyArIHNvdXJjZSArICcmbXVzaWNJZD0nICsgZW5jb2RlVVJJQ29tcG9uZW50KGlkKSArICcmcXVhbGl0eT0nICsgcTsKICBjb25zdCByZXMgPSBhd2FpdCBodHRwR2V0KHVybCwge30sIDMwMDApOwogIGlmIChyZXMgJiYgKHJlcy5jb2RlID09PSAwIHx8IHJlcy5jb2RlID09PSAyMDApICYmIHJlcy51cmwpIHsKICAgIGlmIChpc1ZhbGlkQXVkaW9VcmwocmVzLnVybCkpIHsKICAgICAgcmV0dXJuIHsKICAgICAgICB1cmw6IHJlcy51cmwsCiAgICAgICAgaGVhZGVyczogeyAnVXNlci1BZ2VudCc6ICdNb3ppbGxhLzUuMCcgfQogICAgICB9OwogICAgfQogIH0KICB0aHJvdyBuZXcgRXJyb3IoJ+afs+S6keaXoOWPr+eUqOebtOmTvicpOwp9OwoKLy8gMi4g572R5piT5LqR5a6Y5pa555u06ZO+ICjlpJbpk77lv6vpgJ/pgJrpgZMpCmNvbnN0IGZldGNoTmV0RWFzZU91dGVyID0gYXN5bmMgKGlkKSA9PiB7CiAgY29uc3QgdXJsID0gJ2h0dHBzOi8vbXVzaWMuMTYzLmNvbS9zb25nL21lZGlhL291dGVyL3VybD9pZD0nICsgZW5jb2RlVVJJQ29tcG9uZW50KGlkKSArICcubXAzJzsKICByZXR1cm4gewogICAgdXJsOiB1cmwsCiAgICBoZWFkZXJzOiB7CiAgICAgICdVc2VyLUFnZW50JzogJ01vemlsbGEvNS4wIChpUGhvbmU7IENQVSBpUGhvbmUgT1MgMTdfNSBsaWtlIE1hYyBPUyBYKScsCiAgICAgICdSZWZlcmVyJzogJ2h0dHBzOi8vbXVzaWMuMTYzLmNvbS8nCiAgICB9CiAgfTsKfTsKCi8vIDMuIEdEU3R1ZGlvIOWkh+eUqOiKgueCuQpjb25zdCBmZXRjaEdEU3R1ZGlvID0gYXN5bmMgKHNvdXJjZSwgaWQpID0+IHsKICBjb25zdCBzcmMgPSBzb3VyY2UgPT09ICd3eScgPyAnbmV0ZWFzZScgOiAoc291cmNlID09PSAndHgnID8gJ3FxJyA6IHNvdXJjZSk7CiAgY29uc3QgdXJsID0gJ2h0dHBzOi8vbXVzaWMtYXBpLmdkc3R1ZGlvLnh5ei9hcGkucGhwP3R5cGVzPXVybCZzb3VyY2U9JyArIHNyYyArICcmaWQ9JyArIGVuY29kZVVSSUNvbXBvbmVudChpZCk7CiAgY29uc3QgcmVzID0gYXdhaXQgaHR0cEdldCh1cmwsIHt9LCAzNTAwKTsKICBpZiAocmVzICYmIHJlcy51cmwgJiYgaXNWYWxpZEF1ZGlvVXJsKHJlcy51cmwpKSB7CiAgICByZXR1cm4gewogICAgICB1cmw6IHJlcy51cmwsCiAgICAgIGhlYWRlcnM6IHsKICAgICAgICAnVXNlci1BZ2VudCc6ICdNb3ppbGxhLzUuMCAoV2luZG93cyBOVCAxMC4wOyBXaW42NDsgeDY0KSBBcHBsZVdlYktpdC81MzcuMzYnLAogICAgICAgICdSZWZlcmVyJzogJ2h0dHBzOi8vbXVzaWMtYXBpLmdkc3R1ZGlvLnh5ei8nCiAgICAgIH0KICAgIH07CiAgfQogIHRocm93IG5ldyBFcnJvcignR0RTdHVkaW8g5peg5Y+v55So5Zyw5Z2AJyk7Cn07CgovLyA0LiDphbfmiJHpn7PkuZDlrpjmlrnovabmnLrkuJPnur8gKOi2hemrmOmAnyAxMjBtcyDnm7Tlh7opCmNvbnN0IGZldGNoS3V3b01vYmkgPSBhc3luYyAoaWQsIHF1YWxpdHkpID0+IHsKICBjb25zdCBick1hcCA9IHsKICAgICcxMjhrJzogJzEyOGttcDMnLAogICAgJzE5MmsnOiAnMTkya21wMycsCiAgICAnMzIwayc6ICczMjBrbXAzJywKICAgICdmbGFjJzogJzIwMDBrZmxhYycsCiAgICAnZmxhYzI0Yml0JzogJzQwMDBrZmxhYycKICB9OwogIGNvbnN0IGJyID0gYnJNYXBbcXVhbGl0eV0gfHwgJzMyMGttcDMnOwogIGNvbnN0IHVybCA9ICdodHRwczovL25tb2JpLmt1d28uY24vbW9iaS5zP2Y9d2ViJnVzZXI9MCZzb3VyY2U9a3dwbGF5ZXJoZF9hcl80LjMuMC44X3RpYW5iYW9fVDFBX3FpcnVpLmFwayZ0eXBlPWNvbnZlcnRfdXJsX3dpdGhfc2lnbiZyaWQ9JyArIGVuY29kZVVSSUNvbXBvbmVudChpZCkgKyAnJmJyPScgKyBicjsKICBjb25zdCByZXMgPSBhd2FpdCBodHRwR2V0KHVybCwgeyAnVXNlci1BZ2VudCc6ICdva2h0dHAvMy4xMC4wJyB9LCAyNTAwKTsKICBpZiAocmVzICYmIChyZXMuY29kZSA9PT0gMjAwIHx8IHJlcy5jb2RlID09PSAnMjAwJykgJiYgcmVzLmRhdGEgJiYgcmVzLmRhdGEudXJsKSB7CiAgICBpZiAoaXNWYWxpZEF1ZGlvVXJsKHJlcy5kYXRhLnVybCkpIHsKICAgICAgcmV0dXJuIHsKICAgICAgICB1cmw6IHJlcy5kYXRhLnVybCwKICAgICAgICBoZWFkZXJzOiB7CiAgICAgICAgICAnVXNlci1BZ2VudCc6ICdva2h0dHAvMy4xMC4wJywKICAgICAgICAgICdSZWZlcmVyJzogJ2h0dHA6Ly9rdXdvLmNuLycKICAgICAgICB9CiAgICAgIH07CiAgICB9CiAgfQogIHRocm93IG5ldyBFcnJvcign6YW35oiR6L2m5py65o6l5Y+j5aSx6LSlJyk7Cn07CgovLyA1LiBRUSDpn7PkuZDlrpjmlrnnm7Tov57pgJrpgZMgKOmSiOWvueWFjei0ueatjOabsikKY29uc3QgZmV0Y2hRUU9mZmljaWFsID0gYXN5bmMgKHNvbmdtaWQpID0+IHsKICBjb25zdCBmaWxlID0gJ001MDAnICsgc29uZ21pZCArICcubXAzJzsKICBjb25zdCBndWlkID0gJzEwMDAwMDAwMDAnOwogIGNvbnN0IHJlcURhdGEgPSB7CiAgICByZXFfMDogewogICAgICBtb2R1bGU6ICd2a2V5LkdldFZrZXlTZXJ2ZXInLAogICAgICBtZXRob2Q6ICdDZ2lHZXRWa2V5JywKICAgICAgcGFyYW06IHsgZmlsZW5hbWU6IFtmaWxlXSwgZ3VpZDogZ3VpZCwgc29uZ21pZDogW3NvbmdtaWRdLCBzb25ndHlwZTogWzBdLCB1aW46ICcwJywgbG9naW5mbGFnOiAwLCBwbGF0Zm9ybTogJzIwJyB9CiAgICB9LAogICAgbG9naW5VaW46ICcwJywKICAgIGNvbW06IHsgdWluOiAnMCcsIGZvcm1hdDogJ2pzb24nLCBjdDogMjQsIGN2OiAwIH0KICB9OwogIGNvbnN0IHJlcyA9IGF3YWl0IGh0dHBQb3N0KCdodHRwczovL3UueS5xcS5jb20vY2dpLWJpbi9tdXNpY3UuZmNnJywgcmVxRGF0YSwgewogICAgJ1VzZXItQWdlbnQnOiAnTW96aWxsYS81LjAgKFdpbmRvd3MgTlQgMTAuMDsgV2luNjQ7IHg2NCkgQXBwbGVXZWJLaXQvNTM3LjM2JywKICAgICdSZWZlcmVyJzogJ2h0dHBzOi8veS5xcS5jb20vJwogIH0sIDI1MDApOwogIGlmIChyZXMgJiYgcmVzLnJlcV8wICYmIHJlcy5yZXFfMC5kYXRhICYmIHJlcy5yZXFfMC5kYXRhLm1pZHVybGluZm8gJiYgcmVzLnJlcV8wLmRhdGEubWlkdXJsaW5mb1swXSkgewogICAgY29uc3QgaW5mbyA9IHJlcy5yZXFfMC5kYXRhLm1pZHVybGluZm9bMF07CiAgICBpZiAoaW5mby5wdXJsICYmIGlzVmFsaWRBdWRpb1VybChpbmZvLnB1cmwpKSB7CiAgICAgIGNvbnN0IHNpcCA9IChyZXMucmVxXzAuZGF0YS5zaXAgJiYgcmVzLnJlcV8wLmRhdGEuc2lwWzBdKSB8fCAnaHR0cHM6Ly9pc3VyZS5zdHJlYW0ucXFtdXNpYy5xcS5jb20vJzsKICAgICAgcmV0dXJuIHsKICAgICAgICB1cmw6IHNpcCArIGluZm8ucHVybCwKICAgICAgICBoZWFkZXJzOiB7CiAgICAgICAgICAnVXNlci1BZ2VudCc6ICdNb3ppbGxhLzUuMCAoV2luZG93cyBOVCAxMC4wOyBXaW42NDsgeDY0KScsCiAgICAgICAgICAnUmVmZXJlcic6ICdodHRwczovL3kucXEuY29tLycKICAgICAgICB9CiAgICAgIH07CiAgICB9CiAgfQogIHRocm93IG5ldyBFcnJvcignUVEg5a6Y5pa55o6l5Y+j5pegIHB1cmwnKTsKfTsKCi8vIDYuIOWSquWSleWumOaWuei9puacuuS4k+e6vwpjb25zdCBmZXRjaE1pZ3VNb2JpID0gYXN5bmMgKGlkKSA9PiB7CiAgY29uc3QgdXJsID0gJ2h0dHBzOi8vYXBwLmMubmYubWlndS5jbi9NSUdVTTIuMC9zdHJhdGVneS9saXN0ZW4tdXJsL3YyLjI/bmV0VHlwZT0wMSZyZXNvdXJjZVR5cGU9MiZzb25nSWQ9JyArIGVuY29kZVVSSUNvbXBvbmVudChpZCkgKyAnJmNvbnRlbnRJZD0nICsgZW5jb2RlVVJJQ29tcG9uZW50KGlkKTsKICBjb25zdCByZXMgPSBhd2FpdCBodHRwR2V0KHVybCwgeyAnVXNlci1BZ2VudCc6ICdNb3ppbGxhLzUuMCcgfSwgMjUwMCk7CiAgaWYgKHJlcyAmJiByZXMuZGF0YSAmJiByZXMuZGF0YS51cmwgJiYgaXNWYWxpZEF1ZGlvVXJsKHJlcy5kYXRhLnVybCkpIHsKICAgIHJldHVybiB7CiAgICAgIHVybDogcmVzLmRhdGEudXJsLAogICAgICBoZWFkZXJzOiB7CiAgICAgICAgJ1VzZXItQWdlbnQnOiAnTW96aWxsYS81LjAnLAogICAgICAgICdSZWZlcmVyJzogJ2h0dHBzOi8vbXVzaWMubWlndS5jbi8nCiAgICAgIH0KICAgIH07CiAgfQogIHRocm93IG5ldyBFcnJvcign5ZKq5ZKV5o6l5Y+j5peg55u06ZO+Jyk7Cn07CgovLyA9PT09PT09PT09PT09PT09PSDkuovku7blk43lupTkuI7nq57pgJ/osIPluqYgPT09PT09PT09PT09PT09PT0KCm9uKEVWRU5UX05BTUVTLnJlcXVlc3QsIGFzeW5jICh7IGFjdGlvbiwgc291cmNlLCBpbmZvIH0pID0+IHsKICBpZiAoYWN0aW9uICE9PSAnbXVzaWNVcmwnKSB7CiAgICB0aHJvdyBuZXcgRXJyb3IoJ+S4jeaUr+aMgeeahOaTjeS9nDogJyArIGFjdGlvbik7CiAgfQogIGNvbnN0IGlkID0gZ2V0U29uZ0lkZW50aWZpZXIoc291cmNlLCBpbmZvKTsKICBjb25zdCBxdWFsaXR5ID0gaW5mby50eXBlIHx8ICczMjBrJzsKICBpZiAoIWlkKSB7CiAgICB0aHJvdyBuZXcgRXJyb3IoJ+e8uuWwkeatjOabsuagh+ivhiBJRCcpOwogIH0KCiAgY29uc3QgdGFza3MgPSBbXTsKCiAgaWYgKHNvdXJjZSA9PT0gJ2t3JykgewogICAgLy8g6YW35oiR77ya6aaW6YCJ6L2m5py65LiT57q/ICgxMjBtcynvvIzlpIfpgInmn7PkupEKICAgIHRhc2tzLnB1c2goZmV0Y2hLdXdvTW9iaShpZCwgcXVhbGl0eSkpOwogICAgdGFza3MucHVzaChmZXRjaExpdVl1bihzb3VyY2UsIGlkLCBxdWFsaXR5KSk7CiAgfSBlbHNlIGlmIChzb3VyY2UgPT09ICd3eScpIHsKICAgIC8vIOe9keaYk+S6ke+8mummlumAieafs+S6keS4k+e6v++8jOW5tuihjCBHRFN0dWRpbyDkuI7lrpjmlrnlpJbpk74KICAgIHRhc2tzLnB1c2goZmV0Y2hMaXVZdW4oc291cmNlLCBpZCwgcXVhbGl0eSkpOwogICAgdGFza3MucHVzaChmZXRjaEdEU3R1ZGlvKHNvdXJjZSwgaWQpKTsKICAgIHRhc2tzLnB1c2goZmV0Y2hOZXRFYXNlT3V0ZXIoaWQpKTsKICB9IGVsc2UgaWYgKHNvdXJjZSA9PT0gJ3R4JykgewogICAgLy8gUVHpn7PkuZDvvJrpppbpgInmn7PkupHkuJPnur/vvIzlubbooYzlrpjmlrnpgJrpgZMKICAgIHRhc2tzLnB1c2goZmV0Y2hMaXVZdW4oc291cmNlLCBpZCwgcXVhbGl0eSkpOwogICAgdGFza3MucHVzaChmZXRjaFFRT2ZmaWNpYWwoaWQpKTsKICB9IGVsc2UgaWYgKHNvdXJjZSA9PT0gJ2tnJykgewogICAgLy8g6YW354uX6Z+z5LmQ77ya6aaW6YCJ5p+z5LqR5LiT57q/CiAgICB0YXNrcy5wdXNoKGZldGNoTGl1WXVuKHNvdXJjZSwgaWQsIHF1YWxpdHkpKTsKICB9IGVsc2UgaWYgKHNvdXJjZSA9PT0gJ21nJykgewogICAgLy8g5ZKq5ZKV6Z+z5LmQ77ya6L2m5py65LiT57q/CiAgICB0YXNrcy5wdXNoKGZldGNoTWlndU1vYmkoaWQpKTsKICB9IGVsc2UgewogICAgdGFza3MucHVzaChmZXRjaExpdVl1bihzb3VyY2UsIGlkLCBxdWFsaXR5KSk7CiAgfQoKICAvLyDmnoHpgJ/nq57pgJ/mqKHlvI/vvJrmnIDlv6vov5Tlm57kuJTmnInmlYjnmoToioLngrnkvJjlhYjlkb3kuK0KICB0cnkgewogICAgY29uc3QgcmVzdWx0ID0gYXdhaXQgUHJvbWlzZS5hbnkodGFza3MpOwogICAgaWYgKHJlc3VsdCAmJiByZXN1bHQudXJsICYmIGlzVmFsaWRBdWRpb1VybChyZXN1bHQudXJsKSkgewogICAgICByZXR1cm4gcmVzdWx0OwogICAgfQogIH0gY2F0Y2ggKGVycikgewogICAgLy8g5a6554G+6YCQ5Liq6ZmN57qn5Zue6YCACiAgICBmb3IgKGNvbnN0IHQgb2YgdGFza3MpIHsKICAgICAgdHJ5IHsKICAgICAgICBjb25zdCByZXMgPSBhd2FpdCB0OwogICAgICAgIGlmIChyZXMgJiYgcmVzLnVybCAmJiBpc1ZhbGlkQXVkaW9VcmwocmVzLnVybCkpIHsKICAgICAgICAgIHJldHVybiByZXM7CiAgICAgICAgfQogICAgICB9IGNhdGNoIChlKSB7fQogICAgfQogIH0KCiAgdGhyb3cgbmV3IEVycm9yKCfmiYDmnInpn7PmupDpgJrpgZPop6PmnpDlpLHotKU6ICcgKyBzb3VyY2UgKyAnIGlkPScgKyBpZCk7Cn0pOwoKLy8g5Yid5aeL5YyW6Z+z5rqQ5aOw5piOCnNlbmQoRVZFTlRfTkFNRVMuaW5pdGVkLCB7CiAgb3BlbkRldlRvb2xzOiBmYWxzZSwKICBzb3VyY2VzOiB7CiAgICB3eTogewogICAgICBuYW1lOiAn572R5piT5LqR6Z+z5LmQJywKICAgICAgdHlwZTogJ211c2ljJywKICAgICAgYWN0aW9uczogWydtdXNpY1VybCddLAogICAgICBxdWFsaXR5czogWycxMjhrJywgJzMyMGsnLCAnZmxhYycsICdmbGFjMjRiaXQnLCAnbWFzdGVyJ10KICAgIH0sCiAgICB0eDogewogICAgICBuYW1lOiAnUVHpn7PkuZAnLAogICAgICB0eXBlOiAnbXVzaWMnLAogICAgICBhY3Rpb25zOiBbJ211c2ljVXJsJ10sCiAgICAgIHF1YWxpdHlzOiBbJzEyOGsnLCAnMzIwaycsICdmbGFjJywgJ2ZsYWMyNGJpdCcsICdtYXN0ZXInXQogICAgfSwKICAgIGtnOiB7CiAgICAgIG5hbWU6ICfphbfni5fpn7PkuZAnLAogICAgICB0eXBlOiAnbXVzaWMnLAogICAgICBhY3Rpb25zOiBbJ211c2ljVXJsJ10sCiAgICAgIHF1YWxpdHlzOiBbJzEyOGsnLCAnMzIwaycsICdmbGFjJywgJ2ZsYWMyNGJpdCcsICdtYXN0ZXInXQogICAgfSwKICAgIGt3OiB7CiAgICAgIG5hbWU6ICfphbfmiJHpn7PkuZAnLAogICAgICB0eXBlOiAnbXVzaWMnLAogICAgICBhY3Rpb25zOiBbJ211c2ljVXJsJ10sCiAgICAgIHF1YWxpdHlzOiBbJzEyOGsnLCAnMTkyaycsICczMjBrJywgJ2ZsYWMnLCAnZmxhYzI0Yml0J10KICAgIH0sCiAgICBtZzogewogICAgICBuYW1lOiAn5ZKq5ZKV6Z+z5LmQJywKICAgICAgdHlwZTogJ211c2ljJywKICAgICAgYWN0aW9uczogWydtdXNpY1VybCddLAogICAgICBxdWFsaXR5czogWycxMjhrJywgJzMyMGsnLCAnZmxhYyddCiAgICB9CiAgfQp9KTsK"),
    ]

    static func makeSources() -> [ThirdPartySource] {
        bundled.compactMap { item in
            guard let data = Data(base64Encoded: item.base64),
                  let script = String(data: data, encoding: .utf8) else { return nil }
            return ThirdPartySource(
                name: item.name,
                kind: "script",
                template: "",
                headers: ["quality": "320k"],
                script: script,
                enabled: true
            )
        }
    }
}
