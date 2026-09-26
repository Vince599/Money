# Ledger 构建与首批验证

当前仓库提供首批账本骨架及构建配置。配置已按官方清单核对，但本地 Windows 无法执行 Xcode；首次 macOS CI、模拟器、iPhone 免费签名安装及覆盖更新均须单独记录真实结果。未运行 CI 就没有可安装产物，不把配置文件视为构建通过。

## 固定基线

| 项目 | 固定值 |
|---|---|
| App / scheme | `Ledger` |
| AppTests target | `LedgerAppTests` |
| UI smoke test target | `LedgerUITests`；使用隔离的 DEBUG 测试账本 |
| 本地 Swift package | `Ledger`；产品 `LedgerCore`、`LedgerStore` |
| Bundle ID | `app.vince.ledger`；测试为 `app.vince.ledger.tests` |
| 最低系统 | iOS 26.0，仅 iPhone |
| macOS 包测试最低系统 | macOS 15.0；核心累加使用 Int128，符合其系统可用版本 |
| GitHub runner | `macos-26`，arm64 |
| 核查时的 runner 镜像 | `20260907.0351.1`；它是观察记录，不能通过 runner 标签冻结 |
| Xcode | 26.6，build `17F113`，`/Applications/Xcode_26.6.app` |
| Swift | Apple 编译器 6.3、Swift 6 语言模式；本机 Windows 已观察到 6.4 |
| SDK / 模拟器运行时 | iOS 26.5 |
| XcodeGen | 2.46.0，官方 ZIP 的 SHA-256 固定在 `config/toolchain.json` |
| GRDB | 7.11.1，由根 `Package.swift` 精确依赖 |

