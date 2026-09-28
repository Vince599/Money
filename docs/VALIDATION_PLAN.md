# 按功能批次开发与验证

2026-09-28 用户确认：本地检查贯穿开发，Apple 检查按风险和功能批次安排，完整回归集中在晚间或阶段收尾。预算继续延期，不逐轮交付 IPA。

## 执行节奏

1. 白天连续完成一组相关功能，运行受影响测试及本地核心回归；代码提交或“继续”不自动触发 GitHub。
2. 模块闭环后按需选择 Apple 编译、业务测试或页面专项。数据库迁移、备份恢复、资金计算及新系统能力提前取得对应证据，不推迟到整个 App 完工。
3. 晚间／阶段收尾对有新代码的确定提交做完整回归。相同提交、相同范围已运行时，先复用其结果；失败修复或基础设施故障另有依据才重跑。
   仅文档改动不触发构建；判断代码变化时包含 App／Sources／测试／构建脚本／依赖锁及工程配置。
4. 发起云端后记录分支、完整 SHA、范围、运行 ID／链接及待验证项，结束主动等待。用户稍后继续时读取结果；有明确授权的定时跟进才自动返回。不高频轮询、不重复发送等待消息。
5. 失败先取摘要和相关日志，修复后定向补测；完整回归留到下一批次。验证结果只覆盖其提交，期间继续开发的内容另列待验证。
6. 安装交付必须在同一提交完整通过后显式打包，再执行既有发布与校验流程。

当前仍为手动触发，未创建凌晨自动任务；睡前由用户安排运行。GitHub 构建独立运行，自动分析／修复需要另行配置，不能把一次手动启动当作已设定夜间自动开发。

## Apple 检查入口

工作流 `iOS batch validation` 和 `scripts/build-ios.sh` 共用以下范围，默认 **business**；默认均不打包。

| `validation_scope` | 执行范围 | 用途 |
|---|---|---|
| `compile` | 模拟器 Debug build-for-testing＋arm64 Release 编译；不启动测试 | 检查 Apple SDK／SwiftUI 和测试目标能否编译 |
| `business` | macOS 全部 Core／Store 包测试＋模拟器 AppTests＋arm64 Release 编译 | 一个业务批次的集成验证，跳过 UI 操作 |
| `ui` | 所选 UI 路径＋arm64 Release 编译，不运行包测试和 AppTests | 页面专项或失败修复补测 |
| `full` | 全部包测试＋AppTests＋UITests＋arm64 Release 编译 | 晚间、阶段收尾及交付前回归 |

`ui_suite` 仅对 `ui` 生效，可选 `all`、`calculator`、`imports`、`refunds`、`categories`、`tags`、`accounts`、`entries`。`full` 不会被该选项缩减。旧命令的 `validation_scope=calculator` 在本地脚本兼容为 `ui + calculator`。

`package_ipa=true` 只允许与 `full` 一起使用，其他范围明确拒绝。其作用仅为生成内部未签名包，不自动发布固定安装目录。工作流仍仅有手动触发，没有 push／PR／定时触发；超时仍为 60 分钟，待新增路径的实际耗时接近上限时再拆分或调整。

macOS 示例：

```bash
# 默认：业务测试，不跑 UI、不打包
bash scripts/build-ios.sh
# 只检查编译
LEDGER_VALIDATION_SCOPE=compile bash scripts/build-ios.sh
# 只补测退款页面
LEDGER_VALIDATION_SCOPE=ui LEDGER_UI_SUITE=refunds bash scripts/build-ios.sh
# 晚间完整回归，不打包
LEDGER_VALIDATION_SCOPE=full bash scripts/build-ios.sh
# 明确准备交付时：同一提交完整验证后打包
LEDGER_VALIDATION_SCOPE=full LEDGER_PACKAGE_IPA=true bash scripts/build-ios.sh
```

## 结果与产物

- 每轮记录 `validation-scope.txt`。所选范围及 Release 编译成功后生成 `validation-result.json`，分别标明包／App／UI 测试是通过还是未运行；仅编译不能记作测试通过。
- 测试范围必须实际执行至少一项测试；失败、跳过、预期失败或计数缺失均拒绝生成成功记录。含 UI 的范围还要求截图导出成功且存在 PNG。
- 只有完整验证并明确打包时才生成 IPA、哈希与供发布脚本使用的 `build-metadata.json`；非打包运行不能误作安装包交付。
- 正常 artifact 保存摘要、日志、PNG／附件清单及可选 IPA，不重复上传整个 xcresult。失败时另存 `-diagnostics` 完整结果包，需要诊断才下载。保存期仍为 7 天；并非账本备份。
- 不承诺新流程的具体提速比例。UI 操作耗时、重复准备和无效等待仍需基于后续日志优化，不能删除业务断言换取通过。

## 本批本地检查与待验证项

构建范围及摘要门禁有 8 项可移植检查：`python -m unittest discover -s scripts/tests -p test_validation.py -v`；检查默认范围、全部页面目标、旧别名、完整范围不被缩减、部分验证禁止打包及零测试／失败／跳过拒绝成功。Bash 语法检查通过。这些检查不等于新工作流已经在 Apple 上执行。

同期新增退款／回收关联筛选，本地 Core **249 项／26 套件通过**，56 个 Apple 侧 Swift 文件语法解析通过。新增 2 项 Store 测试和扩展退款 UI 路径尚待 Apple 验证；下一次业务批次可先跑 `business`，页面专项选 `refunds`，晚间完整回归统一覆盖其余受影响的长表单路径。业务 schema 10／CSV profile 10 不变。最新已执行 Apple 证据仍是旧代码的 #41／#42，不能套用于本批。

### 后续累计：流水日汇总

新增完整日期汇总、跨页日值复用和有结果时的筛选清除入口，Core **255 项／27 套件通过**，57 个 Apple 文件语法解析通过。新增 3 Store 用例、既有 App 分页断言与退款 UI 日金额断言尚待 Apple；结合上一批仍待执行的 2 Store 用例，共新增 5 项 Store 待验证。下一次 business 覆盖数据与 App 层，refunds 专项核对新显示及关联筛选，full 再覆盖所有长列表路径；不逐小改动触发构建。详细口径见[流水日汇总](HISTORY_TOTALS.md)。
