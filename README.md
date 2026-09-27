# Ledger for iPhone

单人、单账本的本地 iPhone 财务 App，使用 Swift、SwiftUI 和 SQLite。产品规则见 [IOS_DESIGN.md](IOS_DESIGN.md)，分类见 [IOS_CATEGORIES.md](IOS_CATEGORIES.md)。

以用户当前 iOS 27 真机为主要体验目标，主动采用最新稳定且适用的 Apple 原生技术。视觉、启动速度、动画与操作跟手性、桌面小组件及资源效率贯穿每个开发阶段；具体预算与验收见[原生体验与工程质量标准](docs/EXPERIENCE_QUALITY.md)。当前已验证工具链仍为 Xcode 26.6，升级至 Xcode 27／iOS 27 SDK 及真机性能达标均待实施验证。

目前已实现普通收支、同币种转账、余额更正、编辑删除、自动草稿，以及账户／分类／主体维护。第三批加入精确金额计算器、复制为新流水、标题备注搜索及组合筛选。当前全部核心数据支持 CSV ZIP 备份，并已接入恢复预览、安全副本和原子恢复页面。当前版本未签名 IPA 已生成并核验，仍需签名后才能真机安装；贷款、投资、来源账单导入等按设计继续实施。准确范围与验证结果见 [开发记录](docs/DEVELOPMENT.md)。

国内账户模板包含 31 个机构图标、8 个通用回退和 54 个模板，覆盖微信、支付宝、QQ 钱包、24 家银行及四家运营商。新增／编辑账户已接入搜索、兼容筛选和共享图标，选择结果保存到 SQLite schema 2，并进入 CSV profile 2 完整备份；旧 schema 1 数据库和 profile 1 备份可迁移读取。页面、迁移和备份链路已在 [Apple 云端运行 #19](https://github.com/Vince599/Money/actions/runs/36289340271)通过自动验证；规则与尚待真机覆盖的边界见[国内资产图标与模板接入说明](docs/ACCOUNT_TEMPLATES.md)，素材可在[离线预览](assets/account-templates/preview.html)中查看。

## 本机验证

已接入快捷指令记账：支持打开预填确认与直接保存两种动作，覆盖支出、收入和同币种转账，沿用精确金额、默认账户及草稿保护。已与首页摘要及共享启动一起通过 Apple 编译和自动测试，并在运行 #19 继续完整回归；系统动作发现、后台／锁屏执行与覆盖安装仍需真机验证。使用方式和验证边界见[快捷指令说明](docs/SHORTCUTS.md)。

Windows PowerShell，在项目根目录运行：

```powershell
./scripts/test-core.ps1
```

2026-09-27 实测 Swift 6.4，当前工作副本 137 项核心测试通过，覆盖账务、目录维护、计算器、复制、查询、CSV、ZIP、新旧备份往返、账户模板、快捷指令请求和首页摘要。Windows 脚本在隔离目录原样镜像纯 Swift 核心及测试，保留根 Apple 依赖锁；SQLite/GRDB、SwiftUI、模拟器和 IPA 构建使用 Apple 工具链。账户模板页面、schema 2 和 profile 2 的 Apple 自动验证已经通过，结果见下节；生成的 IPA 可在 Windows 通过用户本地签名后安装。

性能测量准备、合成数据的 Windows 领域基线和 App 内计时边界见[性能基线说明](docs/PERFORMANCE_BASELINE.md)。普通新建／编辑已改为同事务增量写入；完整快照改为一次读事务，磁盘启动直接使用首次存储快照，避免重复全量解码。首页改为后台统一派生资产、本月消费和最近五条，草稿输入不重算，并防止跨月及延迟刷新显示旧状态。防重、草稿和回滚规则保留，整本读取／校验仍需后续优化。App 插桩已通过 Apple 编译，Instruments trace 与真机性能仍待测量。

## Apple 平台构建

macOS 的统一入口：

```bash
bash scripts/build-ios.sh
```

固定工具版本、GitHub Actions 手动工作流、产物与签名方式见 [构建说明](docs/BUILD.md)。2026-09-27 [云端运行 #19](https://github.com/Vince599/Money/actions/runs/36289340271)通过 16 个套件共 173 项 macOS 包测试、39 项 iOS 模拟器 App 测试和 3 项页面操作测试，共 215 项，并生成 arm64 未签名 IPA 与模拟器截图。验证提交为 `de6889a9757a8c29100f02dfcfad746fc2edff08`。新增页面回归搜索 10086 并选择中国移动话费，确认默认不计入汇总；随后保留用户修改的名称和汇总选择，切换到 10010 中国联通模板，保存、重启后仍保持联通模板。该运行同时覆盖 schema 1→2 迁移、profile 1／2 备份兼容和既有功能回归。用户反馈此前版本在 iOS 27 真机上安装、基础记账、重开及 ZIP 导出恢复通过；本次账户模板仍需在真机检查资源加载、交互和覆盖安装，profile 2 真机恢复、深浅色、大字号、全部品牌逐个运行时加载、Xcode 27 升级及性能测量也尚未完成。

Windows 真机安装统一从 **`D:\Data\Ledger-Install\Ledger-latest.ipa`** 取最新版，桌面“Ledger Install”快捷方式可直达。当前固定文件已更新为运行 #19（SHA-256 `70738ddf9095a830721e2ddc1f2a1b312da736505438b0bcc20e7db44b6cfcb7`）；版本信息见同目录 `安装说明.txt`，流程见[固定安装包目录](docs/BUILD.md#固定安装包目录)。

## 目录

| 路径 | 内容 |
|---|---|
| `Sources/LedgerCore` | 精确金额、领域模型、账务规则、草稿与默认设置 |
| `Sources/LedgerCore/Backup*.swift` | 当前全部核心数据的 CSV 契约、校验和 ZIP 容器，详见 [格式说明](docs/CSV_FORMAT.md) |
| `Sources/LedgerStore` | GRDB SQLite、关联校验、原子保存 |
| `App` | 原生页面、状态模型、串行存储入口 |
| `assets/account-templates` / `App/Assets.xcassets/AccountBrands` | 国内机构图标、账户模板清单、出处、离线预览及生成的 Xcode 资源；[接入与验收说明](docs/ACCOUNT_TEMPLATES.md) |
| `Tests` / `AppTests` / `AppUITests` | 核心、数据库、App 存储集成和页面操作测试 |
| `project.yml` / `config` / `scripts` | 工程生成、工具版本与构建验证 |
| `docs` | 开发记录、构建说明及原生体验与工程质量标准 |

正式新账本不带演示资产或流水。首次使用需添加自己的账户；原 HTML 预览仅为设计参考。