2026-09-26 核查的官方依据：[runner 软件清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)、[Apple Xcode 兼容表](https://developer.apple.com/xcode/system-requirements/)、[XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0)、[GRDB 7.11.1](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1)。Apple 已列出更高 Xcode 版本，但当前所选稳定 runner 清单包含的是此组合；不自动换用预览 runner。

可追溯的 [runner 清单固定提交](https://github.com/actions/runner-images/blob/0af81b6d930d02b52941d584bee9214c4bc228c6/images/macos/macos-26-arm64-Readme.md) 记录镜像 `20260907.0351.1`，其 Xcode 表明确列出 26.6（默认）、build `17F113` 和 `/Applications/Xcode_26.6.app`，SDK 表列出配套 iOS 26.5。这是固定配置存在于官方镜像的依据，不是本项目已在该镜像构建成功的证据。

`macos-26` 固定的是系统系列，GitHub 仍会更新镜像。脚本校验 Xcode 版本、build 和 iOS SDK；缺少固定工具或模拟器就失败，不回退到 `latest`。每次保存实际镜像、编译器、工具版本和测试日志。工具升级需要同步 `config/toolchain.json`、`project.yml` 及本页，并重新验证。

核心在内存中用 Int128 累加分录，再检查 Int64 可存储范围；[Apple Int128 文档](https://developer.apple.com/documentation/swift/int128)标明 macOS 15.0／iOS 18.0 起可用。包的 macOS 最低版本因此为 15.0，App 仍为 iOS 26.0；这项配置核对不替代实际 Apple 平台编译。

Bundle ID 是后续覆盖安装和数据保留测试的固定基线，不能为消除签名错误随手更名。若安装工具重签时映射标识，应记录有效标识并在以后沿用；更换账号、标识或安装为另一 App 前先导出数据并明确迁移，不承诺自动继承原容器。

## Windows：运行纯 Swift 领域测试

在仓库根目录的 PowerShell 执行：

```powershell
./scripts/test-core.ps1
./scripts/test-core.ps1 -Configuration release
```

默认筛选 `LedgerCoreTests`，脚本显示实际 Swift 版本并将失败作为非成功结果返回。Swift 安装、Windows SDK 和 C++ 构建工具由现有环境提供，脚本不会安装软件或改系统设置。领域包不应导入 SwiftUI、WidgetKit、GRDB 或 iOS Keychain；Windows manifest 应只包含可移植的核心与其测试。

Windows 测试覆盖金额、分录、账户与交易规则等已实现的核心逻辑；它不能证明 Apple-only `LedgerStore`、SwiftUI、iOS 文件权限或签名安装正常。其余包测试在 macOS 执行，AppTests 在 iOS 模拟器执行。

## macOS / GitHub Actions

在具备固定 Xcode 的 Mac 执行唯一入口：

```bash
bash scripts/build-ios.sh
```

脚本按顺序执行：

1. 核对工具链；下载并校验固定版 XcodeGen 到本项目 `.tools/`，不执行全局安装。
2. 解析精确的 Swift package 依赖，运行核心与 Apple 存储包测试。
3. 从 `project.yml` 生成 `Ledger.xcodeproj`，将实际 `Package.resolved` 提供给 Xcode。
4. 在固定 iOS 26.5 运行时选择可用 iPhone，运行 `LedgerAppTests` 和 `LedgerUITests`，保存 `.xcresult`；UI 测试的截图附件导出到 `artifacts/screenshots/`。
5. 编译 `iphoneos` 的 arm64 Release App，确认产品平台和 Bundle ID，打包未签名 `Payload/Ledger.app` 为 IPA。

根 `Package.resolved` 应随源代码提交。Windows 的核心-only manifest 不能代替 Apple 依赖锁；首次 macOS 解析若产生新锁，CI 会保存它供审核回填，此前只能说直接依赖版本已固定。后续解析或依赖升级造成的锁变化应审查后提交，不手写未验证的锁文件。

项目远端为 [Vince599/Money](https://github.com/Vince599/Money)。工作流仅接受 `workflow_dispatch` 手动触发，没有 push、PR、定时触发和发布步骤。将代码及工作流同步到仓库后，在 Actions 中选择 **iOS validation and unsigned IPA**，手动选择要验证的分支运行。配置文件存在不代表已经推送、触发或构建成功，应以具体运行记录为准。首次使用私有仓库前核对其 Actions 配额与付费设置。

首次注册手动工作流时，`.github/workflows/ios.yml` 必须已存在于仓库默认分支；之后可选择其他分支运行。仅将新增工作流推到非默认分支，不能保证出现手动运行入口。参见 [GitHub 手动运行工作流说明](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)。

成功产物位于 `build/ios/<时间戳>/artifacts/`，包括 `Ledger-unsigned.ipa`、SHA-256、实际依赖锁、工具基线、构建元数据和测试结果。`screenshots/` 保存导出的 PNG 与附件清单，可从下载的 artifact 直接查看；`test-summary.json` 在工具可读取结果时保存测试摘要。日志位于同级 `logs/`；失败时仍尝试导出已有截图、保存已有日志，然后保留原测试失败状态。测试成功但截图导出失败或没有 PNG 时，不继续打包 IPA。GitHub artifact 保留 7 天，不能作为账本备份。

截图使用 [Apple 在 Xcode 16 起提供的 `xcresulttool export attachments` 命令](https://developer.apple.com/documentation/xcode-release-notes/xcode-16_3-release-notes)。脚本同时保存当前固定 Xcode 的 `help export attachments` 输出；具体截图内容与导出结果须以首次包含 UI 测试的云端运行确认。

## Windows 签名与设备验证

未签名 IPA 不能直接在普通 iPhone 上运行。下载成功产物后在 Windows 使用用户自己的 Sideloadly／Apple 账号签名安装，密码与签名凭据不交给 GitHub Actions。第一次安装只用合成数据，验证启动、记账、重启、覆盖安装后数据保留；真实续签及到期恢复必须记录发生日期，不能用首次安装代替。

本批包含主 App、AppTests 与单条 UI smoke test；尚未添加 Widget target、App Groups、NAS、iCloud、后台传输或相关权限。后续按分项 P0 证据扩展。实际机型／iOS 版本以用户设备显示为准；模拟器机型只是云端测试条件。

## 验证记录

- Windows 核心测试：以本轮实际命令输出为准；此页不预填通过次数。
- 2026-09-26，[云端运行 #3](https://github.com/Vince599/Money/actions/runs/36212521636)（提交 `073742da04b90498938dccf703d2693a0e50caeb`）：macOS 包测试 84 项／8 个 suite 通过，iOS 模拟器 AppTests 7 项通过，Release `iphoneos` arm64 构建成功并生成未签名 IPA。实际编译器为 Apple Swift 6.3.3，产物为 `ledger-ios-3`（artifact ID `10896510760`）。
- 新增 `LedgerUITests`、UI 截图附件导出及 PNG 检查：不包含在运行 #3，待后续云端运行验证。
- 免费侧载、覆盖升级、续签与过期恢复：待真机验证。
- 家庭 fnOS、iCloud 目录与 Widget：本批未实现、未验证。
