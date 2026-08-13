# ShotPaste macOS 版 UI/UX 优化方案

> 目标：达到商业级截图/录屏工具（CleanShot X、Shottr、Screen Studio）水准的用户体验。
> 本文档只定方案，不含实现。依据为对 `platforms/mac/ShotPaste/` 全部 7 个模块的源码级交互分析。

## 一、总体诊断

工程底子扎实（状态机严谨、多屏遮罩、渲染管线成熟、Reduce Motion 已有支持），差距集中在四个跨模块共性问题：

| 共性主题 | 典型表现 | 波及模块 |
| --- | --- | --- |
| **反馈闭环缺失** | 截图/保存/停止录屏/删除/登录项等失败全部静默，只写日志 | 全部 7 个模块 |
| **破坏性操作无安全网** | Esc 一键丢弃标注、删除录制无确认、卡片到期文件直接物理删除、录制中退出 App 无确认 | Annotate / Recording / QuickAccess / App |
| **可发现性差** | 所有快捷键不可见、OCR 藏三步、菜单栏只有两个功能项、无新手引导 | 全部模块 |
| **键盘流断裂 / 无障碍空白** | 历史无方向键导航、卡片面板不能成为 key、⌘Z 依赖画布焦点、VoiceOver 标签大面积缺失 | History / QuickAccess / Annotate / Preferences |

## 二、P0 —— 反馈闭环与数据安全（最高优先，丢内容类风险）

### P0-1 建立统一的失败反馈规范
- **问题**：失败静默遍布全模块——捕获准备失败（`CaptureViewModel.swift:382`）、截图保存失败（`InlineAreaAnnotateSession.swift:513-525`）、停止录屏失败（`RecordingCoordinator.swift:635`，整段录像丢失）、Quick Access 保存失败后卡片已被移除（`QuickAccessManager.swift:1133`）、历史删除失败（`HistoryWindowController.swift:221`）、登录项注册失败（`PreferencesLoginItemManager.swift:27`）、GIF 转换失败仅闪 2 秒（`RecordingCoordinator.swift:732`）。
- **方案**：
  1. 定义全局「错误反馈协议」：任何用户发起动作的失败必须走 `AppToastManager` 错误 toast（已有组件），附可执行恢复动作（重试 / 打开设置 / 打开诊断）。
  2. `OneShotCoordinator.finish` 对 `.failure`（除 `.cancelled`）统一兜底弹错。
  3. 写盘成功后再关闭标注现场；保存目录权限被拒时在原现场提供「重新授权文件夹」入口，不丢标注。
  4. 录屏停止失败时尝试抢救临时文件并明确告知；GIF 失败持久标记 + 一键重试。
  5. 登录项失败回滚 toggle 并提示（含 macOS `requiresApproval` 引导）。

### P0-2 破坏性操作保护
- **问题**：Esc 在标注阶段一键丢弃全部标注且无确认（`InlineAreaAnnotateSession.swift:831`，`hasUnsavedChanges` 状态存在却未使用）；录制中点垃圾桶无确认；Quick Access 删除/到期直接物理删除临时文件（`QuickAccessManager.swift:993、1245`）；录制中 Quit 直接 terminate（`AppStatusBarController.swift:608`）。
- **方案**：
  1. **Esc 层级化**：统一语义为「逐级回退」——取消选中 → 退出子模式（OCR 框选/文本编辑）→ 有标注时确认「放弃标注？」→ 退出会话。消除当前画布焦点不同导致 Esc 行为分裂的问题。
  2. 录制删除超过阈值时长（如 10s）需确认；Quick Access 删除统一进废纸篓或给短时「撤销」toast。
  3. 卡片到期消失 ≠ 文件删除：默认保留进历史，或在首用引导中明确告知。
  4. 实现 `applicationShouldTerminate`，录制/滚动截图进行中退出弹确认（保存/放弃/取消）。

### P0-3 权限被拒路径闭环
- **问题**：屏幕录制权限被拒后按热键毫无解释（`CaptureViewModel.swift:258`，系统不再弹窗）；权限页授予屏幕录制后 macOS 需重启 App 才生效但 UI 无提示。
- **方案**：检测 denied 状态弹引导面板（说明 + 「打开系统设置」按钮），授予后自动继续本次捕获；权限页对需重启的权限显式标注「重启后生效」。

