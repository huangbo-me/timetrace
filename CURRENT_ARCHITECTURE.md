# TimeTrace 当前架构

## 产品范围

TimeTrace 是以“工作”为默认体验的通用活动记录应用。现有五个 Tab、导航和视觉系统保持不变；工作活动驱动今天、地点、历史和统计的默认视图，但底层的活动、地点、事件、会话和提醒都按任意活动建模。

## 结构

```text
SwiftUI Feature View
        ↓
Feature Store（页面状态与命令的收口点）
        ↓
AppModel（应用用例编排）
        ↓
Repository / EventPipeline
        ↓
SwiftData + 私有 CloudKit
        ↓
Core Location / UserNotifications 适配器
```

`AppModel` 目前仍是过渡期的应用编排模块。Feature Store 逐步只应暴露页面所需的不可变状态和命令；页面不应依赖 SwiftData 的 `@Model` 生命周期或直接使用 `ModelContext`。

## 领域不变量

- `ActivityDefinition` 是活动聚合根；工作只是默认活动类型。
- `ActivityTrigger` 的地点围栏归属一个活动。地点类型用于展示与分类，不决定活动归属。
- `ActivityEvent` 是不可变事实；相同 UUID 的事件只会写入一次。
- `ActivitySession` 是事件的投影。开始/结束、手工调整和删除均由 Event Pipeline 重放；用户调整使用包含目标会话与开始事件标识的事件载荷。
- 已完成的人工调整和已删除会话在重放时保留；尚未结束的手工会话仍必须能消费随后的结束事件。
- Core Location 注册、通知排程是每台设备的本地投影，不是 CloudKit 同步状态。

## 同步与恢复

SwiftData 使用私有 CloudKit 数据库（`iCloud.com.chronora.time.trace`）。地点名称、坐标、半径、工作日、常规工时、时区、活动、事件、会话和提醒定义都随模型同步。

每次启动、回到前台或 CloudKit 数据合并后，应用会：

1. 重新读取所有活动和触发器；
2. 对每个启用的活动重放会话投影并处理过期会话；
3. 在本机注册每个启用且非演示的地点围栏，移除已停用地点的注册；
4. 重新检查 iCloud 状态，并重新排程所有已启用的提醒。

CloudKit 只同步记录，无法同步 Core Location 或 UserNotifications 的设备运行时注册；因此真机需分别验证恢复结果。

## 当前限制

- 工作是当前 UI 的默认统计维度；其他活动已可拥有提醒和地点，活动切换/筛选的完整 UI 仍是后续收口项。
- 多地点的精确地点段归因、复杂乱序/重叠围栏事件和跨活动并行会话暂留二期；一期优先保证普通事件顺序、手工补录、同步恢复和停用行为正确。
- 提醒以系统重复通知排程；每次送达的完整独立实例与滚动预排程仍需在二期替换。
- `ChinaWorkCalendar` 内置年度数据，需要建立年度更新或降级提示机制。

## 验证

使用 Xcode 的 iPhone 17 Pro（iOS 26.4）模拟器运行单元测试。模拟器构建不能验证真实 iCloud 跨设备同步、后台围栏唤醒或系统通知送达；这些需要同一 Apple ID 的两台真机验收。
