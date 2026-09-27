import Foundation

/// Presentation metadata only; a symbol never determines a category's identity or purpose.
public struct CategorySymbol: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let theme: CategorySymbolTheme
    public let keywords: String
    public init(_ id: String, _ name: String, _ theme: CategorySymbolTheme, _ keywords: String = "") {
        self.id = id; self.name = name; self.theme = theme; self.keywords = keywords
    }
}

public enum CategorySymbolTheme: String, CaseIterable, Sendable {
    case general, food, transport, home, shopping, digital, health, learning, leisure, income
    public var name: String {
        switch self {
        case .general: "通用"
        case .food: "餐饮"
        case .transport: "交通"
        case .home: "家居与服务"
        case .shopping: "购物"
        case .digital: "数码与通信"
        case .health: "健康与保障"
        case .learning: "教育"
        case .leisure: "休闲运动"
        case .income: "收入与资金"
        }
    }
}

public enum CategorySymbolCatalog {
    public static let fallback = "tag"
    public static let all: [CategorySymbol] = [
        .init("tag", "标签", .general, "分类 通用 label"),
        .init("ellipsis.circle", "其他", .general, "更多 通用 other"),
        .init("star", "星星", .general, "收藏 常用 favorite"),
        .init("heart", "爱心", .general, "关爱 公益 捐赠 love"),
        .init("gift", "礼物", .general, "赠礼 收礼 人情 gift"),
        .init("envelope", "信封", .general, "红包 礼金 envelope"),
        .init("person", "人物", .general, "生活服务 照护 person"),
        .init("pawprint", "爪印", .general, "宠物 猫 狗 pet"),
        .init("fork.knife", "餐具", .food, "正餐 吃饭 餐饮 meal"),
        .init("takeoutbag.and.cup.and.straw", "外卖", .food, "打包 配送 takeout"),
        .init("cup.and.saucer", "咖啡杯", .food, "饮品 咖啡 茶 厨具 餐具 coffee tea"),
        .init("birthday.cake", "蛋糕", .food, "零食 甜点 生日 cake"),
        .init("carrot", "胡萝卜", .food, "食材 蔬菜 grocery"),
        .init("leaf", "叶子", .food, "水果 生鲜 fruit"),
        .init("bus", "公交车", .transport, "交通 公共汽车 bus"),
        .init("tram", "轨道交通", .transport, "地铁 电车 metro"),
        .init("car", "汽车", .transport, "打车 网约车 出租车 car taxi"),
        .init("train.side.front.car", "火车", .transport, "高铁 铁路 train"),
        .init("airplane", "飞机", .transport, "机票 航班 airplane"),
        .init("fuelpump", "加油站", .transport, "燃油 充电 fuel"),
        .init("parkingsign.circle", "停车", .transport, "车位 parking"),
        .init("road.lanes", "道路", .transport, "路桥费 高速 公路 road"),
        .init("bicycle", "自行车", .transport, "骑行 单车 bike"),
        .init("house", "房屋", .home, "居住 房租 租金 home"),
        .init("key", "钥匙", .home, "房租 租房 key"),
        .init("drop", "水滴", .home, "水电燃气 水费 drop"),
        .init("building.2", "楼房", .home, "物业 公寓 building"),
        .init("bed.double", "床", .home, "住宿 酒店 hotel"),
        .init("sofa", "沙发", .home, "家居 家具 sofa"),
        .init("hammer", "锤子", .home, "装修 维修 hammer"),
        .init("wrench.and.screwdriver", "维修工具", .home, "车辆养护 生活服务 扳手 螺丝刀 repair"),
        .init("wrench", "扳手", .home, "维修服务 修理 wrench"),
        .init("shippingbox", "包裹", .home, "快递 跑腿 邮寄 delivery"),
        .init("washer", "洗衣机", .home, "家政 洗护 清洁 laundry"),
        .init("scissors", "剪刀", .home, "美容 理发 scissors"),
        .init("bag", "购物袋", .shopping, "日常购物 shopping"),
        .init("basket", "篮子", .shopping, "日用品 超市 basket"),
        .init("tshirt", "衣服", .shopping, "服饰 鞋包 运动衣 clothing"),
        .init("sparkles", "闪光", .shopping, "美妆 护理 化妆 sparkle"),
        .init("refrigerator", "冰箱", .shopping, "家用电器 家电 refrigerator"),
        .init("laptopcomputer", "笔记本电脑", .digital, "电脑整机 laptop"),
        .init("desktopcomputer", "台式电脑", .digital, "电脑整机 显示器 desktop"),
        .init("cpu", "芯片", .digital, "电脑配件 处理器 cpu"),
        .init("iphone", "手机", .digital, "手机平板 电话 phone"),
        .init("camera", "相机", .digital, "摄影设备 镜头 camera"),
        .init("headphones", "耳机", .digital, "音频设备 音乐 audio"),
        .init("externaldrive", "硬盘", .digital, "网络 存储 NAS 硬盘 drive"),
        .init("applewatch", "手表", .digital, "智能 穿戴 手环 watch"),
        .init("cube", "立方体", .digital, "创作设备 3D 打印 cube"),
        .init("cable.connector", "连接线", .digital, "数码配件 数据线 充电器 cable"),
        .init("antenna.radiowaves.left.and.right", "天线", .digital, "通信 增值服务 antenna"),
        .init("iphone.radiowaves.left.and.right", "移动通信", .digital, "手机话费 套餐 mobile"),
        .init("wifi", "无线网络", .digital, "宽带 路由器 wifi"),
        .init("phone", "电话", .digital, "通话 通信 phone"),
        .init("app", "应用窗口", .digital, "数字服务 软件 AI app"),
        .init("cloud", "云朵", .digital, "云服务 存储 云盘 cloud"),
        .init("play.rectangle", "播放窗口", .digital, "影音会员 视频 电影 video"),
        .init("newspaper", "报纸", .digital, "内容资讯 新闻 newspaper"),
        .init("arrow.triangle.2.circlepath", "循环", .digital, "订阅 周期 更新 repeat"),
        .init("cross.case", "医疗箱", .health, "医疗健康 门诊 住院 medical"),
        .init("pills", "药片", .health, "药品 药店 pills"),
        .init("stethoscope", "听诊器", .health, "医疗器械 检查 体检 health"),
        .init("shield", "盾牌", .health, "保险 保障 shield"),
        .init("heart.circle", "健康保障", .health, "健康保险 赠与 补助 heart"),
        .init("car.circle", "车辆保障", .health, "车辆保险 车险 car"),
        .init("house.circle", "房屋保障", .health, "财产保险 家财险 house"),
        .init("book", "书本", .learning, "教育学习 阅读 book"),
        .init("books.vertical", "图书", .learning, "图书资料 小说 教材 电子书 books"),
        .init("person.crop.rectangle", "人物卡片", .learning, "课程培训 兼职劳务 course"),
        .init("checkmark.seal", "认证", .learning, "考试 证书 certification"),
        .init("doc.text", "文档", .learning, "报告 体检 借款服务费 document"),
        .init("figure.run", "跑步", .leisure, "休闲运动 运动健身 健身房 私教 run gym"),
        .init("figure.walk", "步行", .leisure, "散步 运动 walk"),
        .init("theatermasks", "戏剧面具", .leisure, "文娱活动 演出 theater"),
        .init("gamecontroller", "游戏手柄", .leisure, "游戏 娱乐 game"),
        .init("ticket", "门票", .leisure, "景点 游览 ticket"),
        .init("paintpalette", "调色盘", .leisure, "兴趣爱好 绘画 art"),
        .init("briefcase", "公文包", .income, "工作收入 劳务 work"),
        .init("banknote", "纸币", .income, "现金 工资 存款利息 money salary"),
        .init("star.circle", "奖励", .income, "奖金 bonus"),
        .init("storefront", "店铺", .income, "经营收入 经营所得 store"),
        .init("percent", "百分比", .income, "资金收益 利息 财务费用 interest"),
        .init("creditcard", "银行卡", .income, "账户 支付 手续费 card"),
        .init("plus.circle", "加号", .income, "其他收入 增加 income")
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    private static let defaults = Dictionary(uniqueKeysWithValues: SeedData.categories.map { ($0.id, $0.symbol) })

    public static func symbol(_ id: String) -> CategorySymbol? { byID[id] }
    public static func defaultSymbol(for categoryID: UUID) -> String { defaults[categoryID] ?? fallback }

    public static func search(_ query: String, theme: CategorySymbolTheme? = nil) -> [CategorySymbol] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return all.filter { item in
            guard theme == nil || item.theme == theme else { return false }
            let text = item.name + " " + item.keywords + " " + item.id + " " + item.theme.name
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN")) != nil }
        }
    }
}
