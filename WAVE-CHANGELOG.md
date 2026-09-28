# Wave 迁移更新日志

记录把 Wave fork 的功能迁到这个 Ghostty fork（只做 macOS 版）的进度，最新的条目在最上面。
功能编号对应 `WAVE-MIGRATION.md`。

验证状态：**待 CI 验证** → **CI 构建通过** → **已实机验证**。

## 2026-09-28 · 功能 5：工具栏（tool rail）

**做了什么**

- 终端窗口最右侧新增一条 48pt 宽的竖向工具栏，在标题栏 / tab 栏下方，从上到下：
  - **Terminal**：在当前聚焦的终端右边新建分屏（等同菜单里的 Split Right，默认 ⌘D）。
  - **Files**：开关左侧栏（文件面板，目前是 P3 的空壳）。
  - **Git**：开关右侧栏（git 面板，目前是 P3 的空壳）。
  - 底部 **Settings**：打开配置文件（等同菜单里的 Open Config）。
- 按钮平时是灰色；鼠标悬停时图标变成该视图类型的颜色，并加一层同色浅底（13%）：
  文件是琥珀色、git 是橙色、终端用强调色（跟随 `macos-accent-color`），设置按钮用普通文字色
  和悬停底色。侧栏开着时对应按钮一直保持着色。窗口不是 key window 时这些颜色都变灰。
- 窗口高度不够显示全部文字标签时，自动只显示图标（悬停有提示文字）。
- 工具栏自己没有底色，画在窗口底色上：打开 `macos-window-vibrancy` 时毛玻璃会从工具栏后面透出来。
  它和终端之间有一条外壳分隔线。
- 点工具栏按钮不会抢走终端的键盘焦点（按钮设为不可聚焦）。
- 快速终端没有工具栏。

**配置项**

- 新增 `macos-tool-rail = true | false`，默认 `true`。关掉后侧栏仍可从 View 菜单开关。
  改配置后重新加载即可生效，不用重开窗口。

**实现方式**

- 工具栏是 SwiftUI 视图（`macos/Sources/Features/Sidebar/ToolRailView.swift`），和 P3 的侧栏一起由
  `TerminalSidebarsLayout` 排在终端右侧：左侧栏｜终端｜右侧栏｜工具栏。
- `window-width` 仍指终端列数，窗口默认宽度会加上工具栏的 48pt。

**提交：** `a94dfff`

**验证状态：** 待 CI 验证。没有实机验证。

**没做 / 已知问题**

- AI 按钮没加，等功能 11。
- Wave 工具栏右键菜单里的"编辑 widgets.json"没有对应物：Ghostty 的工具栏按钮是固定的，不能自定义。
- 悬停颜色、失焦变灰、标签自动隐藏的实际效果都没有实机确认。

## 2026-09-28 · P3：承载非终端面板（窗口级侧边栏）

**做了什么**

- 终端窗口左右各有一个侧边栏，放在分屏树之外：左边是文件，右边是 git（以后 AI 也放右边）。
  每个 tab 是一个独立窗口，所以每个 tab 各自开关侧栏。快速终端没有侧栏。
- 侧栏在标题栏 / tab 栏下方；隐藏标题栏样式下和终端一样顶到窗口顶部。
  打开侧栏时终端区整体变窄，分屏按比例一起缩，分屏树、分屏导航、拖拽、放大都不受影响。
- 拖动侧栏内侧边缘（5pt 宽）调宽度，最小 160pt；双击边缘恢复默认 260pt。宽度全局记住，
  新窗口沿用。窗口太窄时先压缩侧栏，终端区至少保留 160pt。开关不做动画。
- View 菜单新增 **Files Sidebar**、**Git Sidebar**，带勾选状态，不设默认快捷键
  （可在系统设置 → 键盘 → App 快捷键里绑定）。
- 侧栏跟随当前聚焦终端的 cwd（shell 集成通过 OSC 7 上报）；焦点移到侧栏时仍然记着
  最后一个聚焦的终端。
- 文件、git 两个面板在功能 10 / 9 之前是空壳：顶部标题栏显示面板图标和聚焦终端的 cwd
  （家目录缩写成 `~`，过长时截掉开头），正文是一段"还没实现、会在哪里打开"的说明。
  终端没有上报目录时标题栏显示 "No directory"。
- 标题栏代理图标（proxy icon）改用同一个 cwd 订阅：以前焦点离开终端时它会被清空，现在保留。
- 窗口恢复：侧栏状态（开着的面板、宽度）存进恢复状态的一个可选字段，旧存档读出来是侧栏全关；
  没有改恢复状态的版本号。撤销关闭 tab（⌘Z）也会带回侧栏状态。新窗口、新 tab 默认不开侧栏。

**配置项**

- 无。工具栏的配置项在功能 5。

**实现方式**

- `TerminalViewContainer` 里用 Auto Layout 把两个侧栏排在终端视图两侧，侧栏内容是各自独立的
  `NSHostingView`；`TerminalView.swift` 没有改。代码在 `macos/Sources/Features/Sidebar/`。
- `window-width` / `window-height` 仍然指终端的列数、行数，窗口默认尺寸会加上已打开侧栏的宽度。

**提交：** `31808c4`

**验证状态：** 待 CI 验证。没有实机验证。`TerminalRestorableTests` 里新增了两条断言
（旧存档解码后侧栏为空），但 CI 不跑 Xcode 单元测试，这两条没有运行过。

**没做 / 已知问题**

