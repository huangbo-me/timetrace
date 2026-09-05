# TimeTrace MVP 架构

## 原则

TimeTrace 使用 Event First → Session Second → Insight Last 的单向数据流：

```text
CoreLocation / Notification / Manual Action
                    ↓
              ActivityEvent
                    ↓
           ActivityEventRepository
                    ↓
           ActivitySessionEngine
                    ↓
              ActivitySession
                    ↓
             AnalyticsService
```

原始 Event 只追加；Session 可由排序后的 Event 确定性重放。UI 不访问 SwiftData
`ModelContext`，只调用 Repository、Service 与 AppStore。

## 目录

```text
TimeTrace/
  App/
  Domain/
  Persistence/
  Services/
  Features/
TimeTraceTests/
```

保持单一 App target 和单一 Test target，不拆分模块或引入第三方依赖。

## 领域模型

- `ActivityDefinition`：用户定义的 work/study/exercise/focus/custom 活动。
- `ActivityTrigger`：geofence、schedule、manual、appUsage 触发配置。
- `ActivityEvent`：不可删除的事实记录；处理结果仅标注 applied/redundant/orphaned。
- `ActivitySession`：一次活动，包含起止 Event、状态、置信度与软删除标记。
- `ActivityEvidence`：未来设备使用等执行证据的最小扩展点。
- `ReminderDefinition/ReminderInstance`：提醒定义与每次触发实例分离。

SwiftData 模型使用 UUID 主键和可选关联标识，不使用 CloudKit 专用设计。

## Session 状态机

```text
start event ──→ active ──stop event──→ completed
                   │
                   ├─ 24h 无 stop ──→ incomplete
                   └─ 人工修正 ─────→ manuallyAdjusted
```

- active 时再次收到 start：Event 保留并标记 redundant。
- 无 active 时收到 stop：Event 标记 orphaned。
- 跨午夜不关闭；统计归属 startAt 所在日期。
- 人工补录、修改和删除都写审计 Event；删除是软删除。
- History 将缺失起止事件的异常置顶：缺少离开时用 adjustment 补齐，孤立离开时追加
  manualStart 后确定性重放；忽略异常会追加 anomalyDismissed，原始定位 Event 仍不删除。

## Reminder 状态机

```text
scheduled → reminded → started → inProgress → completed
                    │               └────────→ abandoned
                    ├→ snoozed → scheduled
                    ├→ skipped
                    └→ ignored（仅明确 dismiss 时）
```

通知送达、活动开始与活动完成是三个不同事实。

## 数据与统计口径

- 工作日使用围栏配置时保存的时区，周为周一至周日。
- Daily 总时长为所有已闭合、未删除 Session 的时长之和。
- 不完整日的已知时长进入总计，但不进入平均工时。
- 到达/离开平均分别使用拥有对应时间的数据日。
- Weekly 与 Monthly 都返回结构化数据及上一周期差值；缺数据时差值为 nil。

## MVP 边界

- 仅 iPhone、iOS 26、简体中文、本地 SwiftData。
- 不实现服务器、CloudKit、AI、连续轨迹或 App Shield。公司位置支持本地 MapKit 地址搜索。
- Screen Time 仅提供协议和可测试 Stub，不引入 entitlement。
