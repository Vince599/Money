# 国内资产图标与模板

这是新增、编辑账户页面共用的静态素材库，默认中国大陆、人民币。资源已离线保存，新增 `LedgerBook()` 仍为空账本。账户现在保存可空的机构、模板和图标 ID；新增／编辑页面、SQLite schema 2 和 CSV profile 2 已完成代码接入，并在固定提交上通过 Apple 自动化构建与回归。验收范围和仍待补充的真机／视觉检查见本文末尾。

版本沿革：以上呈现字段从 schema 2／profile 2 引入；后续退款批次已升级到 schema 3／profile 3，保留这些字段和旧备份读取。当前契约以 [CSV_FORMAT.md](CSV_FORMAT.md) 为准，各批实际验证见 [BUILD.md](BUILD.md)。

首批包含 **31 个机构标志、8 个通用回退、54 个账户模板**：微信、支付宝、QQ 钱包；移动、联通、电信、广电；六大行、12 家全国性股份制银行，以及北京、上海、江苏、宁波、杭州、南京银行。银行部分提供 24 个借记卡模板和 15 个常用信用卡模板，另有通用账户、现金、饭卡、交通卡和购物卡。

## 文件与维护入口

| 文件 | 用途 |
| --- | --- |
| [catalog.json](../assets/account-templates/catalog.json) | 唯一维护入口：机构、图标、模板、别名、默认值、出处及 SHA-256 |
| [preview.html](../assets/account-templates/preview.html) | 可直接用浏览器打开的离线预览；支持名称、简称、英文别名搜索和类型筛选 |
| [banks](../assets/account-templates/banks) / [services](../assets/account-templates/services) | 原始或有加工说明的 SVG / PNG、上游来源记录及许可文件 |
| [AccountTemplate.swift](../Sources/LedgerCore/AccountTemplate.swift) | 可直接调用的数据类型、搜索、未保存账户工厂及编辑兼容性过滤 |
| [AccountTemplateCatalog.swift](../Sources/LedgerCore/AccountTemplateCatalog.swift) | 由清单生成的纯 Swift 静态目录，随 LedgerCore 编译，无运行时 JSON 或网络依赖 |
| [AccountBrands](../App/Assets.xcassets/AccountBrands) | 生成的 Xcode imageset，以 `account-brand-…` 命名；`project.yml` 的 `App` sources 包含该资源目录 |

维护清单后运行以下命令。生成器只读本地素材，校验 ID、引用、资源摘要和 SVG 安全性，再生成 Swift、imageset 和预览。请勿手工修改生成文件。

```powershell
python scripts/generate-account-templates.py
python scripts/generate-account-templates.py --check
./scripts/test-core.ps1
```

图标上游来源摘要位于 `banks/banks.sources.json` 和 `services/services.sources.json`。增加或替换图标时核对品牌、保留出处和加工记录，更新 `catalog.json` 的文件路径与 SHA-256；更换外观不改变稳定 ID。生成器发现多余的旧 imageset 会报错，维护者应确认对应引用后再移除。

## 账户语义

| 模板 | kind / nature | 默认计入资产负债汇总 | 说明 |
| --- | --- | --- | --- |
| 微信零钱、支付宝余额、QQ 钱包余额 | wallet / asset | 是 | 只表示钱包自身余额；绑定银行卡另建账户 |
| 银行借记卡 | bank / asset | 是 | 可重复选择同一模板创建多张卡，自定义名称或尾号 |
| 常用银行信用卡、通用信用卡 | creditCard / liability | 是 | 期初填尚欠金额，信用额度不算资产；与借记卡共用机构标志 |
| 移动、联通、电信、广电话费 | storedValue / asset | 否 | 充值记账户间转账，实际扣费才记消费 |
| 交通卡、饭卡、购物卡、其他储值 | storedValue / asset | 否 | 此处选用保守的模板默认值，新增时仍允许自行改汇总开关 |
| 现金、其他钱包、其他银行卡 | 对应类型 / asset | 是 | 使用 SF Symbols 通用回退 |

机构 ID（如 `icbc`）、模板 ID（如 `cn.icbc.debit`、`cn.icbc.credit`）、图标 ID（如 `brand.icbc`）各自独立。它们均不是实际账户 UUID；每次创建账户产生新 UUID。

这批模板不将云闪付、Apple Pay 等绑定银行卡的支付入口自动记成独立余额，也不将微信零钱通、余额宝或信用额度混入钱包余额。投资账户与具体金融产品后续按各自账务模型补充。

