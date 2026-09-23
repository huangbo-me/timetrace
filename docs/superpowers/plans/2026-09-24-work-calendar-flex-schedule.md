# 法定工作日、弹性工时与历史性能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让工作地点按中国大陆法定工作日或自定义星期计算固定/弹性工时，支持 0.5 小时步进的休息扣除、带影响数量的居中范围弹窗，并修复历史列表重复计算和双列失衡。

**Architecture:** 扩展 `WorkScheduleSnapshot` 和 `ActivityTrigger`，让新排班字段随进入事件与排班修正事件固化；`WorkScheduleCalculator` 以工作日规则和工时模式分派到固定窗口或弹性时长算法。应用层复用同一会话筛选计算历史影响数量，历史页只生成一次展示索引并通过可测试的权重分栏器构建两列。

**Tech Stack:** Swift 6、SwiftUI、SwiftData、XCTest、Core Location 事件投影

**Spec:** `docs/superpowers/specs/2026-09-24-work-calendar-flex-schedule-design.md`

## Global Constraints

- 不读取系统日历、不引入 EventKit 权限、不新增网络接口。
- 正常工作日扣除休息时长；休息日不扣除，不属于前一工作日夜班窗口的在岗时间全部计入休息日加班。
- 每日标准工时以 30 分钟递增，可选 0.5–16 小时；休息时长以 30 分钟递增，可选 0–12 小时。
- 旧排班和旧快照必须解释为 `customWeekdays + fixedWindow + restMinutes=0`，升级不能静默改变历史统计。
- 新工作地点默认 `chinaStatutory + fixedWindow + 09:00–18:00 + restMinutes=0`。
- “全部历史”只处理当前地点未软删除的会话，包含进行中；地点和修正事件仍以一次 SwiftData 保存原子提交。
- 不增加薪资倍率、法定节假日倍数、迟到早退判断或实际休息开始/结束打卡。
- 用户界面和文档保持简体中文，保留现有英文代码标识符。

## Review Focus

- 旧 metadata 没有新键：必须成功解析为旧固定排班，不能套用法定日历或休息扣除；由 Task 1 的兼容测试锁定。
- 夜班跨越休息日边界：班次按开始日判断工作日，且只扣一次休息；由 Task 2 的夜班测试锁定。
- 弹性会话跨多个自然日：每个正常工作日分别扣休息并应用标准工时，休息日整段加班；由 Task 2 的多日测试锁定。
- 弹窗数字与真正写入目标漂移：两者必须复用同一筛选函数并捕获展示快照；由 Task 3、Task 4 的数量测试锁定。
- 大字体或不同时段数量使卡片高度变化：权重分栏不能固定奇偶，且两列权重差不超过最后一张卡权重；由 Task 5 的分栏测试锁定。

---

### Task 1: 扩展排班快照、地点持久化与备份兼容

**Files:**
- Modify: `TimeTrace/Domain/Models.swift:107-197,231-298`
- Modify: `TimeTrace/Persistence/DataBackupService.swift:52-118`
- Test: `TimeTraceTests/AnalyticsServiceTests.swift`
- Test: `TimeTraceTests/RepositoryTests.swift`

**Interfaces:**
- Produces: `WorkCalendarMode`, `WorkScheduleMode`
- Produces: `WorkScheduleSnapshot.init?(weekdaysMask:startMinute:endMinute:timeZoneIdentifier:isEnabled:calendarMode:scheduleMode:standardWorkMinutes:restMinutes:)`
- Produces: `ActivityTrigger.workCalendarMode`, `workScheduleMode`, `standardWorkMinutes`, `restMinutes`
- Consumes: existing `EventMetadata`, `ActivityTriggerRecord`

- [ ] **Step 1: Write failing snapshot compatibility tests**

Add these tests to `AnalyticsServiceTests`:

