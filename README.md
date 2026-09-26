# Ledger for iPhone

单人、单账本的本地 iPhone 财务 App，使用 Swift、SwiftUI 和 SQLite。产品规则见 [IOS_DESIGN.md](IOS_DESIGN.md)，分类见 [IOS_CATEGORIES.md](IOS_CATEGORIES.md)。

目前已实现普通收支、同币种转账、余额更正、编辑删除、自动草稿，以及账户／分类／主体维护。当前全部核心数据支持 CSV ZIP 备份，并已接入恢复预览、安全副本和原子恢复页面。它还不是完整可安装版本；贷款、投资、来源账单导入等按设计继续实施。准确范围与验证结果见 [开发记录](docs/DEVELOPMENT.md)。

## 本机验证

Windows PowerShell，在项目根目录运行：

```powershell
./scripts/test-core.ps1
```

2026-09-26 实测 Swift 6.4，72 项核心测试通过，覆盖账务、目录维护、CSV、ZIP 和备份往返。Windows 只构建纯 Swift 核心；SQLite/GRDB、SwiftUI、模拟器和安装需要 Apple 工具链。

## Apple 平台构建

macOS 的统一入口：

```bash
bash scripts/build-ios.sh
```

固定工具版本、GitHub Actions 手动工作流、产物与签名方式见 [构建说明](docs/BUILD.md)。该流程尚未实际运行，当前没有已验证 IPA。

## 目录

| 路径 | 内容 |
|---|---|
| `Sources/LedgerCore` | 精确金额、领域模型、账务规则、草稿与默认设置 |
| `Sources/LedgerCore/Backup*.swift` | 当前全部核心数据的 CSV 契约、校验和 ZIP 容器，详见 [格式说明](docs/CSV_FORMAT.md) |
| `Sources/LedgerStore` | GRDB SQLite、关联校验、原子保存 |
| `App` | 原生页面、状态模型、串行存储入口 |
| `Tests` / `AppTests` | 核心、数据库与 App 存储集成测试 |
| `project.yml` / `config` / `scripts` | 工程生成、工具版本与构建验证 |
| `docs` | 开发记录及构建说明 |

正式新账本不带演示资产或流水。首次使用需添加自己的账户；原 HTML 预览仅为设计参考。
