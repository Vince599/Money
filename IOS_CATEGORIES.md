# Ledger for iPhone · 两级分类与图标颜色附录

> 对应 [主设计文档](IOS_DESIGN.md) 的分类、账户、往来款、预算与导入规则；版本 1.3，2026-09-26。  
> 这是可编辑的建议种子目录。用户已确认两级、自定义图标／颜色／排序／停用、旅行按用途分类、数码细化；没有逐一确认下列每个名称。  
> 图标列定义图形语义；实施时从目标 SDK 的 SF Symbols 中选择并校验实际标识，不将文档中的图形描述直接当 API 名。

## 1. 分类原则

1. 一级组织常用生活用途；每笔消费落在二级。默认快速入口可只展示常用类别，其余可搜索，不必把整个目录铺满一屏。
2. 主体、账户、项目、标签各司其职。MPC／LZY 是主体；微信／京东钱包是账户；“旅行杭州”是项目；亲属卡是来源支付关系。
3. 同一笔消费选一个分类和一个主体。贷款／投资的内部费用组件由业务模型拆解，不要求用户普通消费拆单。
4. 周期不决定用途：房租归居住，话费归通信，健身年卡归休闲运动；这些均可关联订阅实体。
5. “其他明确支出”只用于已理解且目录不合适的消费；未知用途保留导入“待分类”状态，不能自动塞进其他后称已完成。
6. 分类色只用于图标及其小面积浅底，卡片、整行和标题保持统一中性样式；不使用分类色铺满卡片或渐变。金额仍使用独立收入／支出色，普通标题使用近黑／近白主文字色。深色主题使用适合对比的同色系，不以低对比纯色文字承载金额。
7. 二级继承一级基色，可自定义覆盖。色板通过图标、名称和位置共同识别，不要求 15 种颜色单独承担辨识。
8. 稳定 ID 与显示名称分离。改名、切换语言不影响引用；合并／移动类别须预览预算、历史报表与规则的变化。

### 1.1 事件性质与分类边界

分类描述用途，不能代替报销、借出、借入、退款等事件性质。以下业务规则已确认；目录中的具体分类名称仍为可编辑的建议种子。

| 场景 | 分类与统计规则 | 消费预算 |
|---|---|---|
| 储值充值 | 转账到储值账户，增加其余额；不记消费 | 不占用 |
| 储值实际使用 | 按实际用途选择支出二级分类，并减少储值余额 | 按消费日期及预算范围占用 |
| 报销垫付、报销回款 | 独立管理待报销与已收回金额，不按普通消费或收入分类 | 待报销不占用，报销回款不释放预算 |
| 报销转个人承担 | 按实际用途选择消费分类，关联原垫付；确认承担月份计消费，不再扣一次现金 | 在确认承担月份按预算范围占用 |
| 借出本金及本金收回、借入本金及本金归还 | 使用对应往来款事件，不记普通收入或支出；利息与本金分开 | 本金不占用 |
| 借出利息、借入利息 | 收取利息归资金收益／借出利息，支付利息归财务费用／借款利息 | 支付利息按预算范围占用 |
| 借出损失 | 由损失事件单列，不归普通消费分类 | 不占日常消费预算 |
| 借出转赠与 | 用户确认后转为赠与事件，按适用赠与类别统计，不再扣一次现金 | 按赠与类别及预算范围占用 |
| 借入减免 | 由减免事件单列非现金收益，不归普通收入类别 | 不占用 |
| 已关联购买的退款、出售回收 | 支出回收事件，不归普通收入；保留原始消费金额 | 不新增占用，也不释放原预算 |

所有储值账户均跟踪余额；是否计入总资产是独立设置，话费账户默认不计入。不计入总资产不改变充值转账、实际使用才计消费的规则。固定服务周期订阅按其付款与服务周期管理，不因周期性付款自动变成储值账户。

原购买发生在开始记账之前的二手出售，不强制补录或关联购买；用户可手动归为普通收入并选择收入分类。系统不自动创建原购买、物品或支出回收事件，也不将所有二手出售自动归为收入。

有关联退款或回收的购买，流水列表保留原金额并显示“已回收”标记；详情备注区展示回收额与净花费。净花费只用于解释实际花费，不改写原发生月份的支出汇总或预算。