- 设计里说的"在侧栏按 Esc 回到终端"还没做：空壳面板里没有能获得焦点的内容，等功能 9 / 10
  有了真正的面板再加。侧栏关闭时如果焦点在侧栏里，会把焦点交还给终端（未实机验证）。
- 点击空壳侧栏会不会抢走终端的键盘焦点，取决于 `NSHostingView` 的行为，没有实机确认。
- ssh 到远程主机时，核心会丢弃远程发来的 OSC 7，侧栏显示的是 ssh 之前的本地目录。
- 面板内部状态（展开的目录、选中的提交、滚动位置）不随窗口恢复。

## 2026-09-27 · 功能 4：界面主题、sage 外壳配色与强调色

**做了什么**

- 界面主题：沿用 Ghostty 已有的 `window-theme`，没有新增配置键。它设置整个应用的外观，
  sage 终端配色（功能 2）和新的外壳配色都跟着它切换。
- sage 外壳配色：新增 `ChromePalette`，把 Wave 的 sage 基础色搬了过来：画布、面板、面板标题栏、
  弹出层、凸起控件、三级文字、分隔线、悬停 / 选中叠加、错误 / 警告 / 成功色、sage 强调色，
  以及文件、git、AI 三种视图各自的强调色。每个颜色都有深浅两套，按绘制时的外观取值；
  浅色版只重新定义基础色。这套颜色主要给后面的面板、标题栏、工具栏用，
  目前界面上能直接看到的是下面几处。
- 强调色：新增 `macos-accent-color`。Ghostty 自己绘制的强调色都改用它：命令面板（匹配字符、
  选中行、徽标）、分屏拖放提示、surface 高亮、进度条、tab 上的"重置缩放"按钮。
  设为 `system` 时跟随系统设置里的强调色，在系统设置里改了会立即跟着变。
- 窗口失焦：上面这些强调色在窗口不是 key window 时变成灰色（外壳的三级文字色），
  和 AppKit 自带控件一致。以后的聚焦描边和 tab 圆点也走同一套逻辑。
- sage 主题的分屏分隔线改用外壳分隔线色（深色 `#2b362e`、浅色 `#dbe0d6`）；
  进度条的错误 / 暂停色改用外壳的错误 / 警告色。

**配置项**

- 新增 `macos-accent-color = sage | system`，默认 `sage`。
- 界面主题用现有的 `window-theme = auto | system | light | dark`，默认 `auto`；
  由于 sage 默认主题分深浅两套，`auto` 实际等于 `system`。

**提交：** `085c40a`

**验证状态：** CI 构建通过（run 36325372727，提交 `7907e30`）：编译、签名校验、
`+validate-config`（含改动后的两个 sage 主题）和 SwiftLint 都通过。强调色、失焦变灰、
深浅色切换的实际效果没有实机验证。

**有意没改的部分**

- 原生控件（菜单、文本选择、系统按钮）始终用系统强调色，AppKit 不提供覆盖的办法。
- tab 右键菜单里的颜色色板和更新提示按钮保留系统强调色：它们属于原生菜单和上游的更新流程。
- 命令面板、搜索栏等浮层的底色仍是系统材质，没有换成 sage 面板色；
  等功能 5 / 6 有了新外壳之后再统一处理。

**已知问题**

- 系统强调色变化时靠两个通知（`NSColor.systemColorsDidChangeNotification` 和
  `AppleColorPreferencesChangedNotification`）触发重绘，没有实机验证过。

## 2026-09-27 · 功能 3：只在外框透出的毛玻璃

**做了什么**

- 新增配置 `macos-window-vibrancy`。打开后，窗口外框（标题栏和 tab 栏）透出 macOS 的
  under-window 毛玻璃材质，桌面在后面模糊可见；终端保持不透明，对比度不受桌面背景影响。
- 材质跟随窗口激活状态，窗口失焦时按系统规则变淡。
- 以后加的工具栏、侧边栏只要底色透明，也会透出同一层材质，不用再单独处理。

**配置项**

- `macos-window-vibrancy = true | false`，默认 `false`。

**实现方式**

- 打开时窗口改为非不透明、背景透明，在内容视图最底层放一个 `NSVisualEffectView`
  （材质 `.underWindowBackground`，混合方式 `.behindWindow`），并像上游的 glass 背景一样向上延伸到
  标题栏后面；透明标题栏样式不再给标题栏涂终端背景色。终端本身照常以不透明底色绘制。

**提交：** `abfb328`

**验证状态：** CI 构建通过（run 36324774238，提交 `abfb328`）：编译、签名校验和 SwiftLint 都通过。
毛玻璃的实际显示效果没有实机验证。

**已知问题 / 未实现**

- 只在 `macos-titlebar-style = transparent`（默认）以及 macOS 26 上的 `tabs` 样式下看得到；
  `native`、`hidden` 没有透明的外框，macOS 13–15 的 `tabs` 样式标题栏是自绘实色，暂不支持。
- 原生全屏时关闭；`background-blur` 为 macOS glass 样式时以 glass 为准；
  用"切换背景不透明度"强制不透明时也关闭。
- 同时设置 `background-opacity < 1` 时，终端本身也会半透明，那是 `background-opacity` 的行为。
- Ghostty 的分屏之间目前没有间隙，所以能看到材质的只有标题栏 / tab 栏这一条；
  功能 6 给分屏加外框和间隙之后，分屏之间也会透出。
- 非不透明窗口需要系统合成，可能有少量额外的 GPU 开销，没有测量。

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
