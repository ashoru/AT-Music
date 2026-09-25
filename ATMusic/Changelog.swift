import SwiftUI

// MARK: - 版本更新日志（设置页与首次更新弹窗使用）

struct VersionLog: Identifiable {
    let id: String
    let version: String
    let title: String
    let notices: [String]
    let features: [String]
    let fixes: [String]
    let imageURL: URL?
    let textColorHex: String?

    init(id: String, version: String, title: String, notices: [String] = [], features: [String], fixes: [String], imageURL: URL? = nil, textColorHex: String? = nil) {
        self.id = id
        self.version = version
        self.title = title
        self.notices = notices
        self.features = features
        self.fixes = fixes
        self.imageURL = imageURL
        self.textColorHex = textColorHex
    }
}

enum ChangelogStore {
    static let lastSeenKey = "atmusic.lastSeenVersion"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var lastSeenVersion: String {
        UserDefaults.standard.string(forKey: lastSeenKey) ?? ""
    }

    static func markSeen() {
        UserDefaults.standard.set(currentVersion, forKey: lastSeenKey)
        UserDefaults.standard.synchronize()
    }

    static var shouldShowWhatsNew: Bool {
        lastSeenVersion != currentVersion
    }

    static var latest: VersionLog? { logs.first }

    static let logs: [VersionLog] = [
        VersionLog(
            id: "1.8.6-music-library-redesign",
            version: "1.8.6",
            title: "音乐库重构与文件浏览",
            features: [
                "底部“歌单”升级为“音乐库”，首屏只保留最近播放、本地音乐、NAS 文件和我的歌单预览",
                "新增本地音乐浏览：文件、专辑、歌手、本地歌单使用统一的二级浏览结构；文件页显示真实原始文件名",
                "NAS 文件提升为音乐库一级入口，支持文件夹递归、当前目录搜索、播放全部和随机播放",
                "全部歌单改为二级页，支持本地、网易云、QQ、酷狗、NAS 来源筛选；高级同步与管理能力继续保留"
            ],
            fixes: [
                "歌单详情页移除首屏常驻搜索、排序、简介和热度，搜索按需展开，排序与歌单信息统一移入右上角菜单",
                "歌单封面缩至 80pt，简介与热度改到信息页；播放全部与随机播放保留在最靠前操作区",
                "多平台歌单列表改为并发刷新并复用持久化缓存，避免单个平台慢时拖住其它来源",
                "修复最近播放从音乐库进入时可能出现嵌套 NavigationStack 的问题"
            ]
        ),
        VersionLog(
            id: "1.8.5-interaction-theme-consistency",
            version: "1.8.5",
            title: "交互反馈与四主题一致性",
            features: [
                "选中态升级为真正的四主题适配：默认液态、磨砂玻璃、紧凑淡雅、Apple 简洁分别使用匹配的材质、描边与前景色",
                "全局播放类按钮统一加入可见按压反馈与触感反馈，歌单播放全部/随机播放不再无感",
                "播放队列编辑模式使用稳定行身份并冻结编辑态动态效果，避免歌名持续抖动"
            ],
            fixes: [
                "修复播放队列进入编辑后 PlayerManager 高频刷新触发行重布局的问题",
                "修复 Liquid Glass 以外三套 UI 在 iOS 26/27 下缺少按钮按压视觉反馈的问题",
                "统一主页、搜索、音乐库、播放模式、设置和播放器布局的主题感知选中态前景色"
            ]
        ),
        VersionLog(
            id: "1.8.4-home-unification",
            version: "1.8.4",
            title: "主页统一与可读性修复",
            features: [
                "网易、QQ、酷狗统一使用同一套主页推荐卡、平台切换和选中态组件；网易不再保留独立特殊首页风格",
                "网易主页第一排固定提供每日推荐与红心雷达，标题和可见平台胶囊都可直接切换主页",
                "主页缓存升级为内存加磁盘快照，冷启动先显示上次内容，再后台静默刷新"
            ],
            fixes: [
                "单平台主页改为每日推荐、排行榜、歌单并发渐进加载，任一板块先返回即可先展示",
                "聚合主页继续按平台并发渐进加载，并避免切换平台时短暂残留上一平台内容",
                "统一主页、搜索、音乐库、播放队列、设置和播放器布局选择器的选中态，修复浅色背景白字导致的低对比度",
                "移除系统 borderedProminent 残留按钮，播放全部、聚合、保存等高亮按钮统一使用 AT Music 主题表面"
            ]
        ),
        VersionLog(
            id: "1.8.3-home-cleanup-performance",
            version: "1.8.3",
            title: "首页体验与平台精简",
            features: [
                "移除汽水音乐平台及其搜索、播放、歌词、歌单、收藏、下载、配置和登录能力",
                "网易云主页第一排恢复红心雷达，并与每日推荐并排展示",
                "主页左上角平台切换改为直接点击标题和下拉图标，不再要求长按"
            ],
            fixes: [
                "首次进入聚合主页时任一平台返回有效内容即可立即结束空白加载，其余平台结果随后无动画补齐",
                "清理汽水音乐在统一平台模型、音乐库、聚合搜索和播放器中的残留分支"
            ]
        ),
        VersionLog(
            id: "1.8.2-playback-prefetch-cache",
            version: "1.8.2",
            title: "连续播放与音乐缓存优化",
            features: [
                "当前歌曲稳定播放后自动提前缓存真实播放队列中的下一首，切歌时优先使用本地缓存",
                "设置中的播放设置新增音乐缓存空间，可选择 500 MB、1 GB、2 GB、5 GB、10 GB 或 20 GB，上限默认 2 GB",
                "设置页实时显示缓存占用与缓存歌曲数量，并支持一键清除音乐缓存"
            ],
            fixes: [
                "缓存按最近使用时间自动淘汰，并在设备可用空间低于 2 GB 时停止继续占用磁盘",
                "队列插队、重新排序、随机播放和单曲循环时会重新计算下一首缓存目标",
                "缓存文件损坏、无法开始或播放中断时自动删除缓存并回退原网络播放链路"
            ]
        ),
        VersionLog(
            id: "1.8.1-aggregate-search-request-dedupe",
            version: "1.8.1-r4",
            title: "聚合搜索重复请求修复",
            features: [],
            fixes: [
                "修复平台显示监听器在每次视图重建时回放当前值，造成搜索完成后立即再次搜索的循环",
                "聚合首页、音乐库和本地音乐同步改为只响应真实的平台设置变化，避免重复加载",
                "修复 NAS 曲库索引分页通知导致同一关键词在一秒内重复发起多次聚合搜索、结果持续闪烁的问题",
                "同一关键词、平台范围和分类的在途请求现在自动合并，不再由新旧结果互相覆盖",
                "NAS 未参与当前搜索时不再因后台索引刷新聚合结果",
                "歌手与专辑增加跨平台稳定标识，避免不同平台内部 ID 重复时卡片跳动或缺失"
            ]
        ),
        VersionLog(
            id: "1.8.1-aggregate-search-stability",
            version: "1.8.1-r3",
            title: "聚合搜索稳定性优化",
            features: [],
            fixes: [
                "聚合搜索的综合结果改为歌曲、歌手、专辑和歌单一次性原子提交，避免多平台回包时整页反复闪烁",
                "分类页改为进入时从完整快照即时取值，保留全部结果和相关性排序"
            ]
        ),
        VersionLog(
            id: "1.8.1-platform-filter-nav",
            version: "1.8.1-r2",
            title: "导航栏与聚合平台显示优化",
            features: [
                "底部导航栏收起后，点击左侧圆形导航图标可重新展开",
                "我的页面新增 AT Music 更新日志入口",
                "平台显示设置现在同步作用于聚合搜索和聚合首页",
                "取消显示的平台不会继续出现在已打开的聚合搜索结果中"
            ],
            fixes: [
                "移除外部更新地址、检查更新、交流群和资源赞助入口"
            ]
        ),
        VersionLog(
            id: "1.8.1",
            version: "1.8.1",
            title: "1.8.1 原版界面基线 + NAS",
            features: [
                "以真实 AT Music 1.8.1 build 3 为界面基线，继续保留聚合首页入口",
                "首页、精选、搜索、音乐库和我的页面沿用 1.8.1 的标题、间距、搜索框和卡片层级",
                "聚合搜索结果按歌曲、歌手、专辑、歌单分区展示，并保留每条结果的来源标识",
                "播放器设置页收敛为 1.8.1 的半屏圆角样式，布局编辑和播放器风格集中管理",
                "播放器布局编辑器按 1.8.1 重排为独立黑色编辑页，支持当前设备比例的带外框歌曲预览",
                "封面播放页的歌名与歌手改为居中展示；红心与更多菜单仅保留在歌词页右上角",
                "布局预览直接复用真实播放页，显示当前歌曲封面、来源、VIP、歌词状态、进度和底部控制按钮",
                "主题模式改为浅色、深色、跟随系统三项独立选择卡，避免旧版 segmented picker 与原版不一致",
                "主题设置补齐关闭液态效果选项，可关闭液态玻璃与流动背景，同时保留当前布局和功能",
                "统一设置、底栏、搜索、首页公告、个人页和布局编辑器的通用强调色，切换主题后即时联动",
                "设置中补齐运行环境信息与动态效果、外观切换、自愿赞助的隐藏选项",
                "保留群晖 NAS 的搜索、歌手/专辑/歌单详情与播放能力，后续平台接入沿用同一数据层",
                "歌曲信息改为可上拉的半屏信息卡：文件信息、封面和每项标签分开显示，点击铅笔才进入单字段全屏编辑",
                "封面更换改为独立搜索网格，可检索网易云、QQ、酷狗候选封面，或从本机相册选择；点选后才加入待保存改动",
                "聚合歌单改为平台标题右侧箭头：点按直接在首页展开或收起该平台全部歌单，展开后每行两张卡片",
                "歌单、专辑、歌手热门歌曲、搜索、本地音乐、NAS 文件夹和播放队列统一为 1.8.1 连续紧凑歌曲行：46pt 封面、64pt 行高与细分隔线，不再逐首使用玻璃卡片"
            ],
            fixes: [
                "全局四套 UI 样式（默认液态、磨砂玻璃、紧凑淡雅、Apple 简洁）深度统一对齐：主页、精选、歌单、我的、播放页按钮与全部弹窗全量联动",
                "补全 iOS 16+ 全版本通用原生液态玻璃渲染：具备清透基底、液态渐变光晕与晶莹边缘反光，解决真机无液态质感问题",
                "修复设置中「关闭液态效果」开关无视觉效果的问题：开启时实时切换为无液态玻璃的简洁风格，关闭时恢复原生液态玻璃与流动背景效果",
                "修复首页首次进入时错误显示平台切换提示的问题",
                "修复首页默认音源枚举推断冲突导致的编译失败",
                "修复聚合搜索结果统计文本显示为代码表达式的问题",
                "移除播放器设置首页重复展开的旧播放、歌词和效果分组，避免与 1.8.1 新入口重复",
                "NAS 标签写回改为字段差异补丁：只写用户实际编辑的标签，未编辑的专辑歌手、年份、流派和备注不会被清空",
                "修复 NAS 歌曲信息与封面保存长期等待后失败：改用 Audio Station 官方编辑器的数据格式，保存前读取原标签并合并改动",
                "在线封面改为由 NAS 直接获取；本机选图会先压缩后上传，并显示文件权限、只读磁盘或文件已移动等具体失败原因",
                "修复 NAS 标签保存表面成功但未写入：写入请求改为 Audio Station 的路径数组协议，并在提示成功前重新读取文件标签核验",
                "修复 NAS 标签已更新但列表仍显示旧索引字段：歌曲列表优先读取 Audio Station 返回的文件标签",
                "修复 NAS 标签保存无实际变化：按 Audio Station 网页端协议携带原始 audioInfos 标签对象，并在写入后回读核验",
                "修复 NAS 封面保存表面成功但仍显示旧封面：保存后绕过缓存重新读取封面摘要确认结果",
                "修复歌词搜索只载入当前播放页：选择歌词后同时写入 Audio Station 歌词接口，并回读确认已保存",
                "歌曲列表中的来源平台标识统一移动至时间左侧，时间固定在最右侧；VIP 标识紧跟歌曲标题"
            ]
        ),
        VersionLog(
            id: "1.8.0",
            version: "1.8.0",
            title: "1.8 页面逐项对照（第一轮）",
            features: [
                "按手机上独立安装的 1.8 逐页对照，先校正首页首屏、我的页面和设置入口",
                "默认显示 1.8 风格单平台首页，长按首页标题仍可切换聚合首页和 NAS",
                "我的页面加入本机听歌时长与播放次数，设置恢复紧凑分组和半屏展开",
                "保留现有群晖 NAS 登录、搜索和播放逻辑",
                "开发版桌面名称改为 AT Music，避免与原版 1.8 混淆"
            ],
            fixes: [
                "更正上次将切换主题误记为完成 1.8 复刻的更新说明"
            ]
        ),
        VersionLog(
            id: "1.6.5.39",
            version: "1.6.5.39",
            title: "聚合搜索结果页参考 1.8",
            features: [
                "聚合搜索默认进入综合结果页，歌曲、歌手、专辑和歌单按分区连续展示",
                "新增综合结果顶部的平台范围摘要，清晰显示本次参与搜索的音源",
                "每条聚合结果保留来源标识，点击歌手、专辑和歌单可直接进入对应详情页",
                "保留歌曲、歌手、专辑和歌单分类筛选，方便快速切换单一类型"
            ],
            fixes: [
                "修复聚合搜索结果只能按单一类型查看、内容分散的问题"
            ]
        ),
        VersionLog(
            id: "1.6.5.38",
            version: "1.6.5.38",
            title: "参考版设置界面统一",
            features: [
                "设置页改为参考 IPA 的大尺寸液态弹层，支持 iOS 16+ 拖拽指示条和圆角呈现",
                "新增账号与登录统一入口，网易云音乐、QQ 音乐、酷狗音乐和群晖 NAS 使用同一套账号面板",
                "设置页按账号、外观、播放体验、音频工具、数据与支持重新分组",
                "播放器设置与系统设置共用紧凑玻璃分组样式，后续新增平台设置可直接复用"
            ],
            fixes: [
                "修复设置页和播放器设置页表面样式不一致的问题"
            ]
        ),
        VersionLog(
            id: "1.6.5.37",
            version: "1.6.5.37",
            title: "播放器布局设备比例预览",
            features: [
                "布局预览读取当前设备屏幕尺寸和宽高比",
                "预览改为显示完整播放器页面，而不是固定比例的小卡片",
                "预览同步当前正在播放歌曲和当前选择的播放器主题"
            ],
            fixes: [
                "修复布局预览与真实手机页面比例不一致的问题"
            ]
        ),
        VersionLog(
            id: "1.6.5.36",
            version: "1.6.5.36",
            title: "播放器主题布局统一",
            features: [
                "布局预览改为使用当前正在播放歌曲的封面、歌名、歌手和来源",
                "经典封面、Apple Music、唱片模式分别接入对应布局编辑项",
                "三种主题统一支持组件位置、大小、旋转和透明度调整",
                "合并播放器设置入口，移除重复的布局和 Apple Music 设置卡片"
            ],
            fixes: [
                "旧版经典封面和唱片布局数据继续兼容并自动保存"
            ]
        ),
        VersionLog(
            id: "1.6.5.35",
            version: "1.6.5.35",
            title: "播放器设置与布局编辑器",
            features: [
                "播放器设置首页增加自定义布局入口和封面风格选择",
                "新增手机端布局预览，可调整组件 X / Y / 大小 / 旋转 / 透明度",
                "布局修改自动保存到本机，重启应用后保持",
                "新增 Apple Music 外观、音量条、歌词预览和颜色设置"
            ],
            fixes: [
                "兼容旧版本播放器布局数据，升级后不会丢失原有设置"
            ]
        ),
        VersionLog(
            id: "1.6.5.34",
            version: "1.6.5.34",
            title: "iOS 27 播放器布局",
            features: [
                "播放页底部操作栏调整为歌词、评论、播放队列三项",
                "底部评论入口采用 iOS 27 风格的简洁图标排布"
            ],
            fixes: []
        ),
        VersionLog(
            id: "1.6.5.33",
            version: "1.6.5.33",
            title: "播放操作与歌曲信息编辑优化",
            features: [
                "播放界面底部固定显示收藏、加入歌单、歌词、评论、播放列表和更多操作",
                "歌词页新增在线歌词搜索结果弹框，点击结果即可载入当前播放页",
                "歌曲信息页新增在线封面与歌曲信息候选弹框",
                "更多操作新增查看专辑入口，支持跳转歌曲所在专辑详情"
            ],
            fixes: [
                "修复没有歌词时收藏和加入歌单入口不可用的问题"
            ]
        ),
        VersionLog(
            id: "1.6.5.30",
            version: "1.6.5.30",
            title: "本地音乐导入与播放",
            features: [
                "新增系统文件多选导入，音频复制到应用受管目录后可独立播放",
                "支持按文件指纹去重，并读取标题、歌手、专辑、封面和时长信息",
                "支持导入音频同名 LRC 歌词，并可将本地歌曲加入应用歌单和播放队列",
                "新增本地音乐管理页，可搜索、编辑应用内标签和封面，并删除应用内音频副本",
                "本地歌曲支持离线播放，不依赖原始文件位置；删除应用内副本不会影响源文件"
            ],
            fixes: [
                "阶段四聚合搜索与平台来源标识整理为可持续扩展的统一来源模型"
            ]
        ),
        VersionLog(
            id: "1.6.5.28",
            version: "1.6.5.28",
            title: "NAS 音乐信息编辑",
            features: [
                "播放 NAS 歌曲时可在更多操作中手动编辑标题、歌手、专辑、流派、年份和备注",
                "缺少标签或歌词时，可并发匹配网易云音乐、QQ音乐和酷狗音乐候选",
                "支持预览确认后将在线封面、歌曲标签和同步歌词写回 NAS 原文件"
            ],
            fixes: [
                "已有 NAS 信息默认保留并优先手动编辑，不会在打开编辑页时自动覆盖",
                "自动补缺时保留 NAS 现有封面，只有手动选择在线候选并确认后才会替换"
            ]
        ),
        VersionLog(
            id: "1.6.5.27",
            version: "1.6.5.27",
            title: "聚合排行榜扩展",
            features: [
                "聚合首页按平台展示全部可用排行榜",
                "每个平台的排行榜支持横向滑动浏览，不再只显示前三个"
            ],
            fixes: [
                "修复聚合首页排行榜被固定截断为三个的问题"
            ]
        ),
        VersionLog(
            id: "1.6.5.26",
            version: "1.6.5.26",
            title: "搜索歌单详情修复",
            features: [
                "聚合搜索、单平台搜索和 NAS 搜索的歌单统一支持点击进入详情页",
                "歌单详情页保留来源平台、封面、歌曲列表和播放能力"
            ],
            fixes: [
                "修复搜索页歌单点击无反应的问题",
                "修复搜索页缺少导航容器导致 NavigationLink 无法打开的问题"
            ]
        ),
        VersionLog(
            id: "1.6.5.25",
            version: "1.6.5.25",
            title: "精选歌单与聚合搜索扩展",
            features: [
                "精选页接入完整歌单分类，支持语种、风格、场景、情绪、主题等全部分类",
                "精选歌单和歌单搜索改为分页加载，滑动到底部会继续获取，不再限制固定显示数量",
                "精选页搜索改为调用网易云歌单搜索接口，支持搜索全部结果而不是只筛选首屏内容",
                "聚合搜索接入网易云、QQ音乐、酷狗音乐和群晖 NAS 歌单结果",
                "聚合歌单按名称匹配度、平台热度、歌曲数量和平台排名排序",
                "搜索页和歌手详情页支持多选平台筛选"
            ],
            fixes: [
                "修复精选页歌单分类长期只有少数入口的问题",
                "修复聚合搜索歌单无结果的问题",
                "修复部分平台单页数量较少时被误判为加载结束的问题"
            ]
        ),
        VersionLog(
            id: "1.5.8",
            version: "1.5.8",
            title: "歌单同步、主页与播放器全面优化",
            features: [
                "新增网易云音乐、QQ音乐、酷狗音乐歌单一键同步到本地",
                "本地歌单支持编辑和搜索，批量选择歌曲后可添加到其他本地歌单",
                "新增 QQ 音乐热门歌单展示",
                "主页问候语支持自定义文字、颜色、大小、发光、专属字体、底部横线和上下渐变，并可逐行选择渐变颜色",
                "播放器支持左右滑动切换歌曲，新增顶部三平台排序、隐藏主页刷新/用户名/排序按钮",
                "播放器按钮图标样式新增，播放器设置界面重新整理分组和控件排版",
                "主页、音乐库、我的、设置页增加 iPad 最大宽度适配",
                "播放列表、最近播放和日志界面背景同步主页壁纸"
            ],
            fixes: [
                "修复 QQ 音乐喜欢列表不显示的问题",
                "修复最近播放、日志、本地歌单和播放列表不同步主页壁纸的问题",
                "修复设置页掉帧问题；如果本次仍然掉帧，建议更换设备",
                "修复 iOS 15 编译兼容问题"
            ]
        ),
        VersionLog(
            id: "1.5.6",
            version: "1.5.6",
            title: "播放器体验优化",
            features: [
                "封面页歌名、歌手和预览歌词支持渐变、高光及高光强度调节",
                "播放页背景浮尘新增开关，默认关闭；动态浮尘支持密度和大小调节",
                "全局上传壁纸自动同步到播放器封面页背景",
                "播放页支持从顶部下划关闭，并加入缩放、淡出动画"
            ],
            fixes: [
                "修复酷狗排行榜歌曲封面缺失或未归一化的问题",
                "提高内置音源搜索上限",
                "播放器设置打开后不再默认展开播放和歌词显示分组"
            ]
        ),
        VersionLog(
            id: "1.5.5",
            version: "1.5.5",
            title: "播放流畅度与发热优化",
            notices: [
                "从 1.5.4 版本开始，播放器设置已从右上角删除，改为点击中间歌曲正在播放的标题打开。"
            ],
            features: [
                "优化播放中全局刷新策略，移除高刷保持器的常驻空转刷新，降低设置页、我的页面和播放器页面的发热与掉帧",
                "本地壁纸、歌词背景、设置页缩略图改为复用解码缓存，减少滚动和切换设置时的重复图片解码",
                "锁屏/系统正在播放封面增加缓存，避免播放状态变化时反复下载和刷新同一张封面",
                "聆澜内置音源支持多密钥池，当前密钥未命中时自动切换下一个，并记住最近可用密钥",
                "播放器设置新增封面页歌名、歌手、预览歌词与未播放歌词颜色调节"
            ],
            fixes: [
                "修复播放中进度更新过于频繁导致非播放器页面也跟随重绘的问题",
                "修复重新上传歌词背景或恢复壁纸后，部分位置可能继续显示旧图片缓存的问题",
                "修复酷狗排行榜详情歌曲封面链接未归一化，并在官网榜单缺封面时自动用移动端榜单数据补齐封面",
                "优化巨魔安装场景下播放中切换页面的刷新与解码负担"
            ]
        ),
    ]
}