```swift
func testWorkScheduleSnapshotRoundTripsModesAndDurations() throws {
    let snapshot = try XCTUnwrap(WorkScheduleSnapshot(
        weekdaysMask: 0b0111110,
        startMinute: nil,
        endMinute: nil,
        timeZoneIdentifier: "Asia/Shanghai",
        isEnabled: true,
        calendarMode: .chinaStatutory,
        scheduleMode: .flexibleDuration,
        standardWorkMinutes: 8 * 60,
        restMinutes: 3 * 60
    ))
    let decoded = try XCTUnwrap(WorkScheduleSnapshot(metadata: snapshot.adding(to: .empty)))
    XCTAssertEqual(decoded, snapshot)
}

func testLegacyScheduleMetadataKeepsOldSemantics() throws {
    let metadata = EventMetadata(values: [
        "workScheduleEnabled": "true",
        "workScheduleWeekdaysMask": "62",
        "workScheduleStartMinute": "540",
        "workScheduleEndMinute": "1080",
        "workScheduleTimeZoneIdentifier": "Asia/Shanghai"
    ])
    let snapshot = try XCTUnwrap(WorkScheduleSnapshot(metadata: metadata))
    XCTAssertEqual(snapshot.calendarMode, .customWeekdays)
    XCTAssertEqual(snapshot.scheduleMode, .fixedWindow)
    XCTAssertEqual(snapshot.standardWorkMinutes, 8 * 60)
    XCTAssertEqual(snapshot.restMinutes, 0)
}

func testScheduleRejectsOutOfRangeStandardAndRestMinutes() {
    XCTAssertNil(WorkScheduleSnapshot(
        weekdaysMask: 62, startMinute: nil, endMinute: nil,
        timeZoneIdentifier: "Asia/Shanghai", isEnabled: true,
        calendarMode: .chinaStatutory, scheduleMode: .flexibleDuration,
        standardWorkMinutes: 0, restMinutes: 0
    ))
    XCTAssertNil(WorkScheduleSnapshot(
        weekdaysMask: 62, startMinute: 540, endMinute: 1080,
        timeZoneIdentifier: "Asia/Shanghai", isEnabled: true,
        calendarMode: .chinaStatutory, scheduleMode: .fixedWindow,
        standardWorkMinutes: 480, restMinutes: 12 * 60 + 30
    ))
}
```

- [ ] **Step 2: Run the snapshot tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -quiet \
  -project TimeTrace.xcodeproj -scheme TimeTrace \
  -destination 'platform=iOS Simulator,id=A69B2FA1-C58D-4423-A700-BBD507829579' \
  -only-testing:TimeTraceTests/AnalyticsServiceTests/testWorkScheduleSnapshotRoundTripsModesAndDurations \
  -only-testing:TimeTraceTests/AnalyticsServiceTests/testLegacyScheduleMetadataKeepsOldSemantics \
  -only-testing:TimeTraceTests/AnalyticsServiceTests/testScheduleRejectsOutOfRangeStandardAndRestMinutes
```

Expected: compilation fails because the new enums and initializer parameters do not exist.

- [ ] **Step 3: Implement the model and metadata changes**

Add to `Models.swift`:

```swift
enum WorkCalendarMode: String, Codable, CaseIterable, Identifiable {
    case chinaStatutory
    case customWeekdays
    var id: String { rawValue }
}

enum WorkScheduleMode: String, Codable, CaseIterable, Identifiable {
    case fixedWindow
    case flexibleDuration
    var id: String { rawValue }
}
```

Extend `WorkScheduleSnapshot` with the four fields. Give the four new initializer parameters compatibility defaults `.customWeekdays`, `.fixedWindow`, `480`, and `0` so existing explicit fixed-window call sites retain their meaning. Validate `standardWorkMinutes` in `30...960`, `restMinutes` in `0...720`, and both values as multiples of 30. Require start/end only for `.fixedWindow`; require a valid standard duration for `.flexibleDuration`. Write metadata keys `workScheduleCalendarMode`, `workScheduleMode`, `workScheduleStandardMinutes`, and `workScheduleRestMinutes`. When those keys are absent, use the same compatibility defaults.

Add nonoptional SwiftData properties with old-data defaults:

```swift
var workCalendarModeRaw: String = WorkCalendarMode.customWeekdays.rawValue
var workScheduleModeRaw: String = WorkScheduleMode.fixedWindow.rawValue
var standardWorkMinutes: Int = 8 * 60
var restMinutes: Int = 0
```

Expose typed computed properties and include the values in `ActivityTrigger.workScheduleSnapshot` and the initializer.

- [ ] **Step 4: Add failing backup round-trip coverage**

In `RepositoryTests.testEncryptedBackupRoundTripAndStableMerge`, construct the trigger with statutory/flexible/480/180 values and assert the restored trigger preserves all four values. Add a manually encoded legacy `ActivityTriggerRecord` JSON without the new fields and assert decode produces custom/fixed/480/0.

- [ ] **Step 5: Run backup tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -quiet \
  -project TimeTrace.xcodeproj -scheme TimeTrace \
  -destination 'platform=iOS Simulator,id=A69B2FA1-C58D-4423-A700-BBD507829579' \
  -only-testing:TimeTraceTests/RepositoryTests/testEncryptedBackupRoundTripAndStableMerge
```