## 2. 支出一级目录

| 稳定 ID | 中文 | English | 一级图标语义 | 基色 |
|---|---|---|---|---|
| food | 餐饮 | Food & Dining | 餐叉与餐刀 | #D8872B |
| transport | 交通 | Transport | 公共交通车辆 | #397EC7 |
| housing | 居住 | Housing | 房屋 | #AE825D |
| shopping | 日常购物 | Shopping | 购物袋 | #C46F9A |
| digital | 数码设备 | Digital Devices | 电脑 | #7363C6 |
| communications | 通信 | Communications | 通信信号 | #3295A0 |
| health | 医疗健康 | Health & Medical | 医疗十字 | #C46975 |
| education | 教育学习 | Education | 打开的书 | #527FC0 |
| leisure | 休闲运动 | Leisure & Fitness | 运动人物 | #58986D |
| social | 人情往来 | Gifts & Social | 礼物 | #BE7C87 |
| subscriptions | 订阅与数字服务 | Digital Services | 循环箭头与服务 | #8670B5 |
| services | 生活服务 | Personal & Household Services | 工具 | #9C8A5C |
| insurance | 保险 | Insurance | 盾牌 | #4D9288 |
| financial | 财务费用 | Financial Costs | 百分号 | #9B7A5C |
| other | 其他支出 | Other Expenses | 省略号圆圈 | #7F8792 |

“订阅与数字服务”分类描述软件、内容等用途；“订阅”功能是周期管理，两者是独立概念。一次性软件许可也可归数字服务；房租不能因为按月扣款移入这里。

## 3. 支出二级目录

每行 ID 以一级 ID 为前缀；二级颜色默认继承一级。图标允许用户修改，以下为初始推荐。

