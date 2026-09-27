# Wave 迁移更新日志

记录把 Wave fork 的功能迁到这个 Ghostty fork（只做 macOS 版）的进度，最新的条目在最上面。
功能编号对应 `WAVE-MIGRATION.md`。

验证状态：**待 CI 验证** → **CI 构建通过** → **已实机验证**。

## 2026-09-27 · 功能 2：sage 终端配色

**做了什么**

- 新增两个内置主题 `Sage Dark`（与深色外壳一致的 sage "ink" 配色）和 `Sage Light`
  （ANSI 颜色加深、黄色改成赭色），颜色取自 Wave 的 `default-dark` / `default-light`。
  `ghostty +list-themes` 里能看到，也可以单独选用。
- macOS 版默认跟随系统深浅色：系统切换外观时终端配色跟着切换。
- 光标颜色、光标下文字颜色、选区颜色、搜索高亮颜色都跟着配色走：
  - 深色：匹配项 `#c4a000`，当前匹配 `#e0bd72`，文字用底色 `#181f1b`。
  - 浅色：匹配项 `#8a6a12`，当前匹配 `#b4453c`，文字用底色 `#fcfdfa`。
  - 选区：Wave 是半透明叠加，Ghostty 的 `selection-background` 不支持透明度，
    所以预先混合到底色上（深色 `#384635`，浅色 `#cfdbd2`），选中文字保持原色。

**配置项**

- 没有新增配置键。macOS 版的默认值相当于 `theme = light:Sage Light,dark:Sage Dark`。
- 在自己的配置里写 `theme = …` 会整体替换这个默认值；写 `theme =`（空值）则回到
  Ghostty 原本的配色（不用任何主题）。
- `background`、`foreground`、`palette` 等单独设置的颜色仍然覆盖主题里的值。

**实现方式**

- 主题文件在 `src/themes/`，构建时装进 `Ghostty.app/Contents/Resources/ghostty/themes/`，
  不受 `emit-themes` 开关影响。
- 默认值放在 `src/config/macos-defaults.ghostty`，装进 `Resources/ghostty/`；app 读取配置时
  先加载它，再加载用户配置，所以用户的任何设置都能覆盖它。没有改 Zig 里 `theme` 字段的
  默认值——那样 `theme =` 会重置成 sage 而无法取消，也会影响核心的单元测试。
- 只有读取用户默认配置文件时才加载这个默认值；显式指定配置路径时（单元测试的
  `TemporaryConfig`、UI 测试用的 `GHOSTTY_CONFIG_PATH`）不加载，保持上游默认，
  因为有几个 UI 测试假设终端是 Ghostty 原本的深色底。

**提交：** `68f9429`、`a8a885f`

**验证状态：** CI 构建通过（run 36323408224，提交 `ec9fdb8`）。CI 用包内的
`ghostty +validate-config` 校验了默认值文件和两个主题文件，没有报错。
配色在 app 里的实际效果、跟随系统切换还没有实机验证。

**已知问题 / 未实现**

- 命令行 `ghostty +show-config` 不加载这个默认值，显示的 `theme` 仍为空；实际 app 里是生效的。
- 同时使用不同的深浅色主题时，Ghostty 会把 `window-theme = auto` 当作 `system` 处理（上游行为）；
  上游已知 `macos-titlebar-style = tabs` 在切换主题时标题栏 tab 不会刷新。
- Wave 的搜索高亮只画边框，Ghostty 的搜索高亮是填充底色，所以用配色里的颜色做底色、底色做文字色。

## 2026-09-27 · 功能 1：tab 颜色标记

**结论：Ghostty 已覆盖，没有写代码。**

**现有功能（Ghostty 自带）**

- tab 右键菜单末尾有颜色色板：无 + 蓝、紫、粉、红、橙、黄、绿、青、石墨 9 种系统色，
  当前选中的带勾。
- 选中后 tab 标题旁显示一个色点；颜色随窗口恢复保留，撤销关闭 tab 时也会恢复；
  命令面板里的 tab 条目同样显示颜色。

**与 Wave 的差异（未处理）**