Expected: FAIL because `ActivityTriggerRecord` does not preserve the new fields.

- [ ] **Step 6: Implement backward-compatible backup fields**

Add optional Codable fields to `ActivityTriggerRecord`:

```swift
var workCalendarModeRaw: String?
var workScheduleModeRaw: String?
var standardWorkMinutes: Int?
var restMinutes: Int?
```

Encode current values. In `makeModel()`, fall back to `.customWeekdays`, `.fixedWindow`, `480`, and `0` when old backups omit them.

- [ ] **Step 7: Run targeted tests and commit**

Run the Task 1 targeted tests, then:

```bash
git add TimeTrace/Domain/Models.swift TimeTrace/Persistence/DataBackupService.swift \
  TimeTraceTests/AnalyticsServiceTests.swift TimeTraceTests/RepositoryTests.swift
git commit -m 'feat: 扩展工作排班快照与备份字段'
```

### Task 2: 接入法定工作日并实现固定/弹性休息算法

**Files:**
- Move: `TimeTrace/App/ChinaWorkCalendar.swift` → `TimeTrace/Domain/ChinaWorkCalendar.swift`
- Modify: `TimeTrace.xcodeproj/project.pbxproj`
- Modify: `TimeTrace/Domain/AnalyticsService.swift:3-130`
- Test: `TimeTraceTests/AnalyticsServiceTests.swift`

**Interfaces:**
- Consumes: `WorkScheduleSnapshot.calendarMode`, `scheduleMode`, `standardWorkMinutes`, `restMinutes`
- Produces: `OvertimeBreakdown.workdayOvertime`
- Produces: `ChinaWorkCalendar.status(for:calendar:)`

- [ ] **Step 1: Write failing calendar and overtime tests**

Add tests covering these exact expectations:

```swift
func testStatutoryHolidayCountsEntirePresenceAsRestDayOvertime() throws {
    let schedule = try XCTUnwrap(statutoryFixedSchedule(restMinutes: 180))
    let start = localDate(year: 2026, month: 9, day: 25, hour: 10)
    let end = localDate(year: 2026, month: 9, day: 25, hour: 21)
    let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(from: start, to: end, schedule: schedule))
    XCTAssertEqual(result.restDayOvertime, 11 * 3600, accuracy: 0.1)
    XCTAssertEqual(result.normalDuration, 0, accuracy: 0.1)
}

func testMakeUpWeekendUsesNormalWorkdayRules() throws {
    let schedule = try XCTUnwrap(statutoryFixedSchedule(restMinutes: 60))
    let start = localDate(year: 2026, month: 9, day: 20, hour: 9)
    let end = localDate(year: 2026, month: 9, day: 20, hour: 18)
    let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(from: start, to: end, schedule: schedule))
    XCTAssertEqual(result.normalDuration, 8 * 3600, accuracy: 0.1)
    XCTAssertEqual(result.totalOvertime, 0, accuracy: 0.1)
}

func testFlexibleWorkdaySubtractsRestBeforeOvertime() throws {
    let schedule = try XCTUnwrap(statutoryFlexibleSchedule(standardMinutes: 480, restMinutes: 180))
    let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
        from: localDate(year: 2026, month: 9, day: 21, hour: 10),
        to: localDate(year: 2026, month: 9, day: 21, hour: 21),
        schedule: schedule
    ))
    XCTAssertEqual(result.normalDuration, 8 * 3600, accuracy: 0.1)
    XCTAssertEqual(result.workdayOvertime, 0, accuracy: 0.1)
}

func testFlexibleRestDayDoesNotSubtractRest() throws {
    let schedule = try XCTUnwrap(statutoryFlexibleSchedule(standardMinutes: 480, restMinutes: 180))
    let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
        from: localDate(year: 2026, month: 9, day: 26, hour: 10),
        to: localDate(year: 2026, month: 9, day: 26, hour: 21),
        schedule: schedule
    ))
    XCTAssertEqual(result.restDayOvertime, 11 * 3600, accuracy: 0.1)
}
```