| ID | 中文 | English | 二级图标语义 | 边界 |
|---|---|---|---|---|
| food.meals | 正餐 | Meals | 餐盘与餐具 | 堂食及普通餐食 |
| food.delivery | 外卖 | Food Delivery | 外带餐盒 | 有明确外卖场景；无法分清时正餐 |
| food.drinks | 饮品 | Drinks | 杯子与吸管 | 咖啡、茶饮等；杯子本身归厨具 |
| food.snacks | 零食 | Snacks | 食品包装袋 | 包装小吃 |
| food.groceries | 食材 | Groceries | 胡萝卜／食材篮 | 做饭原料 |
| food.fruit | 水果 | Fruit | 苹果 | 可整合进食材，由用户决定 |
| transport.transit | 公交地铁 | Public Transit | 地铁车厢 | 公交、轨道交通 |
| transport.taxi | 打车 | Taxi & Ride-hailing | 出租车 | 网约车、出租车 |
| transport.train | 火车 | Train | 火车 | 高铁、动车、普铁 |
| transport.flight | 机票 | Flights | 飞机 | 出行目的用项目表达 |
| transport.fuel | 燃油充电 | Fuel & Charging | 加油泵／充电 | 交通能源 |
| transport.parking | 停车 | Parking | 停车标志 | 临停、停车月费 |
| transport.tolls | 路桥费 | Tolls | 公路与收费标志 | 过路过桥 |
| transport.maintenance | 车辆养护 | Vehicle Maintenance | 汽车与扳手 | 保养、修车；保险另归保险 |
| housing.rent | 房租 | Rent | 房屋与钥匙 | 租住费用；押金不是房租消费 |
| housing.utilities | 水电燃气 | Utilities | 水滴与闪电 | 居住能源 |
| housing.property | 物业 | Property Management | 楼宇 | 物业管理缴费 |
| housing.accommodation | 住宿 | Accommodation | 床 | 酒店、民宿；旅行用项目 |
| housing.furnishings | 家居家具 | Furniture & Furnishings | 沙发 | 家具、家居布置 |
| housing.maintenance | 装修维修 | Home Maintenance | 房屋与工具 | 房屋施工修缮 |
| shopping.household | 日用品 | Household Supplies | 日用瓶罐 | 纸品、清洁用品 |
| shopping.clothing | 服饰鞋包 | Clothing & Accessories | T 恤 | 衣服、鞋、包、普通配饰 |
| shopping.beauty | 美妆护理 | Beauty & Personal Care | 护理瓶 | 护肤彩妆用品；理发是服务 |
| shopping.kitchenware | 厨具餐具 | Kitchenware | 杯与碗 | 杯子、锅、餐具；可关联物品 |
| shopping.appliances | 家用电器 | Home Appliances | 家电 | 冰箱、洗衣机、清洁电器 |
| shopping.other | 其他购物 | Other Shopping | 购物袋 | 明确商品但无更适合类别 |
| digital.computers | 电脑整机 | Computers | 笔记本电脑 | 台式、笔记本整机 |
| digital.components | 电脑配件 | Computer Components & Peripherals | 芯片／键盘 | CPU、显卡、内存、键鼠、显示器 |
| digital.mobile | 手机平板 | Phones & Tablets | 手机与平板 | 手机、平板整机 |
| digital.camera | 摄影设备 | Cameras & Photography | 相机 | 相机、镜头、摄影专用设备 |
| digital.audio | 音频设备 | Audio Equipment | 耳机 | 耳机、音箱、麦克风等 |
| digital.network | 网络与存储 | Networking & Storage | 网络与硬盘 | NAS、路由器、存储设备 |
| digital.wearables | 智能与穿戴 | Smart & Wearable Devices | 手表 | 智能手表、传感器等；家电整机优先家电 |
| digital.maker | 创作设备 | Maker Equipment | 立体打印设备 | 3D 打印机等创作硬件 |
| digital.accessories | 数码配件 | Device Accessories | 数据线与插头 | 手机壳、线材、充电器；电脑专用外设优先电脑配件 |
| communications.mobile | 手机话费 | Mobile Service | 手机信号 | 话费套餐实际消费；充值为储值转账 |
| communications.broadband | 宽带 | Broadband | 网络信号 | 宽带服务；路由器是数码硬件 |
| communications.addons | 通信增值服务 | Communication Add-ons | 信号加号 | 流量包等 |
| health.care | 门诊住院 | Medical Care | 医疗十字 | 诊疗、住院 |
| health.medicine | 药品 | Medicines | 药片 | 药品购买 |
| health.checkups | 检查体检 | Check-ups | 检查单 | 体检、专项检查 |
| health.equipment | 医疗器械 | Medical Equipment | 医療器具 | 家用监测、护理设备 |
| education.courses | 课程培训 | Courses & Training | 人物与讲台 | 课程、培训 |
| education.books | 图书资料 | Books & Materials | 书本 | 学习书籍、资料 |
| education.exams | 考试认证 | Exams & Certifications | 证书 | 考试、认证费用 |
| leisure.entertainment | 文娱活动 | Entertainment | 剧院面具 | 电影、演出、娱乐活动 |
| leisure.games | 游戏 | Games | 游戏手柄 | 游戏软件、游戏内消费；硬件归数码 |
| leisure.fitness | 运动健身 | Sports & Fitness | 跑步人物 | 健身、运动场馆及用品 |
| leisure.attractions | 景点门票 | Attractions | 门票 | 景区、博物馆等门票 |
| leisure.hobbies | 兴趣爱好 | Hobbies | 调色板 | 兴趣材料、收藏等明确消费 |
| social.gifts | 礼物 | Gifts | 礼物盒 | 真实赠送的物品，不等于所有亲属卡消费 |
| social.cash | 礼金红包 | Cash Gifts | 红包 | 无需归还的赠与；借出本金不属于礼金，用户确认转赠与后才按赠与统计 |
| social.donations | 公益捐赠 | Donations | 爱心与手 | 公益支出 |
| subscriptions.software | 软件与 AI | Software & AI | 应用窗口 | 软件许可、AI 服务 |
| subscriptions.cloud | 云服务与存储 | Cloud & Storage | 云 | 云盘、托管、存储服务；NAS硬件归数码 |
| subscriptions.media | 影音会员 | Media Memberships | 播放按钮 | 视频、音乐服务 |
| subscriptions.content | 内容资讯 | Content & News | 报纸 | 内容订阅、资讯会员 |
| subscriptions.other | 其他数字服务 | Other Digital Services | 循环箭头 | 明确数字服务，无对应细项 |
| services.courier | 快递跑腿 | Courier & Errands | 快递箱 | 快递、跑腿；购物总价内运费不强制拆单 |
| services.cleaning | 家政洗护 | Cleaning & Laundry | 衣物与水滴 | 家政、洗衣服务 |
| services.grooming | 美容理发 | Grooming | 剪刀 | 个人护理服务 |
| services.repair | 维修服务 | Repair Services | 扳手 | 非房屋／车辆的一般维修，可关联物品 |
| services.other | 其他生活服务 | Other Services | 服务人物 | 已明确用途的其他服务 |
| insurance.health | 健康保障 | Health Coverage | 盾牌与心 | 医疗、意外、人身保障 |
| insurance.vehicle | 车辆保险 | Vehicle Insurance | 汽车与盾牌 | 车险 |
| insurance.property | 财产与其他保险 | Property & Other Insurance | 房屋与盾牌 | 财产及其他保障 |
| financial.interest | 借款利息 | Loan Interest | 百分号 | 贷款／信用消费利息；不含本金 |
| financial.payment | 账户与支付手续费 | Account & Payment Fees | 卡片与齿轮 | 转账、账户等普通手续费 |
| financial.loan | 借款服务费 | Loan Fees | 合同与费用 | 借款相关费用；证券费用不放这里 |
| other.identified | 其他明确支出 | Other Identified Expenses | 省略号圆圈 | 必须已经理解用途 |