## 三、P1 —— 可发现性与键盘流

### P1-1 快捷键可见化（成本最低、收益最大）
- **问题**：全 App 快捷键只存在于 keyDown 代码里——截图工具栏 tooltip 无 Enter/⌘S/⌘C（`InlineAreaAnnotateWindow.swift:1923-1985`）、录屏浮条四个全局快捷键零提示、历史面板 ⌘C/⌘E/Delete 不可发现。
- **方案**：统一规范「tooltip = 名称 + 快捷键」（Done ↩、Copy ⌘C…）；录屏状态栏按钮、历史卡片 hover、空状态均附快捷键徽标；空状态页附快捷键速查。

### P1-2 键盘操作补齐
- **历史面板**：方向键/Tab 移动选中并自动滚动可见（剪贴板工具核心场景：呼出 → 方向键 → Enter）；修复 compact 模式 Delete/⌘A 被静默吞掉（`HistoryFloatingPanel.swift:102` + `HistoryFloatingContentView.swift:846`）。
- **标注**：工具单键切换（R/O/T/A…，对标 Shottr）；⌘Z/Delete/方向键上收到 Session 层统一处理，不再依赖画布焦点（当前表现为「撤销经常失灵」）；方向键微调选区。
- **One Shot 选区**：`1-4` 切模式、方向键 1px/10px 调整；Esc 层级回退（见 P0-2）。
- **Quick Access 卡片**：面板可成为 key 或提供局部快捷键（Enter 复制、Esc 关闭），补 VoiceOver 标签。

### P1-3 窗口吸附捕获（功能缺口）
- **问题**：选区只有自由拖拽，无悬停窗口高亮 + 单击选窗口的能力；快照数据已有窗口列表（SCShareableContent 预取），成本低收益高。
- **方案**：armed 阶段命中检测顶层窗口，hover 高亮、单击选中窗口 frame，拖拽回到自由选区（对标 macOS 原生截图 Space 键）。

### P1-4 新手引导与入口扩展
- **问题**：全库无 Onboarding 组件，首启只跳权限页；菜单栏只有 One Shot/History 两个功能项；OCR 需「框选 → 点 OCR → 再框子区域」三步。
- **方案**：
  1. 一次性欢迎/功能导览窗口（版本号控制，复用 `PermissionGuideLaunchPolicy` 模式），覆盖：菜单栏图标位置、全局快捷键、选区后三种模式。
  2. 菜单栏菜单扩展常用动作分组（截图/滚动/录屏/历史/检查更新/关于），「停止录制」项显示快捷键。
  3. OCR 提供 armed 阶段直达入口（快捷键或顶部 Tab），复制成功默认轻量反馈。
  4. 修复崩溃报告入口死代码（`reportProblemAction` 从未被菜单绑定），重启后按 `didDetectCrash` 条件展示。

### P1-5 设置信息架构
- **问题**：7 个顶级标签 + 截取页内嵌分段选择器，60+ 设置项无搜索、无 ⌘1-7 切换；「截取」页单文件 1016 行、40 个设置项。
- **方案**：迁移到 `NavigationSplitView` 侧边栏 + 设置内搜索直达（对标 macOS 系统设置）；截取页拆为截图/录制/标注分组；快捷键页顶部加冲突汇总条。

## 四、P2 —— 视觉一致性与反馈打磨

