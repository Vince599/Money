# Ledger for iPhone

单人、单账本的本地 iPhone 财务 App，使用 Swift、SwiftUI 和 SQLite。产品规则见 [IOS_DESIGN.md](IOS_DESIGN.md)，分类见 [IOS_CATEGORIES.md](IOS_CATEGORIES.md)。

以用户当前 iOS 27 真机为主要体验目标，主动采用最新稳定且适用的 Apple 原生技术。视觉、启动速度、动画与操作跟手性、桌面小组件及资源效率贯穿每个开发阶段；具体预算与验收见[原生体验与工程质量标准](docs/EXPERIENCE_QUALITY.md)。当前已验证工具链仍为 Xcode 26.6，升级至 Xcode 27／iOS 27 SDK 及真机性能达标均待实施验证。

目前已实现普通收支、同币种转账、余额更正、编辑删除、自动草稿，以及账户／分类／主体维护。第三批加入精确金额计算器、复制为新流水、标题备注搜索及组合筛选。当前全部核心数据支持 CSV ZIP 备份，并已接入恢复预览、安全副本和原子恢复页面。已生成基础版本未签名 IPA，仍需签名后才能真机安装；贷款、投资、来源账单导入等按设计继续实施。准确范围与验证结果见 [开发记录](docs/DEVELOPMENT.md)。

国内账户模板已准备 31 个机构图标、8 个通用回退和 54 个模板，覆盖微信、支付宝、QQ 钱包、24 家银行及四家运营商。后续新增／编辑账户开发请先读[国内资产图标与模板接入说明](docs/ACCOUNT_TEMPLATES.md)，素材可在[离线预览](assets/account-templates/preview.html)中查看。当前已提供 Swift 目录和 Xcode 资源，页面接入与机构／图标字段持久化尚待实现。

## 本机验证

Windows PowerShell，在项目根目录运行：

```powershell
./scripts/test-core.ps1
```

2026-09-26 实测 Swift 6.4，112 项核心测试通过，覆盖账务、目录维护、计算器、复制、查询、CSV、ZIP、备份往返及账户模板。Windows 脚本在隔离目录原样镜像纯 Swift 核心及测试，保留根 Apple 依赖锁；SQLite/GRDB、SwiftUI、模拟器和 IPA 构建使用 Apple 工具链。生成的 IPA 可在 Windows 通过用户本地签名后安装。

性能测量准备、合成数据的 Windows 领域基线和 App 内计时边界见[性能基线说明](docs/PERFORMANCE_BASELINE.md)。领域耗时不代表 iPhone 的实际操作速度；新增 App 插桩尚待 Apple 编译和真机 trace 验证。

## Apple 平台构建

macOS 的统一入口：

```bash
bash scripts/build-ios.sh
```

固定工具版本、GitHub Actions 手动工作流、产物与签名方式见 [构建说明](docs/BUILD.md)。2026-09-26 第三批[完整构建与页面验证](https://github.com/Vince599/Money/actions/runs/36218393077)通过 118 项 macOS 包测试、8 项 iOS 模拟器 App 测试和 2 项页面操作测试，覆盖计算器、复制、搜索和金额筛选，并生成 arm64 未签名 IPA 与模拟器截图。用户反馈此前版本在 iOS 27 真机上安装、基础记账、重开及 ZIP 导出恢复通过；新版覆盖安装与第三批新增功能的真机测试尚待验证。

## 目录

| 路径 | 内容 |
|---|---|
| `Sources/LedgerCore` | 精确金额、领域模型、账务规则、草稿与默认设置 |
| `Sources/LedgerCore/Backup*.swift` | 当前全部核心数据的 CSV 契约、校验和 ZIP 容器，详见 [格式说明](docs/CSV_FORMAT.md) |
| `Sources/LedgerStore` | GRDB SQLite、关联校验、原子保存 |
| `App` | 原生页面、状态模型、串行存储入口 |
| `assets/account-templates` / `App/Assets.xcassets/AccountBrands` | 国内机构图标、账户模板清单、出处、离线预览及生成的 Xcode 资源；[后续接入约定](docs/ACCOUNT_TEMPLATES.md) |
| `Tests` / `AppTests` / `AppUITests` | 核心、数据库、App 存储集成和页面操作测试 |
| `project.yml` / `config` / `scripts` | 工程生成、工具版本与构建验证 |
| `docs` | 开发记录、构建说明及原生体验与工程质量标准 |

正式新账本不带演示资产或流水。首次使用需添加自己的账户；原 HTML 预览仅为设计参考。