Also add:

- a fixed 22:00–08:00 night shift with a 1-hour rest that reports 9 hours normal and deducts rest once;
- a flexible Friday-to-Sunday session that applies rest/standard duration separately on normal workdays and counts every rest-day second as overtime;
- a legacy custom-weekday schedule proving its existing weekday behavior is unchanged.

- [ ] **Step 2: Run the calculator tests and verify RED**

Run all `AnalyticsServiceTests` and confirm failures are due to missing modes, statutory calendar use, `workdayOvertime`, and rest subtraction.

- [ ] **Step 3: Move the calendar into the domain group**

Move the source file to `TimeTrace/Domain/ChinaWorkCalendar.swift` and change its PBX file path from `App/ChinaWorkCalendar.swift` to `Domain/ChinaWorkCalendar.swift`. Do not change its 2026 dates.

- [ ] **Step 4: Implement the two calculation paths**

Extend the breakdown:

```swift
struct OvertimeBreakdown: Equatable {
    let normalDuration: TimeInterval
    let earlyOvertime: TimeInterval
    let lateOvertime: TimeInterval
    let workdayOvertime: TimeInterval
    let restDayOvertime: TimeInterval

    var totalOvertime: TimeInterval {
        earlyOvertime + lateOvertime + workdayOvertime + restDayOvertime
    }
}
```

Add a single helper that owns day classification:

```swift
private static func isWorkday(_ day: Date, schedule: WorkScheduleSnapshot,
                              calendar: Calendar) -> Bool {
    switch schedule.calendarMode {
    case .chinaStatutory:
        ChinaWorkCalendar.status(for: day, calendar: calendar).isWorkday
    case .customWeekdays:
        schedule.weekdaysMask.containsWeekday(calendar.component(.weekday, from: day))
    }
}
```

Dispatch `.fixedWindow` to the existing interval algorithm with these changes: classify each shift by its start day, so a workday night shift remains normal across midnight and a rest-day night shift remains rest-day overtime across midnight. Classify time outside any shift by its actual local day. Subtract `restMinutes` once from each workday shift's accumulated normal duration, clamped at zero; never subtract rest from rest-day overtime.

Dispatch `.flexibleDuration` to a calendar-day loop. For each day intersection, put the complete duration in rest-day overtime when not a workday. Otherwise calculate `effective = max(0, presence - restMinutes*60)`, `normal = min(effective, standardWorkMinutes*60)`, and `workdayOvertime = max(0, effective-normal)`.

- [ ] **Step 5: Run calculator tests and commit**

Run `AnalyticsServiceTests`, then:

```bash
git add TimeTrace/Domain/ChinaWorkCalendar.swift TimeTrace/Domain/AnalyticsService.swift \
  TimeTrace.xcodeproj/project.pbxproj TimeTraceTests/AnalyticsServiceTests.swift
git commit -m 'feat: 支持法定工作日与弹性工时计算'
```

### Task 3: 串联地点用例、快照写入和影响数量

**Files:**
- Modify: `TimeTrace/App/AppModel.swift:295-511,1090-1104`
- Test: `TimeTraceTests/RepositoryTests.swift`