### 3.1 按需启用的扩展模板

默认快速面板不增加大量当前不用的类别。分类管理可按需要启用以下模板或自行新建，启用时同时生成稳定 ID、图标、颜色和中英名称。

| 一级模板 | 二级例子 | 图标／建议色 |
|---|---|---|
| 宠物 Pets | 食品 Food；医疗 Vet Care；用品 Supplies；服务 Services | 爪印／#B68A57 |
| 育儿 Childcare | 喂养 Feeding；用品 Supplies；托育 Daycare | 婴儿／#C887A2 |
| 照护 Caregiving | 护理 Nursing；照护服务 Care Services | 双手／#638D98 |
| 税费与行政 Taxes & Administration | 个人税费 Personal Taxes；证件办理 Documents | 文件印章／#7D8493 |

这些是扩展能力，不表示用户已有相关生活情况。启用后继续按用途规则和主体维度工作，避免类别里出现“给 LZY 买的全部东西”。保险储蓄、购房资产等涉及资产性质的业务不能仅靠增加消费类别解决，应走正确的账户与事件类型。

## 4. 收入分类

收入与支出分开维护两级树。下列为设计默认，不把现金流入全部叫收入。

| 一级（ID） | English | 图标／色值 | 二级中文 / English（ID） |
|---|---|---|---|
| 工作收入（employment） | Employment Income | 公文包／#428A6B | 工资 / Salary（salary）；奖金 / Bonus（bonus）；兼职劳务 / Freelance & Services（freelance） |
| 经营收入（business） | Business Income | 商店／#507C9D | 经营所得 / Business Earnings（earnings）；租金 / Rental Income（rent） |
| 资金收益（interest） | Interest Income | 百分号／#659889 | 存款利息 / Deposit Interest（deposit）；借出利息 / Lending Interest（lending） |
| 赠与补助（benefits） | Gifts & Benefits | 礼物／#B47F98 | 收礼 / Received Gifts（gifts）；补助 / Benefits（allowance） |
| 其他收入（income_other） | Other Income | 加号圆圈／#7F8792 | 其他明确收入 / Other Identified Income（identified） |

工资、奖金使用公文包／奖章；兼职用人物工具；经营用商店；租金用房屋钥匙；利息用百分号；收礼用礼物；补助用手托硬币；其他收入用加号圆圈。二级继承父级色。

证券分红、已实现交易收益由投资事件自动进入投资分析，不让用户另记一次同额日常收入。已关联购买的退款与出售回收、报销回款、借出本金收回、借入本金、自己账户转入、卖股收回本金均不映射“其他收入”。借出回款含利息时，本金与利息分开，只有利息进入对应收入分类。

原购买早于开始记账的二手出售，可由用户手动选择普通收入及其分类，无需强制补录购买；这不改变已关联购买的回收规则。借出损失、借入减免由对应事件性质单列，不新增普通支出或收入种子来替代这些业务；报销、借出、借入使用各自独立管理入口。

## 5. 分类与导入规则联动

### 5.1 身份与迁移

