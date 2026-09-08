# 工程复杂度审计与渐进重构方案

日期：2026-09-08。基线：codex/audio-recording-adapter，666ab8db250c7833401cde22096acd13b57ac26c。

本报告前七节保留 666ab8d 基线的静态审计结论，证据链接固定到该提交。审计开始时工作树干净。后续实施见第八节；不能把基线审计的“未验证”或历史行号当作当前实现状态。范围覆盖两个平台的产品代码结构、测试源码、构建入口、CI 和功能契约；重点追踪高风险调用链，未逐行证明全部功能正确。

## 1. 结论与判断标准

**项目存在明确的局部过度工程化和过度测试，但没有证据支持全盘架构重写或按比例削减测试。** 主要问题是旧实现没有退出、测试与真实执行路径脱节、同一事务和窗口行为有多个维护者，以及基础服务通过全局拦截承担了过宽职责。

最值得先做的工作：

1. 纠正测试信号：去掉同一次构建的重复执行，替换测试专用策略副本与源码字符串断言，修正 Windows 交互门禁的产物选择。
2. 移除 macOS 已不再用于产品的 Apple Speech 路线及内部旧接口兼容层。
3. 收敛 Windows Quick Access 显示重试与本地化全局改写，两者已有可追踪的行为风险。
4. 合并音频保存事务，明确转写任务的身份与父子关系。
5. 最后按职责拆分控制器和标注窗口，避免只把一个大文件切成多个仍共享全部状态的文件。

采用四个判据：是否服务当前产品契约；是否存在真实生产调用；同一事实是否有多个可写来源；测试是否能发现真实行为破坏。文件大小、接口只有一个生产实现、测试比产品代码多，都不能单独证明过度工程化。

## 2. 仓库规模与覆盖范围

统计只包含 Git 跟踪文件，不含依赖、构建目录、图片和 xcstrings/JSON 数据。物理行包含注释、空行；这些数字是定位线索，不是质量评分。

| 范围 | 文件数 | 物理行 | 口径 |
| --- | ---: | ---: | --- |
| macOS 产品 | 290 | 98,006 | ShotPaste 下 Swift |
| macOS 测试 | 125 | 27,498 | ShotPasteTests 下 Swift，含 helper |
| Windows 产品 | 136 | 28,615 | src 下 C# 与 XAML |
| Windows 普通测试项目 | 54 | 6,733 | C#，含 helper |
| Windows 原生 E2E | 15 | 6,705 | 6 个项目的 C# |
| 脚本 | 28 | 3,970 | shell（含 pre-commit）、PowerShell、Python、Swift |

macOS 有 1,208 个 test 方法声明；Windows 普通测试有 315 个 Fact/Theory 声明。参数化测试可以展开为多个用例，以上不是本次执行通过数。Windows Headless 合同子集涉及 9 个类、94 个测试方法声明。

macOS 测试/产品物理行约 28%；Windows 普通测试约 24%，加原生 E2E 约 47%。两个平台功能量、UI 写法和测试组织不同，这些比例不能作为按配额删测试的依据。L10n.swift 本身有 5,297 行本地化访问器，不能与业务状态机按相同行数阈值判断。

| 子系统 | 本次判断 | 重构方向 |
| --- | --- | --- |
| One Shot / 捕获 / 原生音视频 | 复杂度大体有产品与系统依据 | 保留统一选区入口、互斥、取消和恢复；缩小协调器职责 |
| 标注 | 职责集中，Windows 有重复状态 | 去重状态，再分离文档/编辑历史与输入交互 |
| 滚动拼接 | 算法、帧处理、准确率测试有明确用途 | 保留确定性回归和专项基准，不扩展通用框架 |
| 音频与转写 | 旧路线、接口兼容、保存事务与身份关联值得收缩 | 删除无生产入口实现，复用真实事务，显式任务关系 |
| Quick Access | 两端有重复流程；Windows 补偿机制尤为突出 | 窗口/卡片生命周期归一个 owner |
| 历史 / 剪贴板 / 数据恢复 | 数据安全逻辑总体必要 | 保留真实删除/恢复测试，不拿内存布尔值替代持久化验证 |
| 本地化 / 设置 | Windows 全局文字改写范围过大 | 只按显式 key 翻译产品文案 |
| Agent / OCR / 翻译 / 自动化 | 本次未发现应整体推翻的抽象 | 保留网络隔离、结构校验、权限/动作边界；后续按具体重复点优化 |
| 构建 / 测试 / CI | 有确定的执行重复与分层错位 | 同一目标执行一次，分开纯逻辑、原生与硬件证据 |

