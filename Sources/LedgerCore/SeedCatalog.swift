import Foundation

/// IOS_CATEGORIES.md sections 2–4. Explicit identifiers survive renaming and reordering.
/// Optional expansion templates are deliberately not part of the ordinary initial catalog.
enum SeedCatalog {
    private struct Item {
        let id: UUID
        let name: String
        let symbol: String
        init(_ number: UInt64, _ name: String, _ symbol: String) {
            self.id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", number))!
            self.name = name
            self.symbol = symbol
        }
    }

    private static func group(_ parent: Item, direction: EntryKind, children: [Item]) -> [Category] {
        [Category(id: parent.id, name: parent.name, direction: direction, symbol: parent.symbol)]
            + children.map { Category(id: $0.id, name: $0.name, parentID: parent.id, direction: direction, symbol: $0.symbol) }
    }

    static let categories: [Category] = [
        group(Item(0x10, "餐饮", "fork.knife"), direction: .expense, children: [
            Item(0x11, "正餐", "fork.knife"),
            Item(0x1001, "外卖", "takeoutbag.and.cup.and.straw"),
            Item(0x1002, "饮品", "cup.and.saucer"),
            Item(0x1003, "零食", "birthday.cake"),
            Item(0x1004, "食材", "carrot"),
            Item(0x1005, "水果", "leaf")
        ]),
        group(Item(0x20, "交通", "bus"), direction: .expense, children: [
            Item(0x1101, "公交地铁", "tram"),
            Item(0x21, "打车", "car"),
            Item(0x1102, "火车", "train.side.front.car"),
            Item(0x1103, "机票", "airplane"),
            Item(0x1104, "燃油充电", "fuelpump"),
            Item(0x1105, "停车", "parkingsign.circle"),
            Item(0x1106, "路桥费", "road.lanes"),
            Item(0x1107, "车辆养护", "car.fill")
        ]),
        group(Item(0x1200, "居住", "house"), direction: .expense, children: [
            Item(0x1201, "房租", "key"),
            Item(0x1202, "水电燃气", "drop"),
            Item(0x1203, "物业", "building.2"),
            Item(0x1204, "住宿", "bed.double"),
            Item(0x1205, "家居家具", "sofa"),
            Item(0x1206, "装修维修", "hammer")
        ]),
        group(Item(0x1300, "日常购物", "bag"), direction: .expense, children: [
            Item(0x1301, "日用品", "basket"),
            Item(0x1302, "服饰鞋包", "tshirt"),
            Item(0x1303, "美妆护理", "sparkles"),
            Item(0x1304, "厨具餐具", "cup.and.saucer"),
            Item(0x1305, "家用电器", "refrigerator"),
            Item(0x1306, "其他购物", "bag")
        ]),
        group(Item(0x1400, "数码设备", "laptopcomputer"), direction: .expense, children: [
            Item(0x1401, "电脑整机", "laptopcomputer"),
            Item(0x1402, "电脑配件", "cpu"),
            Item(0x1403, "手机平板", "iphone"),
            Item(0x1404, "摄影设备", "camera"),
            Item(0x1405, "音频设备", "headphones"),
            Item(0x1406, "网络与存储", "externaldrive"),
            Item(0x1407, "智能与穿戴", "applewatch"),
            Item(0x1408, "创作设备", "cube"),
            Item(0x1409, "数码配件", "cable.connector")
        ]),
        group(Item(0x1500, "通信", "antenna.radiowaves.left.and.right"), direction: .expense, children: [
            Item(0x1501, "手机话费", "iphone.radiowaves.left.and.right"),
            Item(0x1502, "宽带", "wifi"),
            Item(0x1503, "通信增值服务", "antenna.radiowaves.left.and.right")
        ]),
        group(Item(0x1600, "医疗健康", "cross.case"), direction: .expense, children: [
            Item(0x1601, "门诊住院", "cross.case"),
            Item(0x1602, "药品", "pills"),
            Item(0x1603, "检查体检", "doc.text"),
            Item(0x1604, "医疗器械", "stethoscope")
        ]),
        group(Item(0x1700, "教育学习", "book"), direction: .expense, children: [
            Item(0x1701, "课程培训", "person.crop.rectangle"),
            Item(0x1702, "图书资料", "books.vertical"),
            Item(0x1703, "考试认证", "checkmark.seal")
        ]),
        group(Item(0x1800, "休闲运动", "figure.run"), direction: .expense, children: [
            Item(0x1801, "文娱活动", "theatermasks"),
            Item(0x1802, "游戏", "gamecontroller"),
            Item(0x1803, "运动健身", "figure.run"),
            Item(0x1804, "景点门票", "ticket"),
            Item(0x1805, "兴趣爱好", "paintpalette")
        ]),
        group(Item(0x1900, "人情往来", "gift"), direction: .expense, children: [
            Item(0x1901, "礼物", "gift"),
            Item(0x1902, "礼金红包", "envelope"),
            Item(0x1903, "公益捐赠", "heart")
        ]),
        group(Item(0x1a00, "订阅与数字服务", "arrow.triangle.2.circlepath"), direction: .expense, children: [
            Item(0x1a01, "软件与 AI", "app"),
            Item(0x1a02, "云服务与存储", "cloud"),
            Item(0x1a03, "影音会员", "play.rectangle"),
            Item(0x1a04, "内容资讯", "newspaper"),
            Item(0x1a05, "其他数字服务", "arrow.triangle.2.circlepath")
        ]),
        group(Item(0x1b00, "生活服务", "wrench.and.screwdriver"), direction: .expense, children: [
            Item(0x1b01, "快递跑腿", "shippingbox"),
            Item(0x1b02, "家政洗护", "washer"),
            Item(0x1b03, "美容理发", "scissors"),
            Item(0x1b04, "维修服务", "wrench"),
            Item(0x1b05, "其他生活服务", "person")
        ]),
        group(Item(0x1c00, "保险", "shield"), direction: .expense, children: [
            Item(0x1c01, "健康保障", "heart.circle"),
            Item(0x1c02, "车辆保险", "car.circle"),
            Item(0x1c03, "财产与其他保险", "house.circle")
        ]),
        group(Item(0x1d00, "财务费用", "percent"), direction: .expense, children: [
            Item(0x1d01, "借款利息", "percent"),
            Item(0x1d02, "账户与支付手续费", "creditcard"),
            Item(0x1d03, "借款服务费", "doc.text")
        ]),
        group(Item(0x30, "其他支出", "ellipsis.circle"), direction: .expense, children: [
            Item(0x31, "其他明确支出", "ellipsis.circle")
        ]),
        group(Item(0x40, "工作收入", "briefcase"), direction: .income, children: [
            Item(0x41, "工资", "banknote"),
            Item(0x2001, "奖金", "star.circle"),
            Item(0x2002, "兼职劳务", "person.crop.rectangle")
        ]),
        group(Item(0x2100, "经营收入", "storefront"), direction: .income, children: [
            Item(0x2101, "经营所得", "storefront"),
            Item(0x2102, "租金", "house")
        ]),
        group(Item(0x2200, "资金收益", "percent"), direction: .income, children: [
            Item(0x2201, "存款利息", "banknote"),
            Item(0x2202, "借出利息", "percent")
        ]),
        group(Item(0x2300, "赠与补助", "gift"), direction: .income, children: [
            Item(0x2301, "收礼", "gift"),
            Item(0x2302, "补助", "heart.circle")
        ]),
        group(Item(0x2400, "其他收入", "plus.circle"), direction: .income, children: [
            Item(0x2401, "其他明确收入", "plus.circle")
        ])
    ].flatMap { $0 }
}