规则存类别 ID；原始账单类别原文另存。改中文／英文名称无需重写源账单。移动二级分类时先展示历史在一级汇总、预算范围、预设卡片和规则的变化；删除有引用类别时迁移或阻止，绝不留空。

用户停用一个类别后，历史保持；新导入命中它显示“目标分类已停用”，选择恢复或新目标，不能继续无提示使用。规则预览与最终导入使用相同版本。

### 5.2 通用 CSV 导入的合成示例

以下全部为说明规则而构造的合成场景，不取自真实账单或已有分析。来源、账户、主体与用途分别核对，不能仅凭一列名称推断全部字段。

| 来源证据 | 合理候选 | 禁止的推断 |
|---|---|---|
| 商品为“咖啡一杯”，已核对实际支付 | 餐饮／饮品 | 所有含“店”的商户都归餐饮 |
| 商品分别明确为机票、酒店住宿 | 交通／机票；居住／住宿，可关联同一旅行项目 | 统一塞进旅行大类 |
| 支付字段明确为亲属代付，用户确认主体为 LZY | 保留主体与支付关系，按实际商品选择用途分类 | 直接归人情或礼物，或由主体推断资金归属 |
| 从银行卡向手机储值账户充值 100 | 银行卡转账至话费账户，双方余额对应变化 | 将充值记为通信消费，或因话费不计总资产而忽略余额 |
| 手机储值账户实际扣除套餐费 20 | 通信／手机话费，储值余额减少 20 | 将充值与使用各计一次消费 |
| 服务项目明确为住宅物业服务费 | 居住／物业 | 仅看到“费”字就归财务费用 |
| 只知道来自某购物平台，商品和支付账户不明 | 保留来源，继续核对用途与实际扣款账户 | 从平台名自动推断商品用途或扣款账户 |
| 人名、转账金额已知，用途不明 | 待核对交易性质、主体与账户 | 默认人情支出、借出或日常收入 |
| 退款 30，能匹配到本账本原购买 | 关联原购买形成支出回收 | 新记收入、改写原发生额或释放预算 |
| 二手出售，用户确认原购买早于开始记账并选择普通收入 | 按用户选择的收入分类记账，不强制关联原购买 | 自动创建原购买、物品或回收事件 |
| 用户确认收到的是一笔报销回款 | 关联报销事项并减少待报销金额 | 自动归普通收入或冲回消费预算 |
| 用户确认收到借出本金 100 和利息 5 | 本金减少待收款，利息归资金收益／借出利息 | 将全部 105 记成普通收入 |
| 已核对的证券交易税费 | 投资费用组件 | 财务费用消费分类占预算 |

本批批量修改与保存长期规则是两个独立动作。“应用到本批记录”先展示受影响记录，仅修改用户确认的本批范围，不自动创建长期规则；“记住这次选择”用于以后的导入，仍须分别选择记住分类、账户或主体，保存前展示条件与作用范围。

高优先级规则给建议，有冲突由用户确认；分类候选本身不是自动入账授权。本批修改后，长期规则不能覆盖用户已核对的手动值。

## 6. 种子目录验收

- 中文／英文与图标语义一一对应；所有启用叶子有有效父类、图标、颜色和稳定 ID。
- 创建空账本只播种基础类别和默认主体，不灌任何真实账户、余额或交易；默认主体 MPC 可先生成，LZY 可在初始化确认加入。
- 播种幂等：升级不重复创建、不覆盖用户自定义、不恢复用户明确停用的类别。
- 重命名不改历史归属；迁移预览覆盖预算、规则、图表、历史统计。
- 默认快速分类面板可搜索并调整常用顺序，目录完整不等于所有项始终占据首页空间。
- 物品 URL 图标只属于物品模块，不因本分类附录而扩展为流水图片附件。
- 储值充值、报销回款、借还本金不会因来源名称被误分类为普通收支；账户是否计入总资产不影响其余额跟踪。
- 个人承担按确认月份进入消费和预算；借出损失与借入减免保持独立事件性质，转赠与才按赠与类别及范围计预算。
- 已关联购买的回收与无原购买关联、由用户手动选择的二手出售收入可区分；流水原额、回收标记、详情净花费与预算口径一致。
- 本批批量修改不自动生成长期规则，长期规则也不静默覆盖已经确认的本批修改。