依赖清单也不显示通用应用框架泛滥：macOS 项目直接声明 Swift-WebP、GRDB；Windows 主要是录制、音频、图像、SQLite 与凭据保护依赖。Windows 的 5 个 interface 声明中，4 个用于 COM，只有一个文件操作业务接口。无需以删接口、删原生依赖为目标。本次未做依赖漏洞或许可证再审计。

## 3. 有证据的发现

### F1 · 高优先级：测试验证生产没有调用的策略副本

[AudioRecordingCoordinator.swift](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPaste/Features/AudioRecording/AudioRecordingCoordinator.swift#L50) 第 50–79 行定义事务步骤与删除策略，第 121–139 行定义流失败策略。全仓符号引用检索显示，这两组策略除定义外只被测试调用。

实际删除条件在 [AudioAdapterSessionStore.swift](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPaste/Features/AudioRecording/Services/AudioAdapterSessionStore.swift#L619) 第 619–637 行，实际流失败处理在 Coordinator 第 1314–1330 行。[PolicyTests](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPasteTests/Features/AudioRecording/AudioRecordingCoordinatorPolicyTests.swift#L22) 却在验证另一份布尔逻辑。生产门禁改变，副本测试仍可能通过。

**方案：** 删除不参与产品执行的策略与镜像测试，把保留的行为断言落在真实 Store 和 Coordinator 入口。若某项策略确实需要独立存在，先让生产路径使用它，再测试。已有被生产调用的 SaveToastPolicy 和 DisplayRecoveryPolicy 不属于此问题。

**验收：** 模拟保存未完成、历史写入失败、任务写入失败及开始过程中流中断，直接证明内部视频保留、停止只触发一次；不把“策略返回 false”视为文件未删除的证明。

### F2 · 高优先级：Apple Speech 路线已退出产品，复杂实现和测试仍保留

[LocalAudioTranscriber.swift](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPaste/Features/AudioRecording/Processing/LocalAudioTranscriber.swift#L146) 第 146–548 行夹杂 Speech 权限、识别引擎、异步桥和超时状态。第 560–562 行的默认实现已是 Volcengine，全仓未发现 SpeechFrameworkAudioRecognitionEngine 的生产实例。[功能契约](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/docs/FEATURES.md#L129) 明确当前流程不需要 Apple Speech 权限。

[Info.plist](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPaste/Resources/Info.plist#L24) 及各语言 InfoPlist.strings 仍保留 Speech 权限文案；测试也继续维护该旧路线。这里是历史实现与测试互相维持，而不是当前产品需要的多引擎架构。

**方案：** 移除不可达的 Speech 引擎、专属权限桥、错误映射和对应测试；收敛按具体引擎类型分支的编排。保留当前云转写所需的音轨提取、时间线、取消、有效音频与路径校验，不整文件删除。命名调整与逻辑删除尽量分开以便审阅。

**验收：** 云转写仍使用录制时账户快照；静音轨道不破坏另一轨道结果；取消、重启查询和清理不产生重复提交；Debug 运行不再有 Speech 授权入口。同步权限本地化和开发文档。

### F3 · 高优先级：源码文本断言替代了行为证明

[AppControllerFlowTests.cs](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/tests/ShotPaste.Windows.Tests/AppControllerFlowTests.cs#L75) 第 75–97 行按私有方法名截取 C# 文本，第 171–184 行按字符串位置证明输入分支顺序。第 188–202 行与 226–241 行对工具条拖动的断言几乎重复。[macOS 音轨测试](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPasteTests/Features/Recording/AudioAdapterTrackRoleIntegrationTests.swift#L64) 也用源码语句位置证明 writer 的调用顺序。

这类测试会在安全的重命名、方法提取后失败，却可能在对应代码不再执行时继续通过。读取 XAML 或资源本身并非错误：键完整性、禁止项和实际对比度有可检验的静态契约；问题是拿源码语句存在性证明运行正确。

**方案：** 逐条映射“断言 → 用户行为/缺陷”，先复用已有行为覆盖，确有空缺再加最小测试，然后删除语句与私有布局锁定。完全同义的工具条拖动断言只保留一处。颜色、图标、排版常量合并为场景/资源参数表，不每个常量建一个案例。不要新建通用源码分析器来维护这些断言。

**验收：** 提取方法或重命名局部字段不再迫使修改行为测试；破坏真正的停止、拖动、模式选择或保存逻辑时，对应测试仍能失败。

### F4 · 高优先级：Windows Headless 合同测试重复运行，门禁身份还有静态不一致

[build-windows.ps1](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/scripts/build-windows.ps1#L39) 第 46–53 行用互补过滤器执行普通测试与隔离组，合起来覆盖普通测试项目；第 64–67 行又调用 Headless parity。[test-windows-parity.ps1](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/scripts/test-windows-parity.ps1#L42) 第 43–45 行重新执行其中 9 个类、94 个测试方法声明，没有切换到另一种产品运行边界。

[CI](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/.github/workflows/ci.yml#L53) 对 Debug、Release 均走这条路径。因此每个配置都有一次可以确认的子集重复；这与有必要的 Debug/Release 身份差异验证要分开处理。未测量当前耗时，不能推导节省分钟数或加速比例。

同时，parity 脚本第 63 行默认查找 ShotPaste.exe，而 [Debug 身份](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/src/ShotPaste.Windows/Config/AppVariant.Debug.props#L5) 明确为 ShotPasteDebug.exe；CI 第 104 行运行交互任务时没有传 ProductExecutable。静态配置表明，干净 Debug 构建可能在进入真实交互验收前就找不到预期产物；本次未在 Windows 重现。

**方案：** 保持现有脚本为唯一入口，使 Headless 合同在一次验证中仅有一个执行 owner。完整构建已经得到结果时，summary 消费本次实际结果；单独调用 Headless 时仍运行相应测试。结果须包含配置、产物及本次运行标识，不能读取旧 summary 充数。产物路径由现有 AppVariant/MSBuild 属性解析，CI 显式传递正确产物。

先去掉确定重复，保留原生内存较重测试的进程隔离。进一步精简 Release 重复业务测试前，先查配置分支与发布门禁；不直接把 Release 验证删掉。

### F5 · 高优先级：Windows Quick Access 有两层显示修复，关闭不能终止外层重试

[AppController.cs](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/src/ShotPaste.Windows/Services/AppController.cs#L1511) 第 1511–1547 行首次显示后无条件启动 12 次、250 ms 间隔的重试。[QuickAccessService.cs](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/src/ShotPaste.Windows/Services/QuickAccessService.cs#L278) 第 278–307 行又执行最多 6 次 settle，叠加 Show、窗口可见性修复、原生窗口修复和 Activate。

同一服务第 75 行关闭时只移除窗口，未终止控制器的重试。静态执行链表明，用户很快关闭卡片后，剩余 Show 调用可以重新创建同一卡片。这是需原生复现的具体风险，不能在未运行时称为已确认的用户故障。

**方案：** 所有显示修复归 QuickAccessService；同一展示请求只允许一个可取消任务。显示成功、用户关闭、挂起、替换、Dispose 均结束当前尝试。关闭后同一请求不能再次创建窗口；用户主动恢复历史可创建新的展示请求。以已满足的窗口条件和窗口生命周期决定操作，删除无条件外层重试。

**验收：** 立即关闭后不重现、不抢焦点；进入 One Shot/录制的挂起窗口不被后台 settle 拉回；多屏、负坐标、150% DPI 下仍正确显示。保留必要的 NoActivate、输入穿透、捕获排除与坐标换算。

### F6 · 高优先级：Windows 本地化通过全局监听改写控件，覆盖了用户内容

[LocalizationService.cs](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/src/ShotPaste.Windows/Services/LocalizationService.cs#L280) 第 280–385 行拦截所有 FrameworkElement.Loaded，遍历逻辑树/视觉树，对 TextBlock.Text、Content、Header 等注册属性变化并重写值。第 486–538 行还实现词组拼接翻译。

[MainWindow.xaml](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/src/ShotPaste.Windows/Views/MainWindow.xaml#L194) 第 194/201 行把用户 PreviewText/Title 绑定到 TextBlock；[CaptureHistoryItem.cs](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/src/ShotPaste.Windows/Models/CaptureHistoryItem.cs#L54) 第 54–57、81–83 行明确从剪贴板原文生成这些字段。静态路径显示，匹配词典的用户内容也可能被作为界面文案翻译。本次未运行 Windows 验证显示效果，也没有证据说明存储的原始数据被修改。

**方案：** 产品文案显式引用资源 key；动态文案使用格式参数。用户文本、文件名、OCR 和转写结果不进入产品本地化。按窗口迁移为显式 key，过渡期仅对明确标记的产品控件启用旧翻译；最后移除全局拦截、反射订阅和拼词层。复用现有共享目录，不另建语言系统。

**验收：** 切换十种语言后产品控件与辅助名称正确更新；“设置”“录屏”等与词典同名的用户文字、文件名及转写文本保持原样；绑定刷新和虚拟化列表仍正常。macOS 本次未发现同类全局改写机制，无需复制 Windows 实现。

### F7 · 中高优先级：真实音频保存事务在正常、异常和恢复路径重复维护

[AudioRecordingCoordinator.swift](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPaste/Features/AudioRecording/AudioRecordingCoordinator.swift#L744) 第 771–825 与 845–885 行重复提取音频、建立输入、写历史、写任务、确认任务持久化、关联状态、删除内部视频、启动处理；第 1226–1297 行恢复路径又维护其中一段。

**方案：** 先抽一个具体的“完成已停止音频 session 保存”操作，正常与异常入口只处理怎样结束捕获。统一操作依据已持久化事实幂等推进，返回保存结果；声音、Toast、窗口留在 Coordinator。之后让启动恢复调用同一操作。无需引入工作流 DSL、通用事务框架或额外事件总线。

**验收：** 逐个真实写入边界注入失败，确认重试不重复历史、不重复任务、保存失败保留素材，只有持久化和媒体校验都成功才删除内部视频。保留异常结束与正常结束的提示差别。

### F8 · 中优先级：内部协议保留旧签名与下转型，主要为旧 fake 服务

[AudioRecordingProcessingPipeline.swift](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPaste/Features/AudioRecording/Processing/AudioRecordingProcessingPipeline.swift#L55) 第 55–115 行同时维护转写旧签名/账户快照新签名，以及 AI 旧签名/checkpoint 新签名；默认桥接需要丢弃额外参数或拒绝 checkpoint。[Coordinator](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPaste/Features/AudioRecording/AudioRecordingCoordinator.swift#L192) 第 192–224 行通过第二个私有协议和运行时下转型传 preferredHistoryID。

**方案：** 窄协议保留，每种操作仅保留当前完整签名，更新 fake，删除只测试 legacy adapter 的用例。将 preferredHistoryID 纳入现有协议，不以能力探测模拟内部版本兼容。只移除检索确认无调用的别名；不把持久化兼容与内部源码签名兼容混为一谈。

### F9 · 中优先级：转写列表依赖 URL/扩展名推断任务关系

[TranscriptionResultsRepository.swift](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPaste/Features/Recording/Transcription/TranscriptionResultsRepository.swift#L93) 第 93–136 行通过源 URL 关联失败父任务，并以 mov/mp4/m4v 扩展名区分展示的录像任务；第 226–240 行重新提交时再按媒体 URL 查父任务。[音频识别适配器](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPaste/Features/AudioRecording/Processing/VolcengineAudioRecognitionEngine.swift#L24) 实际复用了录屏转写服务生成每轨道回执。

**方案：** 在现有回执增加明确的来源类型与父任务身份，新任务按 ID 关联；业务层不再以 URL 或扩展名推断身份。保留原始 provider request ID 和账户绑定，纯 UI 分类/导航变化不能触发新请求。先改关联关系，再评估重复 AI 编排；不先统一所有存储格式。

捕获恢复、用户可见处理进度、云提交/清理是不同生命周期。它们可以分开存储；问题在于缺少显式关系与重复映射，不能简单压成一个 status 或一个 JSON 文件。是否需要兼容应在实施时核对 release 包含关系与真实数据：未发布的新格式不设计多代迁移框架，但本机已有可恢复录制与待清理云任务仍须保留。

### F10 · 中优先级：测试层级混杂，测试模式改变了需要验收的行为

[ScreenCaptureServiceTests.cs](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/tests/ShotPaste.Windows.Tests/ScreenCaptureServiceTests.cs#L8) 无环境分组地采真实桌面，却只断言像素尺寸。[WindowCaptureExclusionServiceTests.cs](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/tests/ShotPaste.Windows.Tests/WindowCaptureExclusionServiceTests.cs#L9) 创建真实 HWND 并检查 affinity，但用手动再次 SetEnabled 代替生产定时发现新窗口的过程。这不是应删除的边界，而是应放对层级并加强判据。

[AppController.cs](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/src/ShotPaste.Windows/Services/AppController.cs#L113) 的 UiTestMode 跳过托盘/快捷键；[录屏区域窗口](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/src/ShotPaste.Windows/Views/RecordingRegionOverlayWindow.xaml.cs#L127) 与 [QuickAccessService](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/src/ShotPaste.Windows/Services/QuickAccessService.cs#L319) 会改变测试窗口样式或捕获排除。因此样例页面通过不等于真实焦点、窗口层级和隐私路径通过。

**方案：** 真实桌面测试单独标记并在已登录桌面执行；普通测试保留纯几何/状态逻辑。样例页面只用于布局与控件覆盖，测试数据根目录隔离继续保留。为窗口层级、捕获排除、托盘/快捷键保留少量使用真实产品设置的 smoke 场景；失败/未运行必须独立报告，不能静默 skip 后总称验收通过。

### F11 · 中低优先级：大型控制器和标注窗口应该按所有权拆分

Windows AppController 主文件 1,888 行，加音频 partial 150 行；InlineAnnotateWindow.xaml.cs 3,090 行。后者同时持有选区、标注、撤销、视口、OCR 与录前配置，并在[第 1396 行附近](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/src/ShotPaste.Windows/Views/InlineAnnotateWindow.xaml.cs#L1396)及第 2671 行附近同步维护 elementTools 与 elementStyles.Tool。

macOS ScreenRecordingManager.swift 3,170 行，但前约 980 行本就包含多个独立命名类型；InlineAreaAnnotateWindow.swift 3,264 行混合窗口、根视图和控件。QuickAccessManager 的三种媒体插入路径也重复卡片淘汰、面板显示与计时器操作。

**方案：** Windows 先消除 Tool 的重复索引，再分离标注文档/撤销历史、选区交互、One Shot 准备；AppController 逐步只保留组装、命令路由和全局互斥，录屏生命周期由具体 session 负责。macOS 先移动已有独立类型，不改行为；Quick Access 用一个私有插入操作统一栈管理，媒体准备仍各自验证。

不要求每个类拥有 interface，也不引入全应用 Redux/Reducer、插件体系或跨平台 UI 引擎。机械拆文件只是审阅便利；真正收益应是某项行为的状态和 cleanup 有唯一 owner。

### F12 · 中高优先级：部分测试数量多，结果判据却弱；另有同一契约重复覆盖

[RecordingSessionTests.swift](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPasteTests/Features/Recording/RecordingSessionTests.swift#L52) 第 52–69 行四个测试仅调用 setter/reset；名为 reset 清除暂停偏移的测试没有检查偏移或后续时间线。[AnnotateBlurEffectRendererTests.swift](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPasteTests/Features/Annotate/AnnotateBlurEffectRendererTests.swift#L26) 的多种绘制测试重复构造 CGContext、绘制纯色图，却不读取输出像素。这些测试提供的主要是“不崩溃”信号，不能证明遮挡/渲染效果。

[MicrophoneAudioCapturerTests.swift](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPasteTests/Features/Recording/MicrophoneAudioCapturerTests.swift#L73) 的真实麦克风测试等待开始和停止后，只检查 running 为 false；没有证明曾成功启动或收到音频样本。应验证开始状态、首个音频样本、停止后不再接收，产物质量另由录制验收证明。

[RecordingEncodingSettingsTests.swift](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPasteTests/Services/Capture/RecordingEncodingSettingsTests.swift#L29) 与 [ScreenRecordingEncodingSettingsTests.swift](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPasteTests/Services/Capture/ScreenRecordingEncodingSettingsTests.swift#L24) 又分别维护同一编码 API 的码率边界、codec profile 和音频设置。保留更强断言及各自独有边界，合并成一个契约测试组，不必维护两套弱/强版本。

还需修正 [HistoryPanelPositionTests.swift](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPasteTests/Features/History/HistoryPanelPositionTests.swift#L22) 第 22–64 行：无屏幕时构造 XCTSkip 后直接返回，没有抛出，可能被计作通过。类似纯布局数学应接收矩形输入；确实需要屏幕的用例须显式报告跳过。异步测试优先等待完成事件或受控调度，避免用固定 sleep 推断工作完成。

**方案：** 删除无独立价值的 setter smoke，把多个绘制“不崩溃”测试收缩为少量有结果判据的场景：非纯色 fixture、区域内实际变化、区域外不变、空区域不变。保留必要 native crash smoke，但不能将其描述成行为验收。此项随 A 的信号校正与 F 的相关模块重构分批进行。

## 4. 目标结构

两个平台继续独立原生实现，只共享功能契约、本地化与验证场景。

~~~text
菜单/快捷键/受限自动化
        ↓
应用组装与命令路由（全局捕获互斥）
        ↓
具体会话：One Shot / ScreenRecording / AudioRecording
        ↓
保存完成操作 → 已保存媒体与持久化回执 → 历史 / Quick Access
        ↓
有明确父任务身份的转写任务 → 云请求及独立删除状态
        ↓
原文与 AI 产物 → 结果列表和详情投影
~~~

这是一张责任图，不意味着每个箭头新增类或消息系统。优先复用现有 Service/Store，在重复发生处抽具体操作。UI 可以投影状态，但不另维护可与持久化任务冲突的业务真相。

明确保留：录制 generation/teardown 归属、音轨时间线、保存后的媒体校验、真实文件删除保护、SQLite 恢复、云请求幂等与原 ID 恢复、账户绑定、清理重试、自动化 allow-list/鉴权、Debug/Release 隔离与稳定签名。

尤其 [AudioAdapterSessionStore.swift](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPaste/Features/AudioRecording/Services/AudioAdapterSessionStore.swift#L620) 的“读取快照 → 异步校验 → 重读并核对 → 删除”不能因为出现相似 guard 就合并掉；它跨越异步与文件变化边界。

## 5. 测试重构方案

| 类别 | 处理方式 | 保留的证明 |
| --- | --- | --- |
| 无生产调用的策略副本 | 删除副本或接入唯一真实实现 | 实际文件/会话结果 |
| 旧 Speech 专属测试 | 随旧产品路线删除 | 当前云路径的取消、时间线、静音轨道 |
| 私有方法名/语句顺序断言 | 替换或删除已有覆盖的重复 | 输入事件产生的可见结果/副作用 |
| 同义默认值/常量断言 | 合并为小型参数表；无契约者删除 | 持久化格式、默认用户行为、身份差异 |
| 资源/本地化检查 | 保留并归入资源契约 | key、格式参数、语言完整性与必要对比度 |
| 网络与持久化 fixture | 保留、减少重复 setup | 请求格式、原 ID 重试、错误分类、checkpoint |
| 原生桌面/硬件测试 | 单独分层并增强结果判据 | 真窗口、像素、音频样本、媒体产物 |
| 小范围高风险竞态测试 | 保留确定性调度和必要测试观测点 | 取消/旧回调不能破坏当前任务 |
| 纯布局的样例窗口 | 保留代表性场景 | 布局与可访问性，不扩大验收声明 |
| 专项准确率/性能基准 | 相关算法改变时运行 | 图像准确率、资源/延迟回归 |

高价值测试的现有实例包括：[Windows 删除安全](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/tests/ShotPaste.Windows.Tests/CaptureHistoryDeletionSafetyTests.cs#L10) 的真实临时数据库/文件失败保留；[滚动拼接](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/tests/ShotPaste.Windows.Tests/ScrollingStitcherTests.cs#L102) 的重复纹理、固定头尾和方向反转；[macOS 冻结选区](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPasteTests/Services/Capture/FrozenAreaCaptureSessionTests.swift#L495) 的多屏/缩放/像素方向；[MCP 测试](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/windows/tests/ShotPaste.Windows.Tests/ShotPasteMcpTests.cs#L120) 的真实 loopback 鉴权；[提交调度器测试](https://github.com/shotpaste/shotpaste/blob/666ab8db250c7833401cde22096acd13b57ac26c/platforms/mac/ShotPasteTests/Services/Capture/ScrollingCaptureCommitSchedulerTests.swift#L51) 用 continuation 控制并发。这些案例应作为保留和改写的参照。

建议保留的最小风险矩阵：

| 风险 | 主要自动验证层 | 原生补充 |
| --- | --- | --- |
| One Shot 切换/取消破坏捕获 | 会话状态和输出行为 | 截图→滚动→录屏切换、取消恢复 |
| 保存失败误删素材 | 临时目录真实文件 + Store 故障注入 | 正常和异常结束录制保存 |
| 云端重复计费/账户错配 | HTTP fixture + 持久化原 ID/账户快照 | 经授权的公开样本服务验证 |
| 轨道缺失/时间偏移 | 合成媒体有效性、段 ID/时间范围 | 系统音+麦克风、暂停/恢复、设备断开 |
| Quick Access 关闭后重现/抢焦点 | 展示请求生命周期 | 真实桌面窗口与 150% DPI |
| 本地化误改用户内容 | 明确输入内容与资源键测试 | 语言切换后原文不变 |
| 标注状态/撤销错误 | 文档与编辑操作行为 | 多选、缩放、导出及键盘操作 |
| 自动化越权/路径删除越界 | 真实解析器、allow-list、文件安全测试 | 标准 Debug 入口与可见反馈 |

执行层级建议：

1. 开发迭代用现有入口的定向过滤，不强制每次局部编辑跑全套；任务收尾仍遵循现行 AGENTS 门禁。
2. 完整 Debug 验证中每个普通测试只执行一次；原生内存隔离组保留独立进程。源码/资源静态检查不再冒充 UI E2E。
3. Windows 桌面、麦克风、录制和 DPI 场景在专用原生层执行；普通无桌面环境不能承担这些证明。
4. 先保留 Debug/Release 两种身份及构建验证，再根据真实配置差异决定哪些业务测试需要双跑。发布候选与相关构建链变更仍跑完整发布门禁。
5. 纯文档/明确单平台变更可设计条件化 CI，但必须有稳定汇总检查，处理共享目录和构建链兜底，并核对 required checks，不能靠 job 被跳过来显示成功。

先收集固定提交的冷/热构建时间、各层时长、失败原因和人工重跑情况，再设置时间预算。**不设“删 30% 测试”“减少一半代码”等数量目标，也不根据本次静态统计宣称加速。** 小范围观察重命名是否造成无意义失败、典型行为破坏是否被捕获即可，不先上全仓 mutation 平台或新增覆盖率指标体系。

## 6. 分阶段实施与完成标准

以下为拟议改动单元，尚未创建分支、提交或 PR。

| 阶段 | 内容 | 依赖 / 风险 | 完成标准 |
| --- | --- | --- | --- |
| A：校正门禁 | F4 的重复执行和 Debug 路径；F10 的测试分层 | 先做；低到中风险 | 普通测试仅执行一次，独立 Headless 可用，交互门禁选择准确产物，summary 关联本次结果 |
| B：macOS 删除无用路径 | F1、F2、F8，最小入口行为测试 | 与 A 可独立；中风险 | 无旧 Speech 生产符号/权限入口，无未调用策略副本，协议只留当前完整签名 |
| C1：Windows 显示生命周期 | F5 | A 便于验收；中风险 | 关闭/挂起取消重试，单展示请求不重建，真实多屏/DPI与焦点通过 |
| C2：Windows 显式本地化 | F6，逐窗口迁移 | 与 C1 可独立；中风险 | 产品文案十语言正确，用户内容不变，全局自动改写最终移除 |
| D：合并保存事务 | F7，同时消除已覆盖的文本断言 | B 后；高风险 | 正常/异常/恢复共用幂等保存操作，所有失败点保留数据，历史/任务不重复 |
| E：转写任务关系 | F9，按需合并 AI 编排 | D 后；高风险 | 新任务按 ID 关联，查询/清理沿用原请求与账户，不触发额外提交 |
| F：控制器与标注整理 | F11、余下 F3 | 前述稳定后；按子系统拆小块 | 状态所有权减少、测试不依赖私有形状、主要原生交互无回归 |

建议先完成 A、B、C1 的一个闭环，重新观察维护成本，再决定 E/F 的投入深度。每次改动保持一个可验证的责任边界；若机械拆分增加跳转却没有减少状态来源，停止继续抽象。

回退策略：源码改动以独立小提交可回退；持久化格式变化单独处理。先写入新身份字段再改读取路径，验证在用任务的恢复与清理；不得通过清空历史、丢弃待处理任务或重提交云请求来简化迁移。没有发布依据时不创建面向假想旧用户的多代兼容系统。

## 7. 基线审计的验证边界与实施要求

基线审计阶段实际执行的是 Git 状态/基线读取、git ls-files 与 Python 标准库静态统计、rg 符号/调用检索和源码逐段核对；交付前执行 git diff --check、报告链接与引用行号检查、git status --short。该阶段未执行 App 编译、单元测试、原生 UI、硬件或云服务请求，也未把已有 build 日志当作该阶段结果。

基线审计未生成 Debug 产物。实施时必须使用现有原生入口：

~~~bash
./scripts/run-tests.sh
./scripts/build_and_run.sh build --configuration Debug
swift -module-cache-path build/swift-module-cache platforms/mac/Tools/Localization/CatalogTool.swift verify
~~~

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Configuration Debug
$product = (Resolve-Path '.\platforms\windows\src\ShotPaste.Windows\bin\x64\Debug\net8.0-windows10.0.19041.0\win-x64\ShotPasteDebug.exe').Path
.\scripts\test-windows-parity.ps1 -Configuration Debug -Tier Interactive -SkipBuild -ProductExecutable $product
~~~

150% DPI 专项增加 -RequireDpiScale 1.5；Release/签名/打包修改执行对应 Release 门禁。上面是基线审计时列出的实施命令；实际执行结果见第八节及任务交付。

macOS 标准产物相对于仓库为 .build/macos/Debug/ShotPaste Debug.app；Windows 标准产物相对于当次真实 Windows checkout 为 platforms/windows/src/ShotPaste.Windows/bin/x64/Debug/net8.0-windows10.0.19041.0/win-x64/ShotPasteDebug.exe。实施交付时报告实际构建的绝对路径；本次未连接 Windows，不虚构其 checkout 路径。

采用新测试分层/构建策略时同步 AGENTS.md、DEVELOPMENT.md、脚本与 CI；改变功能/隐私契约时同步 FEATURES.md/SECURITY.md；权限与用户文案变更核对所有语言。内部责任整理本身不要求为十份 README 增加实现细节。本报告不改变现行门禁或发布规则。


## 8. 实施记录（2026-09-08）

本轮已实施核心去重和职责收敛：

- 删除未调用的事务策略及镜像测试；流失败入口直接使用已测试的唯一策略。
- 移除 Apple Speech 引擎、权限桥、十分钟旧切片路径与对应测试/权限声明；内部处理协议保留完整签名。
- 正常/异常保存共用停止后保存操作；启动恢复与正常保存共用处理回执事务，保留媒体校验及重读删除门禁。
- 转写回执增加明确类型与音频父 session ID 集合；旧记录只做本地关系修复，原云请求及账户身份不变。
- Windows 普通与重型测试组执行一次；桌面测试单独分类，交互产物按实际构建身份解析。
- Windows Quick Access 显示修复归单一 owner，关闭/挂起取消；新增真实桌面“立即关闭后不重现”的回归场景。
- Windows 产品文案改为显式本地化绑定，去掉全局控件遍历和反射监听，新增语言切换不改写用户内容的行为测试。既有词典及显式文案的回退查找继续复用。
- 去掉 Windows 标注重复 Tool 索引，合并 macOS Quick Access 卡片插入流程，分离录屏 manager 与录制类型/编码契约。
- 合并重复编码测试，移除无结果判据的 setter 测试；绘制测试改为检查八种效果实际改变内容及绘制边界；修正未抛出的 XCTSkip。真实麦克风 opt-in 用例要求进入 running 并收到有效音频样本，不能只检查停止后的状态。
- 移除已由原生 History/Inline/Localization E2E 承担的部分源码形状断言，保留数据安全、算法、协议、资源对比度等有效覆盖。

本轮没有把控制器全面改写成新框架，也没有批量删除尚未建立替代行为证据的源码测试。更大的 AppController/标注文档职责拆分保留为后续独立改动；本轮先消除已确认的重复状态与执行路径，避免同时扩大原生输入和持久化迁移风险。

验证结果在任务交付中列出；本地结果保留于标准 build 目录，不提交录制内容、诊断包或设备绝对路径。


已完成的自动与原生验证：

- macOS：最终全套 XCTest 1,175 通过、0 失败、2 跳过；跳过的是显式 opt-in 的真实麦克风与真实翻译服务测试。标准 Debug 构建和证书签名校验通过；共享目录 1,052 个 key、10 种语言验证通过。
- macOS 实际运行：同一区域在截图、滚动和录屏模式间切换；实际录屏经过暂停、恢复与保存，产出 36.83 秒 H.264/AAC 文件，Quick Access 关闭后保留已保存文件。未进行真实云请求。
- Windows：Windows 11 已登录桌面；Debug、Release 原生构建均 0 警告/0 错误，分别 480 项 headless 测试通过。两项 NativeDesktop 测试通过。
- Windows 历史与标注原生套件通过；标注包含新增的 Quick Access 立即关闭回归。首次本地化验收发现漏格式化 Debug 标题，复验又发现 ASCII 格式名未加入显式本地化，均已修正；十种语言与 OCR 随后的原生复验通过。历史/标注与复验分别保留结果，不把 NotRun 当作通过。

Windows 后续批次的 NativeDesktop、Localization、Ocr、Recording、ScrollingLive、ScrollingEdge 均通过；录制覆盖音频、格式矩阵、设置和真实产品生命周期。独立 Headless 合同入口 124 项通过；不含 Localization 的 DPI 强制验证请求会在执行前被明确拒绝。

以上验收在 Windows 100% DPI 下进行，未将其称为 150% DPI 验收。macOS 独立录音硬件入口尚未验收：当前 UI 工具无法定位菜单栏录音入口，已请求手动打开准备面板；不能用 macOS 实际录屏、合成音频恢复测试或 Windows 录音验收替代。真实云服务调用未执行。