1. **统一 motion token**：当前动画曲线混用（0.15s easeInOut / 0.16s easeOut / spring 多组参数 / 自定义 cubic-bezier），收敛到共享动画常量；补齐工具栏/属性条出现的过渡动画（当前 opacity 硬切）。
2. **统一 design token**：`Spacing`/`Typography` 已定义但快捷键页、截取页、TooltipView 等大量硬编码字号/间距；圆角有 7/8/16/20 多种。逐步收编。
3. **倒计时与状态可见**：Quick Access 卡片加底部倒计时进度条（消除「截图何时消失」焦虑）；录屏准备态消费已埋点的 `isPreparingToRecord`，加可选 3-2-1 倒计时；暂停状态在遮罩区复用现有 `RecordingRegionOverlayGuidance` 显示「已暂停」；菜单栏处理中状态从「菊花」升级为带语义/可取消的菜单项。
4. **放大镜全程可用**：当前只在 armed 阶段出现（`InlineAreaAnnotateWindow.swift:831`），拖拽/调手柄时恰恰最需要像素级对齐。
5. **本地化收口**：数据库恢复弹窗英文硬编码（`ShotPasteApp.swift:202`）、历史搜索占位/时间筛选硬编码、菜单栏 `||` ASCII 暂停符、德/俄长文本截断（固定宽 238pt 搜索框、contextPill maxWidth 142）。
6. **工具栏出口可达**：标注工具栏超宽后完成/取消按钮藏进无指示的 ScrollView（`InlineAreaAnnotateWindow.swift:1904`），出口按钮固钉右端不参与滚动。
7. **录屏删除确认/撤销、重录保留全部选项**（`restartRecording` 丢失 outputMode/highlightClicks/showKeystrokes）。
8. **提示组件规范**：`hint()` 的 hover popover 短文本改用原生 `.help()`；popover 校验错误常驻至用户修正（当前 4 秒自动消失）。

## 五、P2 —— 无障碍基线

- SettingRow 的 `Toggle("").labelsHidden()` 统一注入 `accessibilityLabel(title)`（VoiceOver 目前只读「开关」）。
- 历史卡片、筛选 pill、Quick Access 卡片、录屏标注工具条、快捷键录制器补 label/hint/trait。
- 标注工具栏建立 Tab 焦点链 + focus ring。
- 菜单栏计时器给稳定 accessibilityLabel，避免逐秒播报。
- 快捷键录制器补显式「清除」按钮与录制态朗读。

## 六、P3 —— 效率功能补齐（对标商业工具）

| 功能 | 参照 | 说明 |
| --- | --- | --- |
| 重复上次选区 | Shottr/CleanShot | 记住上次 selectionRect，一键同区截图 |
| 画布缩放/平移 | Shottr | 标注时 ⌘+/⌘-/⌘0、双指缩放、Space 平移 |
| 尺寸标签可编辑 | Shottr | 点击输入精确 W×H |
| 纯内存钉图 | CleanShot | 钉屏不强制落盘（当前先写文件再钉） |
| 二维码识别 | CleanShot/Shottr | OCR handoff 后加 CIDetector QR 分支（FEATURES 宣称支持但 Mac 模块内无实现） |
| 录屏标注 undo/工具快捷键 | — | ⌘Z + 数字键切工具 |
| 卡片「在编辑器中打开」 | CleanShot | Quick Access 双击进入内置标注而非外部打开 |
| 屏幕共享时隐藏卡片 | CleanShot | 会议共享时卡片不弹出 |
| 填充色属性条编辑 + 自定义取色 | — | `supportsQuickFillColor` 恒 false，颜色仅 8 固定色 |
| 历史搜索增强 | Paste | `type:`/日期语法、结果计数 |
| 自动更新 | Sparkle | 当前发现新版仅跳浏览器 |

## 七、实施路线建议

- **第一阶段（止血）**：P0 全部 + P1-1 快捷键 tooltip。全部是点状改动，不动架构，直接消除「丢内容 + 静默失败」两类最伤口碑的问题。
- **第二阶段（键盘流）**：P1-2/1-3/1-5。历史方向键导航、标注工具快捷键、窗口吸附、设置搜索。
- **第三阶段（一致性）**：P2 视觉/动效/本地化收口 + 无障碍基线。建议先立 token 规范再逐模块收编。
- **第四阶段（增值）**：P3 效率功能，按用户反馈排期。

## 八、需产品决策的开放问题

1. crop/watermark/mockup 工具模型与属性条已就绪但工具栏无入口——删死代码
2. Quick Access 卡片到期默认行为：保历史（推荐）还是删文件？——保历史
3. 录屏中 Esc 语义：停止并保存 / 丢弃 / 可配置？——丢弃
4. 历史面板失焦即关 vs 提供 pin 常驻（expanded 模式建议 pin）——pin 常驻