**Interfaces:**
- Consumes: extended `WorkScheduleSnapshot`
- Produces: `AppModel.workScheduleAffectedSessions(triggerId:) -> [ActivitySession]`
- Produces: `AppModel.workScheduleAffectedSessionCount(triggerId:) -> Int`
- Updates: `updateWorkplace(...schedule:scheduleEditScope:)`

- [ ] **Step 1: Write failing affected-count tests**

Create a work trigger with one completed session, one active session, one soft-deleted session, and a second trigger with one session. Assert:

```swift
XCTAssertEqual(model.workScheduleAffectedSessionCount(triggerId: first.id), 2)
XCTAssertEqual(model.workScheduleAffectedSessions(triggerId: first.id).map(\.id),
               [completed.id, active.id])
```

Sort the returned sessions by `startAt`, then `id.uuidString`, so the displayed count and generated event order are deterministic.

- [ ] **Step 2: Run the new count test and verify RED**

Run only that `RepositoryTests` method. Expected: compilation fails because the APIs do not exist.

- [ ] **Step 3: Implement one shared target selector**

Add:

```swift
func workScheduleAffectedSessions(triggerId: UUID) -> [ActivitySession] {
    sessions
        .filter { $0.deletedAt == nil && $0.placeTriggerId == triggerId }
        .sorted {
            $0.startAt == $1.startAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.startAt < $1.startAt
        }
}

func workScheduleAffectedSessionCount(triggerId: UUID) -> Int {
    workScheduleAffectedSessions(triggerId: triggerId).count
}
```

Make `workScheduleAdjustmentEvents` consume this method instead of maintaining its own filter.

- [ ] **Step 4: Write failing propagation and scope tests**

Extend repository tests to save a statutory flexible schedule with 480 standard minutes and 180 rest minutes. Assert:

- the trigger stores all four new values;
- the next geofence entry metadata resolves to the same snapshot;
- `.futureOnly` leaves existing breakdowns on their old custom/fixed/rest-zero snapshot;
- `.allHistory` produces exactly `workScheduleAffectedSessionCount` adjustment events and every revision contains the new metadata;
- a soft-deleted and another-place session receives no revision.

- [ ] **Step 5: Run the propagation tests and verify RED**

Run the newly added repository tests. Expected: FAIL because AppModel does not accept or persist the extended schedule.

- [ ] **Step 6: Implement AppModel propagation**

Change `finishOnboarding`, `updateWorkplace`, and `updatePlace` to accept a complete `WorkScheduleSnapshot` rather than parallel schedule fields; `nil` means “do not change the existing schedule,” while an enabled or disabled snapshot is an explicit schedule value. Thread the snapshot through new-place defaults and `addWorkplace`. Ensure `overtimeBreakdown(for:)` uses the resolved snapshot; no current-trigger field may override a stored snapshot. Update every production and test call site in the same step.

- [ ] **Step 7: Run repository tests and commit**

Run `RepositoryTests`, then:

```bash
git add TimeTrace/App/AppModel.swift TimeTraceTests/RepositoryTests.swift
git commit -m 'feat: 串联排班模式与历史影响数量'
```

### Task 4: 更新工作地点编辑器和居中范围弹窗

**Files:**
- Modify: `TimeTrace/Features/Onboarding/OnboardingView.swift:60-240`
- Modify: `TimeTrace/Features/Settings/SettingsView.swift:539-780`
- Test: `TimeTraceTests/RepositoryTests.swift`

**Interfaces:**
- Consumes: `WorkCalendarMode`, `WorkScheduleMode`, extended snapshot and count APIs
- Produces: `WorkScheduleImpactPrompt.init(affectedCount:)`

- [ ] **Step 1: Write failing prompt-copy test**

Add an internal presentation value:

```swift
func testWorkScheduleImpactPromptShowsStableCount() {
    let prompt = WorkScheduleImpactPrompt(affectedCount: 16)
    XCTAssertEqual(prompt.title, "排班变更应用范围")
    XCTAssertTrue(prompt.message.contains("当前地点共有 16 条未删除记录"))
    XCTAssertTrue(prompt.message.contains("已有 16 条记录保持原排班"))
    XCTAssertEqual(prompt.allHistoryButtonTitle, "全部历史（16 条）")
}
```