## 新增页面的调用方式

```swift
import LedgerCore

let wallets = AccountTemplateCatalog.search("", group: .wallet)
let matches = AccountTemplateCatalog.search("工行") // 同时支持 ICBC、gongshang

if let template = AccountTemplateCatalog.template(id: "cn.icbc.debit") {
    let draft = template.makeAccount(
        name: "工资卡 8899",
        openingMinor: 123_456, // CNY 分，即 1,234.56 元
        openingDate: chosenDate
    )
    // 将 draft 展示给用户，确认后走现有的 model.addAccount。
    // 用户已填的名称、金额、日期、汇总选择应保留；切换模板不能静默重置这些内容。
    // makeAccount 只组装未保存数据；trim、金额解析、校验仍走当前保存入口。
}
```

图标在 App target 内通过资产名称直接调用。品牌图像以原色显示、等比缩放；建议 32–40 pt 图标位内留边，用固定白色小底板兼容深色界面，不把品牌色铺满整行或卡片。

```swift
// 在 SwiftUI ViewBuilder 内；导入 SwiftUI、UIKit 和 LedgerCore。
if let icon = AccountTemplateCatalog.icon(id: chosenIconID) {
    if let name = icon.assetName, UIImage(named: name) != nil {
        Image(name)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .padding(5)
            .frame(width: 36, height: 36)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true) // 同行账户名称提供读屏标签
    } else {
        Image(systemName: icon.fallbackSymbol)
            .accessibilityHidden(true)
    }
} else {
    Image(systemName: "wallet.bifold").accessibilityHidden(true)
}
```

`colorHex` 是小面积辅助色，不用于强制重染多色品牌标志。微信余额使用微信品牌双气泡，QQ 钱包使用 QQ 企鹅；清单说明这些是母品牌图标，不声称是各自独立金融产品标志。

## 编辑账户与持久化

编辑候选可以用 `template.isCompatible(with: account)` 筛选；该函数只检查类型、性质和币种，**不是应用模板的写入接口**。当前 `CatalogEditor.saveAccount` 不允许修改已有账户的 `kind`、`nature`、`currency`、`openingMinor`、`openingDate`。账户 UUID、历史流水、已填写名称、启用状态及汇总设置也不得因换图标自动重置。编辑机构／图标应使用单独的呈现字段，不调用 `makeAccount` 替换现有账户。

`Account` 的 `institutionID`、`templateID`、`iconID` 均为可空稳定字符串。当前实现遵循以下兼容规则：

- 旧 JSON 缺字段按 `nil` 解码；未知 ID 原值保存并显示通用图标。不会按账户名称自动推断，允许自定义名称及同机构多账户。
- SQLite schema 2 在账户表保存三个可空投影列并继续与 payload 交叉校验；打开 schema 1 时在同一事务添加列、升级版本并完整读取验证，失败回滚。
- 新 CSV 导出为 `ledger-core-v2 / 2.0 / db2`，`accounts.csv` 增加三个可空文本列；解码器仍接受精确的 `ledger-core-v1 / 1.0 / db1`，旧备份恢复后字段为 `nil`。版本、表头与字典混搭会被拒绝。

## 后续实施顺序与验收

实现与验收按以下顺序推进。前四步已经进入当前工作副本；第五步已由 Apple 工具链和模拟器自动化覆盖主要新增流程。Windows 核心测试不能替代 Apple 构建，模拟器自动化也不能替代全部真机与视觉验收。