// MARK: - 更新说明弹窗

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: ThemeStore.shared.backgroundSyncAll ? ThemeStore.shared.customBackground : nil)
                ScrollView {
                    if let log = ChangelogStore.latest {
                        VersionLogCard(log: log)
                            .padding(16)
                    }
                }
                .atmusicScrollIndicatorsHidden()
            }
            .navigationTitle("更新说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始使用") {
                        ChangelogStore.markSeen()
                        dismiss()
                    }
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.medium, .large]))
        .onDisappear {
            ChangelogStore.markSeen()
        }
    }
}

struct ChangelogListView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: ThemeStore.shared.backgroundSyncAll ? ThemeStore.shared.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(ChangelogStore.logs) { log in
                            VersionLogCard(log: log)
                        }
                    }
                    .padding(16)
                }
                .atmusicScrollIndicatorsHidden()
            }
            .navigationTitle("更新日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.medium, .large]))
    }
}

private struct VersionLogCard: View {
    let log: VersionLog

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("v\(log.version)")
                    .font(ATMusicFont.appFont(16, .bold))
                    .foregroundStyle(Color.atmusicAmber)
                Text(log.title)
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(textColor)
            }
            if let imageURL = log.imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else if phase.error != nil {
                        EmptyView()
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if !log.notices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(log.notices, id: \.self) { notice in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.top, 1)
                            Text(notice)
                                .font(ATMusicFont.appFont(13, .semibold))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color.orange, Color.red.opacity(0.88)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            if !log.features.isEmpty {
                logSection(title: "新增功能", icon: "plus.circle.fill", items: log.features)
            }
            if !log.fixes.isEmpty {
                Divider().overlay(Color.atmusicComment.opacity(0.15))
                logSection(title: "问题修复", icon: "checkmark.circle.fill", items: log.fixes)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .atmusicCardShadow(radius: 9, y: 3)
    }

    private func logSection(title: String, icon: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(ATMusicFont.appFont(14, .bold))
                .foregroundStyle(Color.atmusicAmber)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(.top, 2)
                    Text(LocalizedStringKey(item))
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var textColor: Color {
        if let raw = log.textColorHex, let color = Color(hex: raw) { return color }
        return Color.atmusicLabel
    }
}
