# Ark Novel 开发规范

Ark Novel 是轻小说文库（wenku8）的第三方 Flutter 客户端，主要面向 Android 和 macOS。这是单人项目，会同时用多个 AI 工具开发，所有工具都遵守这份规范。

如果仓库根目录有 `AGENTS.local.md`（不入库，放本机路径、设备等信息），先读它。

回复用中文，讲清楚。

## 常用命令

```bash
flutter pub get
flutter analyze
flutter test

# 编译都要指定入口；Android 还要加 cronetHttpNoPlay
flutter run -t lib/next/main.dart --dart-define=cronetHttpNoPlay=true
flutter build apk --release --target-platform android-arm64 --dart-define=cronetHttpNoPlay=true -t lib/next/main.dart
flutter build macos --release -t lib/next/main.dart
flutter build windows --release -t lib/next/main.dart
```

Flutter 版本是 3.47.4，和 `.github/workflows/check.yml` 保持一致。

环境跑不起来时，停下来说明哪一步失败，不要自己另搭一套环境绕过去。

## 项目结构

- `lib/next/`：应用代码，入口是 `lib/next/main.dart`（`lib/main.dart` 只作转发）
- `test/`：测试，改了逻辑就补对应的测试
- `tool/`：开发辅助工具

代码风格：格式化宽度 160，但老代码没有统一格式化，只格式化自己改的行，**不要对整个文件跑 `dart format`**。

## 开发流程

1. 先说明理解和大致方案，等确认后再改。方案被修改后，重新复述并再次确认。
2. 改完后实际测试，并如实说明测过什么、没测什么。
3. 用户说“开 PR”后，自动完成下面的全部步骤，不用再问：

```bash
git fetch origin
git switch -c <工具名>/<主题> origin/main   # 动手改代码前就开好分支
git commit -m "fix: 修复书架同步失败"
git push -u origin HEAD
gh pr create --base main --title "fix: 修复书架同步失败" --body "改了什么、怎么测的"
gh pr merge --auto --merge --delete-branch --body ""   # 合并提交的正文留空，原因见下面「版本和发版」
```

分支前缀用工具名：`claude/`、`codex/`、`antigravity/`、`kiro/`。PR 只提到本仓库的 `main`，用合并提交。CI 通过后 GitHub 会自动合并；CI 失败就修好再推，修不好再找用户。

只有用户说了才提交、推送、开 PR。用户明确说“编译”“提交推送”“merge”时直接做。

## 版本和发版

版本由 release-please 自动管理，流程是：PR 合并后，机器人开发版 PR，改好版本号和 `CHANGELOG.md`，CI 通过后自动合并并打 tag。

提交信息决定版本怎么变：

| 改动 | 提交信息 | 版本变化 |
|---|---|---|
| 修复、小功能（默认） | `fix: 说明` 或 `feat: 说明` | `1.0.0` → `1.0.1` |
| 改动比较大 | 再加一行 `Release-As: 1.1.0` | `1.0.1` → `1.1.0` |
| 第 1 位 | 同上，**只有用户明确说了才升** | `1.1.0` → `2.0.0` |
| 只改文档、CI、测试 | `docs:`、`ci:`、`test:` | 不发版 |

- 改动是否算“比较大”由 Agent 判断，并在 PR 说明里写明原因。
- 写 `Release-As` 前先看 `main` 上的 `pubspec.yaml`，用当前版本第 2 位加 1、第 3 位归零的版本号。
- 构建号（`+` 后面的数字）每次发版自动加 1。
- 改了 `lib`、`android`、`macos`、`windows` 或 `assets` 却没有 `fix:` 或 `feat:` 提交，CI 会失败。
- 更新日志里每一条就是一个 `fix:` / `feat:` 提交的第一行，所以一项用户能感觉到的改动单独提交一次，第一行写给用户看；细节写在正文里，不进日志。
- 合并 PR 时 `--body ""` 不能省：release-please 会把合并提交正文里的每一行 `fix:` / `feat:` 也当成一次提交，仓库默认把 PR 标题写进正文，日志里就会和原提交重复一条（1.0.4～1.1.2 每条都重复就是这个原因）。

## 边界

**总是做**
- 从最新的 `main` 开分支
- 提交前跑 `flutter analyze` 和 `flutter test`

**先问**
- 新增依赖
- 改数据库结构、备份格式等会影响用户数据的地方
- 改仓库设置

**绝不做**
- 把 APK、macOS 包等安装包放进仓库、Release、CI 产物或任何公开的地方；只能装到用户手机或直接交给用户
- 手改 `pubspec.yaml` 的 `version`、`CHANGELOG.md` 或 `.release-please-manifest.json`
- 直接推 `main`，或动其他工具的分支
- 填写、保存或复述文库账号、WebDAV 密码，这些由用户自己在 App 里输入
- 用不同签名覆盖安装，这会卸载 App 并清空数据
- 把本机路径、设备号、令牌写进仓库（仓库是公开的）
- 更改仓库的公开或私有状态
- 向上游或其他仓库开 PR，除非用户审阅过草稿并同意