| 顺序 | 实施位置与内容 | 完成标准 |
| --- | --- | --- |
| 1. 持久化与备份（代码完成） | 在 `Sources/LedgerCore/Models.swift`、`Sources/LedgerStore/SQLiteLedgerStore.swift` 及 `BackupSchema.swift` / `BackupCodec.swift` 落实上一节的可空标识、迁移和版本兼容。 | 旧账本升级、旧版 CSV 恢复后账户与余额不变；新标识保存重开后保留；完整备份往返保留已知及未知 ID，未知 ID 不阻止恢复。迁移或恢复失败时原账本完整。 |
| 2. 共享图标显示（代码完成） | App 内的共享账户图标组件由账户列表、模板选择和编辑页面共用本地资源查找、SF Symbols 回退及读屏规则。 | 旧账户无标识、未知标识或资源缺失时显示通用图标；品牌保持原色、等比缩放，离线正常显示，同行名称与图标不重复朗读。 |
| 3. 新增账户（代码完成） | [AccountsView.swift](../App/AccountsView.swift) 的 `AddAccountView` 已接入分组、搜索和模板草稿，再走现有 `model.addAccount` 保存。 | 可以按中文、机构简称、英文别名搜索；同机构可新增多账户。同一份新建草稿固定账户 UUID，保存重试不重复创建；切换模板保留用户已填内容，取消不留下账户。话费默认不计入汇总，信用卡为负债，空账本不自动生成账户。 |
| 4. 编辑账户（代码完成） | [CatalogViews.swift](../App/CatalogViews.swift) 的 `EditAccountView` 已接入兼容模板筛选，仅更新明确选择的机构／模板／图标呈现字段，继续由 `CatalogEditor.saveAccount` 校验。 | 换图标后账户 UUID、类型、性质、币种、期初、余额与历史不变；用户名称、启用状态和汇总选择不被模板覆盖。保存重开及导出恢复后呈现选择一致，取消编辑不写入。 |
| 5. Apple 平台验收（主要自动化流程完成） | 在固定 Apple 工具链运行 `scripts/build-ios.sh`，确认 Xcode `actool` 编译新增 imageset，并以 iOS 模拟器自动化验证模板新建和重开。 | 运行 #19 已完成资源编译、全套测试及 arm64 Release IPA；自动化覆盖运营商模板的搜索、默认值、用户覆盖、切换模板、保存和重开。全品牌逐个加载、浅色／深色、大字号、真机及 profile 2 备份恢复仍需单独记录。 |

核心测试负责模板默认值、搜索、编辑边界与备份数据契约；App／存储测试负责实际保存、升级及恢复；iOS 页面验收负责资源编译后的显示与交互。不能用一层测试通过代替其他层的完成证据。

## 资源来源与验证范围

钱包图形来自 Simple Icons，上游许可和免责声明随素材保留；银行及运营商逐项记录实际来源、固定修订（如有）、获取日期、加工步骤及授权声明状态。图标库的代码许可与品牌商标权分别记录；第三方收集的标志不标为官方授权。具体信息以清单及来源文件为准。

2026-09-26 已完成的验证：Windows 核心测试 **112 项、11 个套件**通过，其中账户模板为 **6 个测试**；生成器 `--check` 通过；离线预览的 **31 个品牌、54 个模板**图片全部加载，搜索与类型筛选通过。

上述 Windows 结果验证清单与生成产物一致、模板核心行为及浏览器预览。随后 [云端运行 #11](https://github.com/Vince599/Money/actions/runs/36221886418)在验证提交 `44ef8b11da2bc84764f98e33286b9b4e5a5a47fa` 上完成 Xcode `actool` 资源编译、模拟器测试和 arm64 Release 构建；账户模板核心测试也包含在通过的 135 项包测试中。

素材阶段的运行 #11 不能代表之后的页面与 schema 2 改动。新的固定快照已经完成两轮 Apple 验证：

- [运行 #18](https://github.com/Vince599/Money/actions/runs/36288574926)验证提交 `e2f9ead3716653b3abd3c64b740d57c594264c29`。173 项包测试、39 项 App 测试通过；3 项 UI 测试中有 1 项因自动化点击未命中目标而失败，因此整轮失败且没有生成 IPA。这个结果证明失败发生在 UI 操作定位，不能记为完整通过或安装包交付。
- [运行 #19](https://github.com/Vince599/Money/actions/runs/36289340271)只调整上述 UI 测试的命中方式，验证提交 `de6889a9757a8c29100f02dfcfad746fc2edff08`。173 项包测试（16 个套件）、39 项 App 测试和 3 项 UI 测试，共 **215 项**全部通过，并生成 arm64 Release IPA。

运行 #19 的账户模板 UI 自动化覆盖：搜索并选择中国移动话费模板、确认话费默认不计入资产汇总、保留用户手工修改的账户名称和汇总选择、切换为中国联通模板、保存并重启 App 后确认联通模板仍然保留。Store 与 Core 回归同时覆盖 schema 1 到 schema 2 的事务迁移、呈现字段持久化，以及 CSV profile 1 解码和 profile 2 数据契约往返。

这组证据没有逐个打开全部品牌图标，也没有覆盖浅色／深色切换、大字号布局、iOS 真机显示或 profile 2 备份恢复的完整页面流程。上述场景仍需单独验收，不能由一次运营商模板模拟器用例或 IPA 生成结果推断通过。
