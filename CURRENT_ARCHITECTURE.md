# TimeTrace 当前架构审计

## 当前目录

- 审计路径：`/Users/akahuangbo/Documents/TimeTrace`
- 审计时目录为空：没有 Xcode 工程、Swift Package、Git 元数据、源码、资源或测试。
- 因此本次工作不是迁移或重构，需从最小 iOS App 骨架开始。

## 数据层与页面层

- 当前不存在数据模型、持久化实现、Repository、Service、ViewModel 或页面。
- 当前不存在可复用代码，也没有需要兼容的历史数据库 schema。

## 本机能力

- Xcode：26.4.1（Build 17E202）
- iOS SDK：26.4
- 可用模拟器：iPhone 17 Pro（iOS 26.4）等。
- `xcode-select` 当前指向 Command Line Tools；构建命令需临时设置
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，不修改全局设置。

## 需要新增的模块

- SwiftUI App 与依赖容器
- Activity、Session、Reminder、Analytics 领域模型
- SwiftData Repository
- Event Pipeline 与确定性 Session Engine
- CoreLocation Geofence 与 UserNotifications Action
- Screen Time 协议及 Stub
- Onboarding、Today、History、Insights、Settings 页面
- 单元测试与内存持久化测试

## 风险

- Always Location、真实围栏后台唤醒只能在完成签名的真机上最终验收。
- 用户强制结束 App、关闭“后台 App 刷新”或撤销定位权限会影响系统事件投递。
- 系统不保证所有通知消失场景都产生 dismiss callback；未确认的实例必须保持 unresolved。
- 暂定公司名为 `Chronora`，Bundle ID 为 `com.chronora.time.trace`；真机部署由 Automatic Signing 创建描述文件。
