# Ledger 构建与验证

当前仓库已在 GitHub 的 macOS runner 完成包测试、iOS 模拟器 App 测试和未签名 IPA 构建。本地 Windows 负责核心测试；用户已反馈此前版本在 iOS 27 真机上安装及基础记账、重开、导出恢复成功，覆盖更新仍待验证。具体运行、版本与验证边界见本页末尾。

## 当前已验证的固定基线

主要体验目标已更新为用户当前 iOS 27 真机。下表记录实际采用过的构建基线；最新稳定工具链目标、升级流程和性能证据要求见[原生体验与工程质量标准](EXPERIENCE_QUALITY.md)。配置已精确固定 Apple Swift 6.3.3 并增加只读探测入口；云端运行 #29 已按该基线完成当前完整 Apple 自动回归，尚未切换到 Xcode 27。

| 项目 | 固定值 |
|---|---|
| App / scheme | `Ledger` |
| AppTests target | `LedgerAppTests` |
| UI test target | `LedgerUITests`；使用隔离的 DEBUG 测试账本 |
| 本地 Swift package | `Ledger`；产品 `LedgerCore`、`LedgerStore` |
| Bundle ID | `app.vince.ledger`；测试为 `app.vince.ledger.tests` |
| 最低系统 | iOS 26.0，仅 iPhone |
| macOS 包测试最低系统 | macOS 15.0；核心累加使用 Int128，符合其系统可用版本 |
| GitHub runner | `macos-26`，arm64 |
| 核查时的 runner 镜像 | `20260907.0351.1`；它是观察记录，不能通过 runner 标签冻结 |
| Xcode | 26.6，build `17F113`，`/Applications/Xcode_26.6.app` |
| Swift | 实测 Apple 编译器 6.3.3、Swift 6 语言模式；本机 Windows 已观察到 6.4 |
| SDK / 模拟器运行时 | iOS 26.5 |
| XcodeGen | 2.46.0，官方 ZIP 的 SHA-256 固定在 `config/toolchain.json` |
| GRDB | 7.11.1，由根 `Package.swift` 精确依赖 |