Run the test and confirm compilation fails because `WorkScheduleImpactPrompt` does not exist.

- [ ] **Step 2: Implement the prompt value and alert**

Add:

```swift
struct WorkScheduleImpactPrompt: Equatable {
    let affectedCount: Int
    let title = "排班变更应用范围"
    var allHistoryButtonTitle: String { "全部历史（\(affectedCount) 条）" }
    var message: String {
        "当前地点共有 \(affectedCount) 条未删除记录。\n" +
        "仅今后：已有 \(affectedCount) 条记录保持原排班，下次到达时生效。\n" +
        "全部历史：按新排班重新计算 \(affectedCount) 条记录，包含进行中的记录。"
    }
}
```

Replace schedule `.confirmationDialog` with `.alert`. When `requestSave()` detects a changed schedule, assign a state-held `WorkScheduleImpactPrompt` using the current count, then present the alert. Use its captured count for text even if the store refreshes while the alert is visible. Keep delete confirmation unchanged.

- [ ] **Step 3: Add the work-calendar and schedule-mode controls**

In onboarding and workplace editing:

- add a segmented/menu picker for “中国大陆法定工作日 / 自定义每周工作日”;
- show `WeekdayPicker` only for custom mode and add the caption “选择通常需要上班的星期”；
- add “固定上下班 / 弹性工时” picker;
- fixed mode shows start and end pickers;
- flexible mode shows a standard-duration picker over `stride(from: 30, through: 960, by: 30)`;
- both modes show a rest picker over `stride(from: 0, through: 720, by: 30)`;
- format zero as“无休息”，others as“X 小时” or “X.5 小时”。

Pass a complete snapshot into AppModel. Preserve old trigger values on edit and use the new-place defaults from the spec.

- [ ] **Step 4: Run prompt and repository tests, build, and commit**

Run the prompt test, relevant repository tests, and a Debug simulator build. Then:

```bash
git add TimeTrace/Features/Onboarding/OnboardingView.swift \
  TimeTrace/Features/Settings/SettingsView.swift TimeTraceTests/RepositoryTests.swift
git commit -m 'feat: 更新排班编辑与影响范围弹窗'
```

### Task 5: 消除历史页重复计算并平衡瀑布流

**Files:**
- Modify: `TimeTrace/Features/History/HistoryView.swift:17-150,181-320,876-927`
- Test: `TimeTraceTests/AnalyticsServiceTests.swift`

**Interfaces:**
- Produces: `HistoryMasonryColumns.distribute(_:weight:)`
- Consumes: one body-level `origins`, `overtime`, and `daySpans` snapshot

- [ ] **Step 1: Write failing deterministic column-allocation tests**

Define a generic/id-based test fixture with weights `[1, 4, 2, 4, 1, 3]`. Assert distribution places each next item on the currently lighter column rather than alternating, preserves input order within each column, and satisfies:

```swift
XCTAssertLessThanOrEqual(abs(result.leftWeight - result.rightWeight), weights.max()!)
XCTAssertNotEqual(result.left.map(\.id), [0, 2, 4])
```

Add an empty-input test returning two empty columns and zero weights. Run and verify RED because the allocator does not exist.

- [ ] **Step 2: Implement the pure weight allocator**

Add an internal generic helper near HistoryView:

```swift
struct HistoryMasonryColumns<Element> {
    let left: [Element]
    let right: [Element]
    let leftWeight: Int
    let rightWeight: Int

    static func distribute(_ elements: [Element], weight: (Element) -> Int) -> Self {
        var left: [Element] = []
        var right: [Element] = []
        var leftWeight = 0
        var rightWeight = 0
        for element in elements {
            let value = max(1, weight(element))
            if leftWeight <= rightWeight {
                left.append(element)
                leftWeight += value
            } else {
                right.append(element)
                rightWeight += value
            }
        }
        return .init(left: left, right: right,
                     leftWeight: leftWeight, rightWeight: rightWeight)
    }
}
```