- Wave 用 7 种偏灰的 sage 配套色，并给整个 tab 底色着色（普通 22%、当前 38%、悬停 32%）；
  Ghostty 用系统色，只显示色点。属于外观问题，留到功能 4（外壳配色）/ 功能 8（胶囊 tab 栏）
  时再决定要不要对齐。

**配置项：** 无

**提交：** 无代码提交（只更新了文档）

**验证状态：** 不涉及（上游现有功能）

## 2026-09-27 · P2：fork 的构建流水线（CI）

**做了什么**

- 新增 `.github/workflows/wave-build-macos.yml`（Actions 页面里叫 "Build macOS (fork)"）：
  手动触发，在 GitHub 托管的 `macos-26`（Apple Silicon）runner 上用 Xcode 26 构建 arm64 的
  `Ghostty.app`，打成 zip 作为 artifact 上传（保留 30 天）。
- 构建步骤与上游一致：先用
  `zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=native`
  生成 GhosttyKit，再用 `xcodebuild` 构建 app。
  Info.plist 里写入提交哈希（"关于"窗口可见）和构建号（提交数）。
- 签名：没有配置签名密钥时，用上游本地构建用的 `ReleaseLocal` 配置，保持 ad-hoc 签名；
  配置了 `PROD_MACOS_CERTIFICATE` 等密钥时，改用 `Release` 配置并按上游方式做 Developer ID 签名
  （不做公证）。
- 构建完成后用包内的 `ghostty +validate-config` 校验 fork 自带的配置文件（默认值文件和
  `src/themes/` 里的主题），这些文件只在运行时读取，构建本身发现不了写错的键。
- 最后一步跑 `swiftlint lint --strict`；放在上传之后，lint 失败时仍能拿到安装包。

**怎么用**

- Actions → Build macOS (fork) → Run workflow，分支选 `feat/wave-migration`（按钮不出现时见下方已知问题）。
  可选填 Xcode 版本（如 `26.6`），留空则用 runner 上最新的 Xcode 26.x。
- 下载 artifact，解压两层 zip 得到 `Ghostty.app`。首次打开前需要去掉隔离标记：
  `xattr -dr com.apple.quarantine /path/to/Ghostty.app`。

**配置项：** 无（可选的仓库 secrets：`PROD_MACOS_CERTIFICATE`、`PROD_MACOS_CERTIFICATE_PWD`、
`PROD_MACOS_CERTIFICATE_NAME`、`PROD_MACOS_CI_KEYCHAIN_PWD`）

**提交：** `c87aebb`、`7a0a6a0`、`ec9fdb8`

**验证状态：** CI 构建通过。run 36322596272（提交 `7a0a6a0`）和 run 36323408224
（提交 `ec9fdb8`）全部步骤成功：GhosttyKit 约 5–8 分钟，app 约 2 分钟，整次约 9–12 分钟；
`codesign --verify --deep --strict` 通过；SwiftLint 0.65.1 检查 196 个文件 0 违规。
产物能否在 Mac 上正常打开还没有实机验证。

**已知问题**

- GitHub 只允许手动触发已"注册"的工作流，而只放在非默认分支上的纯 `workflow_dispatch`
  工作流不会被注册（触发时报 404）。所以加了一个只在这个工作流文件本身变更时生效的 `push`
  触发器，用来注册；push 事件下构建 job 直接跳过，不占用 runner。
  网页上的 "Run workflow" 按钮按 GitHub 文档要求默认分支（`main`）上有这个文件，所以可能不出现；
  这时可以用 `gh workflow run wave-build-macos.yml --ref feat/wave-migration`（或 API）触发。
- app 的 bundle ID 仍是 `com.mitchellh.ghostty`，和官方 Ghostty 共用偏好设置、配置目录；
  自动检查更新保持关闭，但手动"检查更新"会拉到官方版本并覆盖这个构建。
- 上游的 `Test`、`Nix` 工作流在 fork 上 push 时也会运行：大部分 job 因仓库判断被跳过，
  但两个汇总 job（"Required Checks"）没有仓库判断、用的是上游专用 runner，会一直排队直到超时。
  与本工作流无关，没有改动。
