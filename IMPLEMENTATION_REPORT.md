# TimeTrace MVP 实施报告

## 修改文件

- 工程：`TimeTrace.xcodeproj`、共享 Scheme、`.gitignore`
- 架构：`CURRENT_ARCHITECTURE.md`、`MVP_ARCHITECTURE.md`
- App：依赖组装、统一 `AppModel`、根导航
- Domain：Activity/Event/Session/Evidence/Reminder 模型、Repository 协议、Session Engine、Analytics
- Persistence：SwiftData Container 与各 Repository 实现
- Services：Event Pipeline、CoreLocation、UserNotifications、Screen Time Stub
- Features：Onboarding、Today、History、Insights、Settings 与公共格式化
- Tests：Session Engine、Analytics、SwiftData/Pipeline/Fake System Service 测试

## 数据模型与状态机

所有系统和人工输入先追加 `ActivityEvent`；事实字段不删除、不覆盖。Session Engine
按时间顺序重放 Event，并将处理结果标记为 applied、redundant 或 orphaned。

Session 支持 active、completed、incomplete、manuallyAdjusted。跨午夜不拆分；24 小时
未闭合转 incomplete，但不伪造 endAt。用户删除为软删除，原始 Event 保留。

Reminder 将 scheduled、reminded、started、inProgress、completed/abandoned 与 snoozed、
skipped、ignored 分开，避免把通知送达当成活动完成。

## Geofence 工作流程

用户可通过 MapKit 搜索公司/地址、高精度当前位置、轻点地图或拖动红色大头针配置公司围栏；
地图同时显示系统蓝色当前位置、围栏圆与定位精度。CoreLocation 只注册圆形区域，不持续保存轨迹。
进入/离开回调统一转换为 geofenceEnter/geofenceExit Event，然后交给 Event Pipeline。
启动时恢复监控并请求 region state；state 本身不伪造成边界事件。

## Notification 工作流程

App 启动注册 Activity Reminder Category。开始、稍后、跳过分别追加对应 Event；稍后会
创建 10 分钟后的一次性通知。开始会创建 Session，Today 提供完成和放弃。明确收到通知
dismiss callback 时标记 ignored；系统未回调的通知保持 unresolved。

## 已实现能力

- 公司位置、围栏半径、工作日与正常时间配置
- 公司名/地址搜索、候选地址选择与当前位置兜底
- 自动围栏 Event Pipeline 与多段工作 Session
- 重复、孤立、乱序、跨天、缺失 Exit 和 24 小时 stale 处理
- History 修改、补录、软删除
- 异常记录置顶；缺少到达/离开时可手动补齐，并支持忽略异常
- 近三天、本周、上一周、最近一个月及自定义范围画像；时长/到达/离开按天趋势曲线和等长周期比较
- 多活动按周提醒、通知 Action、完成/放弃闭环
- Screen Time protocol 与无 entitlement Stub
- SwiftData 本地持久化及 Repository 隔离

## 尚未实现

- CloudKit、自建服务器、AI 文案
- FamilyControls/ManagedSettings/DeviceActivity 与 App Shield
- 连续定位轨迹、复杂催促策略
- iPad 专用布局与英文资源

## 测试结果

- Xcode 26.4.1，iPhone 17 Pro / iOS 26.4.1 Simulator
- Clean build：成功
- Unit tests：33 passed，0 failed，0 skipped
- 模拟器安装与首屏启动：成功

## 当前风险与下一阶段

- Always Location、真实围栏后台唤醒、强制结束 App 后行为需要使用当前 Bundle ID `com.chronora.time.trace` 完成签名和真机验证。
- iOS 不保证所有通知消失场景产生 dismiss callback，不能自动把未知情况标成 ignored。
- 下一阶段优先做真机矩阵验证、定位权限降级提示、数据导出/备份，再评估 CloudKit 与 Screen Time entitlement。