Use a card weight of `4 + sessionCount * 2 + crossDayLine + overtimeLine`; calculate the two flags from the already-created maps.

- [ ] **Step 3: Remove per-card dictionary recomputation**

Change `historyCard` to accept `origins`, `overtime`, and `crossedDays` as parameters. Pass the body-level values at both call sites. Remove all calls to `originBySessionID`, `overtimeBySessionID`, or `crossedDaysBySessionID` from inside `historyCard`.

Pre-index `model.events` by ID and the non-schedule-adjusted session IDs once while building `originBySessionID`, so `origin(for:)` no longer performs two full event scans per session.

- [ ] **Step 4: Replace odd/even split with balanced columns**

Replace `leftSummaries`/`rightSummaries` odd-even `compactMap` calls with `HistoryMasonryColumns.distribute`. Keep the two `LazyVStack`s, paging count, filter reset, card click behavior, and `onAppear` pagination unchanged. Delete the unused non-lazy `MasonryLayout` implementation.

- [ ] **Step 5: Run allocator tests, full Analytics tests, build, and commit**

Run `AnalyticsServiceTests`, a Debug build, and `git diff --check`. Then:

```bash
git add TimeTrace/Features/History/HistoryView.swift TimeTraceTests/AnalyticsServiceTests.swift
git commit -m 'perf: 优化历史计算与瀑布流分栏'
```

### Task 6: 同步文档并完成全量验证

**Files:**
- Modify: `CONTEXT.md`
- Modify: `CURRENT_ARCHITECTURE.md`
- Modify: `README.md`
- Verify: all files changed by Tasks 1–5

**Interfaces:**
- Consumes: final behavior from all prior tasks
- Produces: source-aligned Chinese documentation and verification evidence

- [ ] **Step 1: Update domain and architecture documentation**

Document these exact rules:

- statutory/custom workday modes and the 2026 offline boundary;
- fixed/flexible schedule modes;
- workday rest subtraction versus full rest-day overtime;
- old snapshot compatibility;
- range alert affected-count semantics;
- one-time history presentation calculation and weighted waterfall columns.

- [ ] **Step 2: Run focused test groups**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -quiet \
  -project TimeTrace.xcodeproj -scheme TimeTrace \
  -destination 'platform=iOS Simulator,id=A69B2FA1-C58D-4423-A700-BBD507829579' \
  -only-testing:TimeTraceTests/AnalyticsServiceTests \
  -only-testing:TimeTraceTests/RepositoryTests \
  -only-testing:TimeTraceTests/ActivitySessionEngineTests
```

Expected: every selected test passes with zero failures.

- [ ] **Step 3: Run the full suite and Debug build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -quiet \
  -project TimeTrace.xcodeproj -scheme TimeTrace \
  -destination 'platform=iOS Simulator,id=A69B2FA1-C58D-4423-A700-BBD507829579'

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -quiet \
  -project TimeTrace.xcodeproj -scheme TimeTrace -configuration Debug \
  -destination 'platform=iOS Simulator,id=A69B2FA1-C58D-4423-A700-BBD507829579'

git diff --check
```

Expected: full tests pass, build exits 0, and diff check emits no output.

- [ ] **Step 4: Perform simulator UI acceptance**

Verify in the work-place editor:

- statutory/custom control visibility;
- fixed/flexible field switching;
- 0.5-hour duration increments and state restoration;
- schedule range appears as a centered alert, not a popover/action sheet;
- displayed count matches fixture sessions;
- History scroll reaches the last card without a long empty left column.

- [ ] **Step 5: Verify the physical-device boundary without mutating data**

Re-export the connected app container read-only and retain the 9 月 21 日 source record as an acceptance fixture. Do not install or overwrite the user's phone build without a separate explicit request. Report the expected result for statutory/flexible 8-hour/3-hour settings, while labeling actual on-device recalculation as pending installation.

- [ ] **Step 6: Commit docs and final verification state**

```bash
git add CONTEXT.md CURRENT_ARCHITECTURE.md README.md
git commit -m 'docs: 同步法定工作日与弹性工时口径'
git status --short
```

Expected: clean feature worktree after the final commit.
