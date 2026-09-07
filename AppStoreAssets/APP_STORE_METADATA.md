# 时迹 · App Store 资料（简体中文）

## 产品页

**副标题**

到达即记录，离开即结束

**主要类别 / 次要类别**

效率 / 生活

**年龄分级建议**

4+（应用不含不当内容、广告、用户生成内容或医疗建议）

**推广文本**

自动记录抵达与离开，让每一段专注时光都有迹可循。

**描述**

时迹是一款以地点为线索的时间记录工具。设置常去的工作地点、图书馆或健身房后，抵达时自动开始记录，离开时自动结束，无需反复打卡。

- 自动记录地点停留时长，减少手动操作
- 在历史中回顾每天的时间投入和异常记录
- 通过统计查看累计时长、到达与离开时间趋势
- 支持为不同地点设置类型和围栏半径

隐私优先：时迹只记录你进出已设置地点的事件，不保存连续移动轨迹。数据默认保存在本机；开启 iCloud 同步后，仅同步至你的私人 iCloud 数据库。

**关键词**

时间记录,自动记录,地点围栏,工时,学习,运动,专注,时间统计,日历

**技术支持网址**

https://github.com/huangbo-me/timetrace/issues

**营销网址**

https://github.com/huangbo-me/timetrace

**版权**

© 2026 Bo Huang

## 审核资料

**登录信息**

不需要登录。

**审核备注**

提交前请将以下英文内容粘贴到 App Store Connect 的“App Review Information → Notes”，并在 Resolution Center 回复中附上真机录屏。方括号内容必须替换为本次提交的真实设备、系统版本及录屏链接。

```text
Screen recording
A screen recording captured on a physical [iPhone model] running iOS [version] is attached in Resolution Center and is also available at: [unlisted video URL].

The recording begins by launching the app and demonstrates the standard flow: completing the initial place setup, granting location and notification permissions, creating and viewing a place-based geofence, viewing Today, History, and Insights, creating a local reminder, and reviewing iCloud sync status in Settings.

App purpose and target audience
TimeTrace (时迹) is a personal, place-based time-recording app for individual users, including office workers, students, and people tracking time spent at regular places such as workplaces, libraries, or gyms.

Users create one or more places and choose a geofence radius. When the device enters or exits a configured place, the app records the corresponding time session. Users can also review, correct, and manually add records. The app helps users reduce manual time tracking while keeping a clear history and summary of time spent.

Setup and access instructions
No account registration, login, or demo credentials are required.

1. Launch the app.
2. During onboarding, create a place by selecting a location on the map or using the current location.
3. Allow location access. “Always Allow” is needed for background geofence-based automatic recording.
4. Allow notifications to receive optional local entry, exit, and reminder alerts.
5. Use the Places tab to add or edit places; use Today, History, and Insights to review records and statistics.
6. The app remains usable locally if the reviewer is not signed in to iCloud. iCloud sync is optional.

External services, tools, and platforms
The app does not use third-party SDKs, advertising networks, analytics services, authentication services, payment processors, AI services, or external user-content services.

Its core functionality uses Apple system frameworks and services:
- Core Location for circular geofence monitoring and optional current-location selection.
- MapKit and Apple Maps data for map display and place search.
- UserNotifications for local reminders and optional geofence entry/exit notifications.
- SwiftData for on-device storage.
- Optional Apple CloudKit private database sync through the user’s own iCloud account (container: iCloud.com.chronora.time.trace).

Regional availability
There are no intentionally different app features, content catalogs, prices, or user flows by region. The app is currently presented in Simplified Chinese. Map search results can vary according to Apple Maps availability and data in the user’s region; core local recording functionality is otherwise the same.

Regulated industries and third-party material
The app is not a regulated-industry service and does not provide medical, financial, legal, or other regulated advice. It does not distribute protected third-party content.
```

**真机验收清单**

1. 在最新 iOS 的实体 iPhone 上从主屏幕开始录屏并启动新安装的 App。
2. 完成首次地点设置；允许“使用 App 期间”和后续的“始终允许”定位权限，以及通知权限。
3. 验证地点保存、今日记录、历史、统计、提醒和设置页 iCloud 状态均可正常进入。
4. 单独进行实际进入和离开围栏的测试：确认后台唤醒后的记录与本地通知；不要以模拟器结果代替真机结论。
5. 若要在 Notes 放录屏链接，使用审核员无需登录即可访问、不会过期的非公开链接；同时在 Resolution Center 上传原始录屏文件。

## App 隐私申报

- 跟踪：否
- 收集的数据：无（数据仅保存在设备上；如用户启用 iCloud，同步至用户私有的 iCloud 数据库，开发者不可访问）
- 隐私政策网址：**待发布**。必须在 App Store Connect 填写后才能提交审核。

## 尚需用户确认

1. 审核联系人的名字、姓氏、电话号码与邮箱。
2. 公开的隐私政策网址；可以将本仓库新增的隐私政策发布到 GitHub 后使用其公开链接。
3. 提交审核所用的构建版本；当前版本页尚未关联构建。
