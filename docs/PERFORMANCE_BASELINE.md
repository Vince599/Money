# 性能基线与测量入口

日期：2026-09-26。执行[原生体验与工程质量标准](EXPERIENCE_QUALITY.md)的第一批测量准备；本页记录测量能力和限制，不表示 Q01—Q09 已达标。优化前先保留同条件的原始样本，随后比较相同数据与操作。

## 1. App 内分段计时

`App/LedgerPerformance.swift` 使用 Apple [OSSignposter](https://developer.apple.com/documentation/os/ossignposter)，在 Instruments 的 signpost 轨道选择 subsystem `app.vince.ledger`、category `Performance`。每次调用产生独立 ID，嵌套区间按调用关系分析，不能相加计算总耗时。未启用 signpost 时不创建区间状态；无逐行日志、定时轮询或自建计时文件。

| 区间 | 实际起止 | 不包含的部分 |
|---|---|---|
| `App.StartToModel` | 首次／重试 `start()` 通过防重检查，至账本状态发布并设置 `isLoaded`，或读取失败 | 系统启动、进程初始化、实际帧呈现和可操作性；不是 Q01 |
| `Store.Open` | Repository 创建 SQLite store，至初始化／迁移／整本校验返回 | 等待 detached task 获得执行时间、后续快照读取 |
| `Repository.Snapshot` | 读取完整账本、草稿、设置，至快照构造结束 | actor 入场前的排队、模型更新和绘制 |
| `Entry.SaveToModel` | `model.save()` 入场，至 Repository 返回且模型应用完成或未应用 | 原始点击、按钮内金额解析、调用前排队和 SwiftUI 呈现；不是 Q05 |
| `Repository.SaveEntry` | actor 内保存入口，至完整返回快照构造结束 | actor 入场前等待、模型更新和绘制 |
| `Entry.Commit` | 调用 `store.saveEntry()`，包含同事务读取、领域计算、目标行写入、草稿处理和快照核对，至数据库提交返回 | 模型更新和绘制；不是纯 SQL 执行时间，区间结束在 `database.write` 返回之后 |
| `History.QueryExecution` | 一次内存筛选和排序 | 输入事件、呈现、分页；同一次 SwiftUI 更新可能多次执行 |
| `History.GroupExecution` | 已筛选结果按天分组 | 查询、行布局和绘制 |
| `Home.RecentSort` | 首页最近流水的全量排序 | 行布局和绘制 |
| `Home.MonthlyConsumption` / `Home.AccountTotals` | 首页消费／资产金额计算及格式化 | 实际显示；不是 Q07 |

结束信息只有固定的 `completed`、`threw`、`notApplied` 状态。`notApplied` 表示模型没有应用保存结果，可能是忙碌拒绝或报错；`threw` 表示该区间抛错。普通新建／编辑现在在提交前读回核对快照，提交后不再执行可能失败的数据库读取；失败由同一事务回滚。取消信号不能把已提交事务伪装为回滚。较早插桩中的 `Entry.Record`／`Entry.Replace` 已并入 `Entry.Commit`，前后版本的区间名称和范围不能直接混比。

不记录账户、流水或操作 ID、金额、标题、备注、搜索词、文件路径及错误详情。插桩不新增业务 `await`、任务或取消点，不调整 Repository 串行执行、草稿版本保护、入账同事务规则或恢复行为。

## 2. Windows 领域基线

独立工具使用实际 `Sources/LedgerCore` 源码的隔离副本和 Release 配置；不改根 `Package.swift`、`Package.resolved`、App 数据库或账务模型，不注入正式账本。输入是固定版本的合成数据，包含跨年日期、多账户和多种文本。

分别记录领域校验、单笔入账、内存查询的原始毫秒样本、p50、p95 和最大值；准备数据、预热和结果核对在计时范围外。每次入账从相同规模的原始账本开始，不让前一轮结果累加到下一轮。样本少于体验标准要求时只作开发诊断，不用于验收。

运行方式：

```powershell
# 小规模确认编译、结果与输出；不构成性能验收。
./scripts/benchmark-core.ps1 -Sizes 0,1200 -Samples 2 -Warmups 1

# 默认空账本、1 万笔和 10 万笔；每个操作 1 次预热、10 次采样。
./scripts/benchmark-core.ps1
```

`core-mixed-v1` 固定数据含六个账户、两个主体、三种币种、收支／同币种转账、四年日期与长文本；零流水组仍保留相同账户和目录以隔离规模因素，不代表首次安装空库。分别测 `validate`、`recordExpense`、`queryAll` 和 `queryCombined`。组合查询包含关键词、方向、账户、一级分类、主体、币种、金额和日期范围；完整结果及排序在计时外与独立预期核对。

每轮输出保存在忽略的 `build/performance/<run>/`：`results.json` 包含全部样本与 nearest-rank 分位数，`metadata.json` 记录编译器、系统、源码摘要和数据版本，`run.log` 保留构建与执行输出；`package/` 是实际被编译的源码副本。源码摘要包含核心、基线程序和生成的 manifest，脚本也单独记录哈希，不能仅凭 Git HEAD 识别尚未提交的被测代码。小于 20 次采样时 p95 通常等于最大值；本工具不删除异常慢样本，失败时保留报告且退出失败，不把失败或不完整结果当作基线。详细范围见 [Benchmarks/README.md](../Benchmarks/README.md)。

这些样本仅衡量 Windows CPU 上的领域运算。它们不包含 SQLite、文件持久化、SwiftUI、主线程调度、系统输入或实际帧呈现，不能与 iPhone 的 Q01—Q09 阈值直接比较，也不替代数据库读写基线。

### 2.1 首次开发基线结果

2026-09-26，默认命令成功完成。主机 Intel Core Ultra 9 290HX Plus／x86_64、Windows build 26200、Swift 6.4 RELEASE（编译器报告 `+assertions`）、包配置 Release；固定 `core-mixed-v1` 数据，0／10,000／100,000 笔，每操作预热 1 次、测量 10 次，共 132 条记录全部通过结果核对。组合筛选分别命中 0／85／607 条，并逐样本验证完整结果及排序。

| 操作 | 零流水 p95（ms） | 1 万笔 p50 / p95（ms） | 10 万笔 p50 / p95（ms） |
|---|---:|---:|---:|
| 完整领域校验 | 0.0852 | 4.7939 / 4.8719 | 48.4635 / 49.6184 |
| 单笔支出领域入账 | 0.1517 | 10.1871 / 10.5244 | 104.7841 / 108.0722 |
| 全量内存查询与排序 | 0.0007 | 3.3966 / 3.8593 | 47.7788 / 58.6477 |
| 组合条件内存查询 | 0.0035 | 1.4059 / 1.4423 | 13.1588 / 14.7926 |

十次测量使用 nearest-rank 时 p95 等于最大样本；这组小样本用于定位随数据规模增长的成本，没有采满真机验收要求，也没有控制后台负载、热状态和电源模式。单笔入账的领域计算随账本扩大明显增长；数据库整本读写尚未计入，不能将 108 ms 写成 App 保存耗时或 Q05 达标。

本地原始证据：`build/performance/20260926T052419745Z-25612-b3a9c1/results.json`，同目录有源码快照、metadata 与日志；该目录不入版本库。报告 SHA-256 为 `4181c20b911497590f06be34eb87e30c84bd13a253c81311cea0ddfba650451e`，实际编译源码摘要为 `176bcca847cfaceb726e29c27ef9401cb553e1978b3e4e2ac40606270f1ba933`。以后对比需保留原始证据，不能只留表中四舍五入数字。

## 3. Apple 平台和真机证据

当前工作副本的 signpost 插桩尚未经过 Apple SDK 类型检查、Release 编译或 Instruments trace 核验；Windows 的 Swift 源码解析不能代替这些验证。以前 Run #9 的成功记录属于插桩之前的提交。

后续在可用的固定 Apple 构建环境执行已有包、App、UI 回归和 Release 构建，再用合成数据采集一段成功与失败路径的 trace，确认区间配对和实际提交边界。真机测量另记录设备、OS build、App commit／包哈希、工具、账本规模、缓存、温度、电量与调试器状态。

冷启动需通过系统工具关联进程启动起点、标准首帧指标和账本可操作时点；[XCTApplicationLaunchMetric](https://developer.apple.com/documentation/xctest/xctapplicationlaunchmetric)的系统指标与本地数据就绪分开记录。Q03—Q07 需补输入事件与真实呈现证据，不用 App 的状态赋值时刻充当终点。没有连接真机的 Mac／同等可信测量条件时，设备性能和能耗继续标为待测。

## 4. 普通记账增量事务

普通新建只插入一条流水及其操作登记；编辑保留原行位置、身份和创建时间，仅更新目标流水、登记新操作并退役旧操作。操作依据同一写事务内读到的最新账本，由原 `LedgerEngine` 执行规则判断；幂等重试仍遵守既有草稿序号策略。

编辑更换操作 ID 时，复合外键和登记表唯一键需要临时延迟外键检查。仅在该事务使用 `defer_foreign_keys=ON`，不关闭 `foreign_keys`，不在提交前手动复位；成功／失败分别由 COMMIT／ROLLBACK 自动恢复即时检查。依据 [SQLite 官方说明](https://www.sqlite.org/pragma.html#pragma_defer_foreign_keys)。

提交前读回完整账本、草稿和设置，核对投影／payload、关联约束及领域预期，再由数据库完成提交。Repository 只在提交成功后推进草稿序号并返回快照，消除普通入账“提交成功后读取失败”的歧义。草稿替换即使字符串按 Unicode 等价比较相同也实际写入，保留用户原始编码。

数据库 schema 仍为 1，CSV profile／列和旧账本格式均不变。恢复、目录维护、删除和余额更正仍使用原整本事务；启动和保存仍有整本读取／校验，首页最小查询、索引分页、缓存代次和 Widget 尚未实现。这一批只缩小普通新建／编辑的写入范围，不能宣称已完成十万笔性能优化；前面的 Core 基线也不用于计算此次数据库优化的加速倍数。实际 Apple 回归证据记入[开发记录](DEVELOPMENT.md)。