2026-09-26 核查的官方依据：[runner 软件清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)、[Apple Xcode 兼容表](https://developer.apple.com/xcode/system-requirements/)、[XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0)、[GRDB 7.11.1](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1)。Apple 当前已列出稳定 Xcode 27／iOS 27 SDK／Swift 6.4；上表为现有链路的实际组合，不再作为长期目标。下一步核实可运行新工具链的稳定 macOS 环境，完成升级回归后重新固定版本；不能因 runner 预装较旧版本而无限期推迟，也不自动换用测试版工具。

可追溯的 [runner 清单固定提交](https://github.com/actions/runner-images/blob/0af81b6d930d02b52941d584bee9214c4bc228c6/images/macos/macos-26-arm64-Readme.md) 记录镜像 `20260907.0351.1`，其 Xcode 表明确列出 26.6（默认）、build `17F113` 和 `/Applications/Xcode_26.6.app`，SDK 表列出配套 iOS 26.5。这是固定配置存在于官方镜像的依据，不是本项目已在该镜像构建成功的证据。

`macos-26` 固定的是系统系列，GitHub 仍会更新镜像。脚本校验 Xcode 版本、build 和 iOS SDK；缺少固定工具或模拟器就失败，不回退到 `latest`。每次保存实际镜像、编译器、工具版本和测试日志。工具升级需要同步 `config/toolchain.json`、`project.yml` 及本页，并重新验证。

升级时还需检查 `Package.swift` 的平台／工具要求、依赖锁与脚本中的固定运行时，验证 Swift 6 严格并发、包／App／UI 回归及 arm64 Release 产物，随后完成真机覆盖安装与核心体验对照。编译 SDK、最低部署版本、模拟器运行时分别记录；以新 SDK 构建不要求机械提高最低部署版本。历史构建证据保留，缺少新版证据时仍标为“升级待验证”。

### Xcode 27 环境核查与探测

2026-09-27 分类图标批次开工时再核对 [Apple 兼容表](https://developer.apple.com/xcode/system-requirements/)及 [macos-26 arm64 清单](https://raw.githubusercontent.com/actions/runner-images/main/images/macos/macos-26-arm64-Readme.md)：Apple 仍列出稳定 Xcode 27；当前 runner 清单的最新预装稳定版本为 Xcode 26.6（17F113），镜像 `20260907.0351.1`。本批继续固定回归基线，未切换 SDK；公开清单核对不当作目标工具链的实际执行证据。

2026-09-26 再次核对：Apple 支持表列出的稳定 Xcode 27 要求宿主 macOS 26.6 或更新版本，配套 iOS 27 SDK 与 Swift 6.4。当前 [macos-26 arm64 官方清单](https://raw.githubusercontent.com/actions/runner-images/main/images/macos/macos-26-arm64-Readme.md)返回 macOS 26.6.2、镜像 `20260907.0351.1`，已安装 Xcode 表最高稳定版仍为 26.6；宿主满足要求不代表已安装 Xcode 27。[xcode-27 runner 公告](https://github.com/actions/runner-images/issues/14404)明确为预览环境，其示例仍包含 beta 版本，不能据此固定稳定工具 build。

在可用 Mac／runner 上先运行只读探测：

```bash
bash scripts/probe-apple-toolchain.sh
# 也可显式指定已安装的 Xcode：
bash scripts/probe-apple-toolchain.sh /Applications/Xcode_27.app
```

JSON 输出包含宿主、已安装 Xcode 的精确版本／build、Swift、SDK 和模拟器运行时，各命令错误保留在对应字段。脚本不下载安装、不构建、不启动设备、不修改全局 `xcode-select`；退出成功仅说明完成了安装目录探测，不代表每个工具可用或 App 已验证。Windows 调用会明确拒绝。

如兼容宿主尚未安装稳定工具，使用 [Apple 官方安装入口](https://developer.apple.com/xcode/resources/)准备环境，再探测、更新固定配置并完整回归。尚未在远端执行新增的 Xcode 27 探测入口或下载 Xcode，故保留当前已验证的构建版本；运行 #11 核对并使用的是已固定的 Xcode 26.6，不能把网络清单当成新工具链执行证据。App 性能插桩的编译证据及待测范围见[性能基线](PERFORMANCE_BASELINE.md)。

核心在内存中用 Int128 累加分录，再检查 Int64 可存储范围；[Apple Int128 文档](https://developer.apple.com/documentation/swift/int128)标明 macOS 15.0／iOS 18.0 起可用。包的 macOS 最低版本因此为 15.0，App 仍为 iOS 26.0；这项配置核对不替代实际 Apple 平台编译。

Bundle ID 是后续覆盖安装和数据保留测试的固定基线，不能为消除签名错误随手更名。若安装工具重签时映射标识，应记录有效标识并在以后沿用；更换账号、标识或安装为另一 App 前先导出数据并明确迁移，不承诺自动继承原容器。

## Windows：运行纯 Swift 领域测试

在仓库根目录的 PowerShell 执行：

```powershell
./scripts/test-core.ps1
./scripts/test-core.ps1 -Configuration release
```

默认筛选 `LedgerCoreTests`，脚本显示实际 Swift 版本并将失败作为非成功结果返回。Swift 安装、Windows SDK 和 C++ 构建工具由现有环境提供，脚本不会安装软件或改系统设置。领域包不应导入 SwiftUI、WidgetKit、GRDB 或 iOS Keychain；Windows manifest 应只包含可移植的核心与其测试。

Windows SwiftPM 6.4 会预取根 `Package.resolved` 中的 Apple 依赖，即使 manifest 已按平台排除；GRDB checkout 的符号链接会在本机权限条件下失败。Windows 脚本因此将原始 `Package.swift`、`Sources/LedgerCore` 与 `Tests/LedgerCoreTests` 原样同步到 `build/windows-core`，在不含 Apple 锁的隔离目录执行同一套核心测试；镜像每次移除旧 Swift 源文件，避免已删除测试残留。根锁保持原位且不改写。macOS 仍直接在原项目执行全量包测试。

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

根 `Package.resolved` 已由首次 macOS 解析生成、核对并提交。Windows 的核心-only manifest 不能代替 Apple 依赖锁；后续解析或依赖升级造成的锁变化应审查后提交，不手写未验证的锁文件。

项目远端为 [Vince599/Money](https://github.com/Vince599/Money)。工作流仅接受 `workflow_dispatch` 手动触发，没有 push、PR、定时触发和发布步骤。将代码及工作流同步到仓库后，在 Actions 中选择 **iOS validation and unsigned IPA**，手动选择要验证的分支运行。配置文件存在不代表已经推送、触发或构建成功，应以具体运行记录为准。首次使用私有仓库前核对其 Actions 配额与付费设置。

首次注册手动工作流时，`.github/workflows/ios.yml` 必须已存在于仓库默认分支；之后可选择其他分支运行。仅将新增工作流推到非默认分支，不能保证出现手动运行入口。参见 [GitHub 手动运行工作流说明](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)。

成功产物位于 `build/ios/<时间戳>/artifacts/`，包括 `Ledger-unsigned.ipa`、SHA-256、实际依赖锁、工具基线、构建元数据和测试结果。`screenshots/` 保存导出的 PNG 与附件清单，可从下载的 artifact 直接查看；`test-summary.json` 在工具可读取结果时保存测试摘要。日志位于同级 `logs/`；失败时仍尝试导出已有截图、保存已有日志，然后保留原测试失败状态。测试成功但截图导出失败或没有 PNG 时，不继续打包 IPA。GitHub artifact 保留 7 天，不能作为账本备份。

截图使用 [Apple 在 Xcode 16 起提供的 `xcresulttool export attachments` 命令](https://developer.apple.com/documentation/xcode-release-notes/xcode-16_3-release-notes)。脚本同时保存当前固定 Xcode 的 `help export attachments` 输出；运行 #4 实际导出 3 张截图，第三批运行 #9 导出 5 张，账户模板整合运行 #19 导出 6 张。

## Windows 签名与设备验证

未签名 IPA 不能直接在普通 iPhone 上运行。下载成功产物后在 Windows 使用用户自己的 Sideloadly／Apple 账号签名安装，密码与签名凭据不交给 GitHub Actions。第一次安装只用合成数据，验证启动、记账、重启、覆盖安装后数据保留；真实续签及到期恢复必须记录发生日期，不能用首次安装代替。

当前包含主 App 内的两个快捷记账动作、AppTests 与四条 UI 操作测试：基础入账重开，计算器／复制／搜索筛选，运营商账户模板切换与重启持久化，以及退款原额／净花费／明确整组删除。快捷动作与页面共用主 App 数据入口，未添加单独扩展；系统发现及前台／后台／锁屏行为须按[快捷指令清单](SHORTCUTS.md)实测。尚未添加 Widget target、App Groups、NAS、iCloud、后台传输或相关权限。后续按分项 P0 证据扩展。实际机型／iOS 版本以用户设备显示为准；模拟器机型只是云端测试条件，各轮真实通过情况见以下记录。

## 固定安装包目录

当前开发阶段暂不交付中间安装包、不更新固定目录，也不要求用户逐轮安装。先完成计划内功能和完整流程；待开发完成或用户明确要求安装验证时，再执行本节发布步骤。云端自动验证可继续生成内部构建产物，这不表示已向用户交付或已更新本机最新版。

Windows 真机安装统一使用工作区以外的 **`D:\Data\Ledger-Install\Ledger-latest.ipa`**。每次成功交付后更新此文件，用户无需再从不同的构建目录中找包；桌面“Ledger Install”快捷方式指向该目录。

完成云端构建、下载并核验产物后执行：

```powershell
./scripts/publish-ipa.ps1 -ArtifactsDirectory 'build/validation/run-19-artifact/20260927T105703Z/extracted/20260927T024338Z-42280/artifacts'
```

上面是运行 #19 的已执行示例，后续传入对应构建的 `artifacts` 目录。脚本核对 IPA 的 SHA-256、成功构建状态、arm64 与源码提交，保留按构建时间和提交命名的 `history` 版本，再从同目录临时文件原子替换 `Ledger-latest.ipa`；文件被占用或复制失败时不会先删除旧 IPA。目录内的 `latest.json` 和 `安装说明.txt` 记录构建时间、提交、运行 ID、大小及哈希，它们分别更新，不与 IPA 构成多文件原子事务。更旧的构建不能覆盖最新版，也不自动清理历史。

这一步是每次交付的固定流程，见根目录 `AGENTS.md`；仅云端构建成功不会自动写入本机磁盘，必须下载后执行脚本并确认成功。主工作区和其他 worktree 共用此位置，不将安装包提交到 Git。文件仍未签名，需用户在 Sideloadly 中签名安装；自己的签名输出另存，避免后续更新覆盖。

## 验证记录

- 体验与版本政策：2026-09-26 新增[体验质量标准](EXPERIENCE_QUALITY.md)，要求最新稳定原生技术和分阶段体验验收；Xcode 27 升级、Q01—Q09 真机性能及完整 Widget 品质均尚未验证。模拟器截图和基础安装成功不能代替这些证据。
- Windows 核心测试：2026-09-27 当前 Swift 6.4 实测 151 项／15 个套件通过；历史第三批基线为 106 项／10 个套件。
- 2026-09-26，[云端运行 #3](https://github.com/Vince599/Money/actions/runs/36212521636)（提交 `073742da04b90498938dccf703d2693a0e50caeb`）：macOS 包测试 84 项／8 个 suite 通过，iOS 模拟器 AppTests 7 项通过，Release `iphoneos` arm64 构建成功并生成未签名 IPA。实际编译器为 Apple Swift 6.3.3，产物为 `ledger-ios-3`（artifact ID `10896510760`）。
- 2026-09-26，[云端运行 #4](https://github.com/Vince599/Money/actions/runs/36212928265)（提交 `c5ba22d45f000a611cb2dd57293b2537ae6c1366`）：在前述 84 项包测试、7 项 App 测试之外，通过 1 项 UI 操作测试；新增账户与支出、重启后数据保留、备份入口均验证通过，导出截图并生成同版未签名 IPA。UI 测试未操作系统文件选择器或执行页面恢复。
- 运行 #4 的 [完整产物](https://github.com/Vince599/Money/actions/runs/36212928265/artifacts/10896293141)为 `ledger-ios-4`；IPA 为 3,059,852 字节，SHA-256 `fdd7f69b98079e46ae1598a7fe193e0a16a5d1aee3aabfcb6da5480b0de78132`，已下载核对一致。3 张截图来自 iPhone 17 Pro Max／iOS 26.5 模拟器，分辨率 1320×2868，内容为重启后首页、账户页及备份入口。
- 2026-09-26，[云端运行 #9](https://github.com/Vince599/Money/actions/runs/36218393077)（提交 `d778e373dd1cdd568492400d2acc9e87610ccaae`）：第三批 macOS 包测试 118 项／11 个 suite、iOS AppTests 8 项、UITests 2 项全部通过，Release arm64 构建成功。新增页面测试验证算式 `10+5.05*2` 得到 20.10、复制形成两笔独立流水后余额 59.80、大小写搜索、无结果状态、最低金额 20.11 排除两笔 20.10 流水，以及清除筛选后恢复两笔记录。5 张命名截图包含前三个基础页面、计算器和复制后的搜索列表。
- 运行 #9 的[完整产物](https://github.com/Vince599/Money/actions/runs/36218393077/artifacts/10898635666)为 `ledger-ios-9`，已下载并核对：IPA 为 3,218,468 字节，SHA-256 `9ae789b9433ad5994ec068ee14b07ff354060cceef2f0c429c6aeb71453a5f1e`。测试摘要为 iPhone 17 Pro Max／iOS 26.5（23F77），10 项 App／UI 测试零失败、零跳过；其余 118 项见包测试日志。新增计算器和搜索截图已查看，未发现当前合成数据下的遮挡或文字截断。此包尚未进行真机覆盖安装验证。
- 2026-09-26，[云端运行 #10](https://github.com/Vince599/Money/actions/runs/36221607153)（提交 `664e7d2c1dd3616c69fa7df6ea6546f5cd1ce809`）通过 135 项 macOS 包测试／13 套件，随后因缺少配置所指的 `AppIcon` 集而在资源编译失败，App／UI 测试未执行、未生成 IPA。失败日志保留；补入并行任务已制作的 AppIcon 后重新完整验证。
- 2026-09-26，[云端运行 #11](https://github.com/Vince599/Money/actions/runs/36221886418)（分支 `codex/incremental-entry-validation`，提交 `44ef8b11da2bc84764f98e33286b9b4e5a5a47fa`）全部成功：135 项 macOS 包测试（112 Core＋23 Store，13 套件）、12 项 AppTests、2 项 UITests，共 149 项。新增回归覆盖普通新建／编辑增量事务、草稿序号、防重、故障回滚及旧数据兼容；性能插桩和新增图标资源通过 Apple 编译。实际工具为 Xcode 26.6（17F113）、Apple Swift 6.3.3、iOS 26.5 SDK；模拟器为 iPhone 17 Pro Max／iOS 26.5（23F77），runner 镜像 `20260907.0351.1`。
- 运行 #11 的[完整产物](https://github.com/Vince599/Money/actions/runs/36221886418/artifacts/10898673854)为 `ledger-ios-11`。已下载至 `build/validation/run-11-artifact/20260926T054837Z-8946/`，核对下载 ZIP 的 GitHub 摘要及 IPA 随附清单：IPA 为 **5,838,918 字节**，SHA-256 `6bc108000240aab9fe08c5a70d0ef3563dc5d1e1f230a65a295b0eae0e12519d`。测试摘要记录 14 项 App／UI 测试零失败、零跳过；5 张 1320×2868 截图（首页、账户、备份入口、计算器、搜索）已查看，当前合成数据下未见遮挡或截断。
- 运行 #11 验证的是固定快照，包括普通记账增量事务、性能插桩、账户模板素材和 AppIcon；随后并行新增的快捷记账代码不在此提交中。原工作区 `main` 与暂存区未由本批提交或重置。该 IPA 尚未真机安装验证，Instruments trace、性能指标及最终 UI 仍待专项验收。
- 2026-09-26，[云端运行 #12](https://github.com/Vince599/Money/actions/runs/36224785602)（`codex/incremental-entry-validation`，提交 `f50dd055e6662932c40de56adc6095617ac160bf`）全部成功：145 项包测试（112 Core＋33 Store，14 套件）、16 项 AppTests、2 项 UITests，共 **163 项**。本批只在上一验证快照增加 5 个代码／测试文件，覆盖一致快照、启动去重和相应回归；保留普通保存与备份恢复测试。实际工具仍为 Xcode 26.6（17F113）、Apple Swift 6.3.3，runner 镜像 `20260907.0351.1`，完成 arm64 Release 构建。
- 2026-09-27 完成运行 #12 的[完整产物](https://github.com/Vince599/Money/actions/runs/36224785602/artifacts/10900386916)核对：`ledger-ios-12` 的 ZIP 为 113,682,285 字节，SHA-256 `02663953656b10d19f245ac477f66c9ee2802f0242f33406487305cf3129fa31` 与 GitHub 摘要一致；安全解压至 `build/validation/run-12-artifact/20260926T064703Z-4677/`。IPA 为 **5,843,152 字节**，SHA-256 `f41ae9389f1cf6703253af078d52c98658210ddd0ff08a3a906a8e4ba4c46b56` 与随附清单一致，构建元数据的源码提交与本次运行匹配。测试摘要确认 iPhone 17 Pro Max／iOS 26.5（23F77）上 18 项 App／UI 测试零失败、零跳过；5 张 1320×2868 截图（首页、账户、备份入口、计算器、搜索）已查看，当前合成数据下未见遮挡或截断。
- 运行 #12 同样不包含并行快捷记账代码及其启动协调变更。原工作区已用最小补丁接入本批工厂与读取 API，保留快捷入口；两者整合后的完整 Apple 回归随后记入运行 #15。整本读取仍存在，尚未进行本版本的真机安装、Instruments trace 或性能验收。
- 2026-09-27，[云端运行 #13](https://github.com/Vince599/Money/actions/runs/36283696910)（提交 `6418ee3fdd2ce90c7bd68bedc6e40bf400e9462f`）在新增首页摘要测试的复杂表达式处触发 Apple Swift 6.3.3 类型推断耗时错误；包测试未执行完成，App／UI 测试未运行，未生成 IPA。拆分测试表达式后重新执行完整构建。
- 2026-09-27，[云端运行 #14](https://github.com/Vince599/Money/actions/runs/36283853854)（`codex/incremental-entry-validation`，提交 `c59628f73f9c32005ae125762f8e8dd0e792ff04`）全部成功：157 项包测试（124 Core＋33 Store，15 套件）、30 项 AppTests、2 项 UITests，共 **189 项**。新增回归覆盖首页分币种汇总、金额边界、最近五条、上海月界、延迟刷新、草稿保护，以及保存／编辑／删除／目录修改／更正／恢复后的摘要一致性；工具链仍为 Xcode 26.6（17F113）／Apple Swift 6.3.3，完成 arm64 Release 构建。
- 运行 #14 的[完整产物](https://github.com/Vince599/Money/actions/runs/36283853854/artifacts/10920231592)为 `ledger-ios-14`，已下载并核对：ZIP 为 113,072,281 字节，SHA-256 `291c7449a24b115b8ea3414227dbd381b801aad4b4bac9d432fed04f85478def` 与 GitHub 摘要一致；解压至 `build/validation/run-14-artifact/20260927T005331Z-7609/`。IPA 为 **5,870,993 字节**，SHA-256 `573816d47a7efa7384ab77da89a57d0b36b4018fd671159aa9dd158d08d1245f` 与随附清单一致，元数据提交及 run ID 匹配。摘要确认 iPhone 17 Pro Max／iOS 26.5（23F77）上 32 项 App／UI 测试零失败、零跳过；5 张 1320×2868 截图已查看，首页余额 79.90／消费 20.10 与合成账本一致，当前场景未见遮挡或截断。
- 运行 #14 固定快照包含该轮首页优化，不含并行快捷指令记账。原工作区保留这些入口并接入首页摘要；合并后的 Apple 回归记录见运行 #15。运行 #14 对应的本机完整 Core 为 133 项／13 套件（含快捷请求的 9 项），不可与该 Apple 快照的包测试总数直接混比；原主分支与暂存区保持原状。
- 2026-09-27，[云端运行 #15](https://github.com/Vince599/Money/actions/runs/36285466571)（`codex/incremental-entry-validation`，提交 `fbbe3d03f61d2df6c83fc731802e47d8e65f2a7b`）全部成功：166 项包测试（133 Core＋33 Store，16 套件）、39 项 AppTests、2 项 UITests，共 **207 项**。本轮把快捷记账、共享启动、弹窗协调及首页摘要整合进同一固定快照；新增两项回归确认快捷保存后旧首页结果／错误不会覆盖新状态和手动草稿。Xcode 26.6（17F113）／Apple Swift 6.3.3 完成 arm64 Release 构建，runner 镜像仍为 `20260907.0351.1`。
- 运行 #15 的[完整产物](https://github.com/Vince599/Money/actions/runs/36285466571/artifacts/10920687143)为 `ledger-ios-15`，已下载并核对：ZIP 为 112,238,100 字节，SHA-256 `7a036f9a8ee083624abc458c37391f76fa1a2bd9b9dcd122a42039c0dd9e9caa` 与 GitHub 摘要一致；解压至 `build/validation/run-15-artifact/20260927T012516Z-1823/`。IPA 为 **6,008,239 字节**，SHA-256 `0e2b132c2c55edfec72efd71a5439e5be88bddebac28157acebb5c17013d8cb3` 与随附清单一致，元数据源码提交与 run ID 匹配。测试摘要确认 iPhone 17 Pro Max／iOS 26.5（23F77）上 41 项 App／UI 测试零失败、零跳过；5 张 1320×2868 截图已查看，当前合成场景未见遮挡或截断。
- 运行 #15 的 IPA 内已核对 `Metadata.appintents/extract.actionsdata` 与 `root.ssu.yaml`，确含“直接记一笔”“准备记一笔”、账户／分类／主体实体与查询、三个中文短语；元数据版本 3.0、工具 build `17F113`。这不证明系统动作已索引或真实后台执行通过。主 App 三处同步 `requestValue` 重载出现弃用警告，另有既有无实际异步的 `await` 与屏幕方向警告；构建及测试成功，不称为零警告构建。签名覆盖安装、系统快捷指令、最终视觉和 Instruments／真机性能仍待验证。核对记录保存在 `build/validation/run-15-verified.json`，原工作区 `main` 与暂存区未由本批提交或重置。
- 2026-09-27，[云端运行 #16](https://github.com/Vince599/Money/actions/runs/36288358797)（提交 `b788d739106d78177077ecd9c5a7caa3f970dd72`）在 Apple Swift 6.3.3 编译 Store 测试时失败：`Set.isDisjoint` 在该工具链要求显式 `with:` 参数标签。包、App 和 UI 回归未完整执行，未生成 IPA；补兼容写法后重跑。
- 2026-09-27，[云端运行 #17](https://github.com/Vince599/Money/actions/runs/36288471471)（提交 `68d6a12ba043301e3da7cf47653e9a26532ca2fd`）继续在 Store 测试编译阶段失败：抛出的 GRDB `Data.fetchOne` 调用嵌入 `#require` 宏，Apple Swift 6.3.3 无法编译。将读取与断言拆开后重新完整执行；本轮同样未生成 IPA。
- 2026-09-27，[云端运行 #18](https://github.com/Vince599/Money/actions/runs/36288574926)（提交 `e2f9ead3716653b3abd3c64b740d57c594264c29`）通过 173 项包测试／16 套件及 39 项 AppTests；3 项 UITests 中 2 项通过，账户模板用例因键盘焦点下的通用元素点击落在汇总开关左侧而失败。测试摘要为 42 项中 41 通过、1 失败、0 跳过；整轮失败且未生成可交付 IPA。后续提交只调整 UI 测试：明确定位开关、点击右侧控制区域并等待值变为 1，产品代码没有变化。
- 2026-09-27，[云端运行 #19](https://github.com/Vince599/Money/actions/runs/36289340271)（提交 `de6889a9757a8c29100f02dfcfad746fc2edff08`）全部成功：173 项包测试／16 套件、39 项 AppTests、3 项 UITests，共 **215 项**，零失败、零跳过。新增 UI 路径验证 10086 中国移动话费默认不计汇总、用户修改名称与汇总设置后切换 10010 中国联通、保存并重启仍保留模板。Xcode 26.6（17F113）／Apple Swift 6.3.3、iOS 26.5 SDK、XcodeGen 2.46.0 和 GRDB 7.11.1 完成 arm64 Release 构建；runner 镜像为 `20260907.0351.1`。
- 运行 #19 的[完整产物](https://github.com/Vince599/Money/actions/runs/36289340271/artifacts/10921873775)为 `ledger-ios-19`。ZIP 为 134,721,689 字节，SHA-256 `1b58022a0826e6dce39de7c007ced48d957a907960cfc0514ca775fb2b251c7f`，与 GitHub 摘要一致；安全解压至 `build/validation/run-19-artifact/20260927T105703Z/extracted/20260927T024338Z-42280/`。IPA 为 **6,070,693 字节**，SHA-256 `70738ddf9095a830721e2ddc1f2a1b312da736505438b0bcc20e7db44b6cfcb7`，与随附清单一致；元数据的提交、运行 ID、arm64 和成功状态均匹配。IPA 含 `Payload/Ledger.app`、可执行文件、`Info.plist`、`Assets.car` 与 App Intents 元数据，不含 provisioning profile。
- 运行 #19 的测试摘要确认 iPhone 17 Pro Max／iOS 26.5（23F77）上 42 项 App／UI 测试全部通过。6 张 1320×2868 截图已查看；新增账户模板截图显示中国联通原色图标、自定义名称和汇总开关在重启后保留，当前合成场景未见阻断性布局问题，交互结果由 UI 测试断言确认。构建仍有既有的三处 `requestValue` 弃用、一个无实际异步的 `await`、屏幕方向、多目标目的地及模拟器 App Intents 元数据跳过警告，日志无编译错误，不能称为零警告构建。
- 运行 #19 已通过 `scripts/publish-ipa.ps1` 发布到 **`D:\Data\Ledger-Install\Ledger-latest.ipa`**；固定文件、历史文件 `history\20260927T025604Z-de6889a975\Ledger-unsigned.ipa` 与云端 IPA 的字节数和 SHA-256 三方一致，`latest.json` 和 `安装说明.txt` 均记录运行 ID `36289340271`，核对摘要保存在忽略目录的 `build/validation/run-19-verified.json`。该文件仍未签名，`deviceInstallation` 为 `not verified`；用户需在本地签名后完成 iOS 27 覆盖、profile 2 恢复、账户模板视觉和新增功能真机验证。
- 2026-09-26，用户反馈此前提供版本在 iOS 27 真机签名安装成功：新建“真机测试”账户期初 100.00 元、本月消费 0；记录 20.10 元餐饮／正餐支出后余额 79.90 元、消费 20.10 元且只有一笔流水；强制退出重开后保留；完整 ZIP 可导出到系统“文件”；再支出 5.00 元后恢复原 ZIP，余额从 74.90 元回到 79.90 元且恢复一笔流水。精确 iOS build、已安装包哈希未取得，证据类型为用户反馈；不能作为第三批新增功能的真机测试结果。
- 覆盖升级、续签与过期恢复：待真机验证。模拟器结果仍为 iOS 26.5；上述 iOS 27 基础人工验证不代表全量兼容性验收。
- 家庭 fnOS、iCloud 目录与 Widget：本批未实现、未验证。

### 流水分页验证过程（内部构建）

运行 [#20](https://github.com/Vince599/Money/actions/runs/36291175203)（`ebba131`）在新增 Store 回归中发现关键字内嵌零字符经过 SQL TEXT 桥接丢失，以及跨连接创建索引后检查连接仍使用旧 schema 的查询计划断言问题。改为 UTF-8 BLOB 参数、使用新连接检查实际索引后重跑。运行 [#21](https://github.com/Vince599/Money/actions/runs/36291309859)（`c81a236`）因测试诊断引用了错误作用域变量而编译失败；修正后运行 [#22](https://github.com/Vince599/Money/actions/runs/36291335912)（`722268f`）通过 180 项包测试／17 套件，但 App 测试的 continuation gate 缺少 MainActor 隔离声明，Swift 6 严格并发编译拒绝。

运行 [#23](https://github.com/Vince599/Money/actions/runs/36291479135)（`356df6e`）通过 180 项包测试和 45 项 AppTests；账户模板 UI 用例通过，但搜索用例在输入 `Lunch` 后立即读取到 `Lunc`，随后该轮因已有更新提交而取消，不能标为整轮通过。补充关键字原始 Unicode 编码的请求身份比较后，运行 [#24](https://github.com/Vince599/Money/actions/runs/36291734137)（`582f30e`）也因进一步改善搜索列表稳定性而取消。最终改为搜索期间保留列表、区别请求中与已完成的筛选，增加取消后重进测试，并让 UI 输入断言等待精确值稳定；没有通过反复补打字符掩盖输入问题。以上各轮均未交付安装包，也未更新固定目录。

最终运行 [#25](https://github.com/Vince599/Money/actions/runs/36291987191) 验证提交 `7096e27c8c7060429637a23dff058c8007c4b394`，181 项包测试／17 套件、46 项 AppTests、3 项 UITests 共 230 项全部通过，无失败或跳过；iPhone 17 Pro Max 模拟器为 iOS 26.5（23F77）、arm64。Release 真机构建成功，仅作为内部产物，未进行本轮真机安装。

Windows 已下载并核对 [ledger-ios-25 构建产物](https://github.com/Vince599/Money/actions/runs/36291987191/artifacts/10922463802)：ZIP 大小 137,577,723 字节，SHA-256 `de8afc05b9e56d0520a57d3e5f3fe5ccad1941688b1544e39a0e8198f34dc3e6` 与 GitHub 元数据一致；构建记录中的源码和运行编号匹配。只提取测试摘要、构建记录和截图用于内部核对，未提取或发布 IPA。已逐张查看六张 1320×2868 截图，覆盖账户模板编辑、金额计算器、两笔搜索结果、首页、账户与备份入口；这些合成场景的主要内容可见，无新增遮挡，不能代替深浅色、大字号、全部品牌或真机体验验收。核对记录保存在忽略目录 `build/validation/run-25-internal/review/review.json`。

按用户最新安排，本轮未运行 `publish-ipa.ps1`，固定安装目录仍保留运行 #19；后续计划内功能和完整流程开发完成，或用户明确要求安装验证时，再执行正式交付步骤。

### 退款与回收验证过程（内部构建）

运行 [#26](https://github.com/Vince599/Money/actions/runs/36293964201)（`502119f`）停在新增 Store 测试的编译阶段：Swift Testing 宏内的抛出表达式不能为外层 GRDB 闭包自动推断 `throws`，已显式标注。运行 [#27](https://github.com/Vince599/Money/actions/runs/36294155512)（`0d19b29`）通过 194 项包测试／19 套件（147 Core＋47 Store），随后 App 编译在 `EntryEditor` 金额说明的长字符串表达式处触发类型推断超时。已将金额说明、原购买标题及账户标题拆为普通属性／函数，运行 #28 继续完整回归。以上失败运行均没有完整通过结论，也没有交付安装包或更新固定目录。

运行 [#28](https://github.com/Vince599/Money/actions/runs/36294320403)（`9a98c3f`）通过 194 项包测试和 48 项 AppTests，四项 UI 测试中两项失败。复制用例在半屏详情中以尚未被 List 懒加载的“编辑”按钮查找滚动容器，无法定位；退款用例已完成记账、原额与净花费检查，但点击整组开关时落在外层辅助文字，开关保持关闭。已依据日志中的实际 AX 层级改为最上层呈现列表，并点击开关实际控件所在的尾部区域；保留原有金额、默认关闭、开启和删除后余额断言，未放宽校验。运行 #29 继续验证该测试定位修正。

最终 [运行 #29](https://github.com/Vince599/Money/actions/runs/36295019551)在提交 `55216aa0f24ce8dc7d4eb154e8f43373fa6944f9` 上通过 **194 项包测试／19 套件（147 Core＋47 Store）、48 项 AppTests 和 4 项 UITests，共 246 项**，无失败或跳过。模拟器为 iPhone 17 Pro Max／iOS 26.5（23F77）、arm64，Release 真机构建成功；本轮没有真机安装。仍有既有的 App Intents `requestValue` 弃用、无实际异步的 `await`、屏幕方向及模拟器元数据提示，不称为零警告构建。

Windows 已下载并核对 [ledger-ios-29 内部产物](https://github.com/Vince599/Money/actions/runs/36295019551/artifacts/10923478989)：ZIP 为 **161,469,921 字节**，SHA-256 `6b2265e1ca155100c188329f36310eb15a3a690291e61ee0cb3d16f3771f9b33` 与 GitHub 摘要一致；构建元数据的源码提交、运行编号、arm64 和成功状态均匹配。只提取测试摘要、构建记录及截图，未提取或发布 IPA；核对记录保存在忽略目录 `build/validation/run-29-internal/review/review.json`。

已逐张查看九张 1320×2868 截图，包括原有六个页面和新增退款流水、净花费、整组删除影响。原购买保持 1,000，退款 200，净花费 800；删除预览列出两笔及账户 1,200→2,000，相关金额未截断。删除列表原购买行因禁用跳转而呈浅灰，需在视觉专项中改为可读的静态行；其余字号、对齐、深浅色、大字号及真机体验也不因本次截图检查而视为验收完成。按用户安排未运行发布脚本，固定目录仍保留运行 #19。

### 分类图标验证过程（内部构建）

用户在本批明确暂停预算开发，已同步开发约定、路线图及 Widget 范围；预算规则保留为延期设计，日常个人消费仍继续计算。分类图标代码复用既有 `symbol` 字段，未升级 schema 或备份格式；实现范围见 [CATEGORY_ICONS.md](CATEGORY_ICONS.md)。

[运行 #30](https://github.com/Vince599/Money/actions/runs/36297022152)验证 `7fce7329b051e5a51aab428181d0b0b081c2e393`：198 项包测试／20 套件（151 Core＋47 Store）和 51 项 AppTests 全部通过；5 项 UITests 中账户模板及新增图标编辑路径通过，另三项失败。日志的可访问性树中，原生分类菜单只暴露“请选择分类”，自定义图标视图对应的条目没有可操作元素，导致测试无法选择普通消费分类。这是产品菜单兼容问题，未通过放宽测试或换点击位置绕过；提交 `eb64361048154da6c7d5e71200f0fa1bf568f1e1` 改回标准 `Label(title, systemImage:)` 并继续使用共享回退函数，本地语法解析通过。该轮没有成功 Release 构建，也未交付 IPA。

已下载并核对 [运行 #30 内部产物](https://github.com/Vince599/Money/actions/runs/36297022152/artifacts/10924571331)：ZIP 为 245,985,247 字节，SHA-256 `96d182bf04752a317a544e6161e91a339233ea6a4c5e1ab3b5514b1ca7ddc0c9` 与 GitHub 摘要一致，提交匹配。只提取测试摘要和截图；四张 1320×2868 截图均已查看，新增图标搜索／预览、重启后的已保存图标显示完整；另有账户模板和计算器截图。没有取得修正后删除预览的截图，不能据此确认该视觉修正已验收。产物和核对记录在忽略目录 `build/validation/run-30-internal/`。

[运行 #31](https://github.com/Vince599/Money/actions/runs/36297737190)尝试验证菜单修复提交 `eb64361048154da6c7d5e71200f0fa1bf568f1e1`，但 GitHub 在分配 runner 前终止；job `108559600346` 的 `runner_name` 为空、步骤为空。检查注释为：“The job was not started because recent account payments have failed or your spending limit needs to be increased.” 因此本轮没有运行任何构建或测试、没有产物；不能说修复后的完整 Apple 回归已通过，也不能判断具体是付款失败还是额度限制。

后续需账号持有人检查 GitHub Billing & plans 的付款／支出限制，恢复可运行条件后对当前分支完整重跑；本批未调整付费设置或尝试提高额度，不重复启动同样会被拦住的运行。本地开发可继续，Apple 完整回归与截图确认保留为未完成项；未调用 `publish-ipa.ps1`，固定安装目录不变。
