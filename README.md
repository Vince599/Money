# Ledger for iPhone

单人、单账本的本地 iPhone 财务 App，使用 Swift、SwiftUI 和 SQLite。产品规则见 [IOS_DESIGN.md](IOS_DESIGN.md)，分类见 [IOS_CATEGORIES.md](IOS_CATEGORIES.md)。

目前已实现普通收支、同币种转账、余额更正、编辑删除、自动草稿，以及账户／分类／主体维护。第三批加入精确金额计算器、复制为新流水、标题备注搜索及组合筛选。当前全部核心数据支持 CSV ZIP 备份，并已接入恢复预览、安全副本和原子恢复页面。已生成基础版本未签名 IPA，仍需签名后才能真机安装；贷款、投资、来源账单导入等按设计继续实施。准确范围与验证结果见 [开发记录](docs/DEVELOPMENT.md)。

## 本机验证

Windows PowerShell，在项目根目录运行：

```powershell
./scripts/test-core.ps1
```

2026-09-26 实测 Swift 6.4，106 项核心测试通过，覆盖账务、目录维护、计算器、复制、查询、CSV、ZIP 和备份往返。Windows 脚本在隔离目录原样镜像纯 Swift 核心及测试，保留根 Apple 依赖锁；SQLite/GRDB、SwiftUI、模拟器和 IPA 构建使用 Apple 工具链。生成的 IPA 可在 Windows 通过用户本地签名后安装。

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
| `Tests` / `AppTests` / `AppUITests` | 核心、数据库、App 存储集成和页面操作测试 |
| `project.yml` / `config` / `scripts` | 工程生成、工具版本与构建验证 |
| `docs` | 开发记录及构建说明 |

正式新账本不带演示资产或流水。首次使用需添加自己的账户；原 HTML 预览仅为设计参考。
