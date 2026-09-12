# 时光落点发布

在当前项目目录只需执行：

```bash
./appstore.sh
```

无需 export 环境变量，也无需手动指定版本、构建次数或 Git 基线。依赖缺失时入口自动运行 Bundler 安装；当前机器已经配置完成。

入口会展示当前 Bundle ID 和 commit，提供三个选项：

1. 继续当前 commit 到 TestFlight（默认）。
2. 继续当前 commit 到 App Store 审核。
3. 查看当前 commit 进度。

## 按 Bundle ID + commit 断点续跑

同一 App、同一个完整 commit SHA 复用已有发布记录：

- 已生成说明：复用，可在终端选择编辑。
- 已归档：跳过归档；若导出失败，只重试导出。
- 已导出 IPA：校验后复用，不重新构建。
- 已上传并处理成功：跳过上传。
- 更新说明未变化且已填写：跳过资料写入。
- 已提交审核：跳过提审。

只在当前 commit 没有发布记录时新建构建。Apple 已上架的版本自动递增补丁号；已有更高的可编辑版本则沿用。正在审核或等待发布时，准备新版本会停止。

应用源码有未提交改动时先停止，要求提交后执行，避免一个 commit 对应多份源码。源码范围由 `source_paths` 配置。不同 commit 不复用彼此的构建，不同 Bundle ID 的记录也相互隔离。默认从该 App 上一次成功上传的 commit 生成差异说明，首次使用则取配置中的 `initial_base`。

更新说明来自提交标题，需要在脚本展示时核对；英文或内部实现标题可选择 `e` 打开文本编辑器改成用户文案。文案为空时必须填写。选择审核流程后，输入 `submit` 才执行资料写入及审核提交；审核通过后手动发布。

上传中断且结果不明时，脚本先查询 Apple：找到相同版本/构建则补完处理，不重复传包；尚未出现则保留进度并提示稍后重试。明确无效的构建需要修复代码并创建新 commit。提交中断时也会核对同一构建是否已进入审核。

## 本地配置

全部本机配置和私钥集中在项目根目录的 `appstoreConfig/`：

- `config.json`：Apple API 标识、私钥文件名、Ruby/Xcode 路径、项目、scheme、Bundle ID、文案语言、源码目录、初始 Git 基线及产物位置。
- `AuthKey_*.p8`：Apple 私钥，权限 600；目录权限 700。
- `ExportOptions.plist`：导出方式、开发团队及签名设置。
- `.run.lock`：入口并发锁。

`bundle_id` 支持具体值，也支持 `auto`。入口从本项目的 Xcode scheme 查询实际 Bundle Identifier；显式配置与项目不符时停止，`auto` 则直接使用项目值。迁移到其他项目时使用该项目的 `appstoreConfig`，配置其 project、scheme、source_paths 和导出签名信息。

`appstoreConfig/` 已加入 `.gitignore`。入口还会检查目录是否被错误地跟踪；一旦发现会停止，不会打印私钥内容。忽略目录不等于加密，需自行妥善备份，不要强制 git add 该目录。

发布产物和分阶段状态保存在 `release_root/<Bundle ID>/<版本>/attempt-<序号>/`。默认位于 `~/Library/Developer/TimeTraceReleases`，避免 Documents/iCloud 添加 FinderInfo 属性造成签名失败。入口兼容并核验本项目首次上传的旧目录记录。

只检查本机配置，不连接 Apple、不构建、不上传：

```bash
./appstore.sh --check
```

## 开发验证

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
ruby Scripts/tests/release_version_test.rb
ruby -c fastlane/Fastfile
bash -n appstore.sh
git diff --check
```

内部 `Scripts/release.py` 和 `fastlane/Fastfile` 提供分阶段执行能力；日常只使用根目录 `appstore.sh`。上传 TestFlight、Apple 处理完成、提交审核、审核通过是不同阶段。
