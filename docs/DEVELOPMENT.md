<a id="project-structure-and-build"></a>

# 项目结构与构建

<a id="repository-layout"></a>

## 仓库布局

```text
.
├── platforms/
│   ├── mac/                    # Swift/AppKit/SwiftUI 应用与 XCTest
│   └── windows/                # C#/WPF 应用与 .NET 测试
├── resources/localization/     # 共享本地化目录
├── assets/                     # 共享项目素材
├── scripts/                    # 构建、测试、发布与工具命令
├── docs/                       # 项目文档
└── .github/                    # CI 与仓库自动化
```

两个客户端共享产品行为与资源，不共享 UI 或捕获引擎代码。
平台行为必须在对应原生操作系统验证。文档默认使用简体中文；
README 与使用指南保留多语言，具体范围见[文档导航](README.md)。

## macOS

环境要求：

- macOS 13 或更高版本
- Apple Silicon
- Xcode 26.2 或兼容的更高版本

<a id="local-signing-identity"></a>

### 本地签名身份

macOS 构建脚本拒绝 ad-hoc 签名，以便本地重复构建时保持隐私权限稳定。
可使用已有 Apple Development 或 Developer ID 身份；若没有，在登录钥匙串中
创建仅用于开发的 `ShotPaste Local Development`：

```bash
./scripts/create-signing-cert.sh
```

后续本地构建继续使用此身份。脚本仅为导入创建临时 PKCS#12 文件，退出时删除，
不打印或导出发布凭据。该脚本创建的身份仅限本地开发，不能替代固定发布身份。

构建标准 Debug 应用：

```bash
./scripts/build_and_run.sh build
```

仅用于开发的 ASR 2.0 账户探针（不随任一原生应用分发）：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p test_volcengine_transcription_probe.py -v
python3 scripts/volcengine_transcription_probe.py
# 中断后查询已持久化的任务，不重新提交：
python3 scripts/volcengine_transcription_probe.py --resume
```

真实命令提示输入语音 API Key，不回显、不保存，仅提交一次官方公开短 MP3。
运行前须获得账户所有者对服务开通和使用费用的授权。
报告位于被忽略的 `build/volcengine-account-verification/`；
仅在有意发起新的计费提交时使用新的报告路径。禁止通过命令参数传递凭据。
此探针只验证 ASR HTTP 行为，不验证 TOS 权限、原生录制、清理、实际账单或跨平台验收。
其余门禁见[改造方案](VOLCENGINE_TRANSCRIPTION_REFACTOR_PLAN.md)。

可选私有 TOS 探针使用官方 Python `tos==2.9.2` SDK（Apache-2.0），
只安装在被忽略的开发虚拟环境，不是原生应用依赖。使用可信的 Python 3.12+：

```bash
python3 -m venv build/volcengine-account-verification/tos-venv
build/volcengine-account-verification/tos-venv/bin/python -m pip install 'tos==2.9.2'
PYTHONDONTWRITEBYTECODE=1 build/volcengine-account-verification/tos-venv/bin/python -m unittest discover -s scripts -p 'test_volcengine*probe.py' -v
build/volcengine-account-verification/tos-venv/bin/python scripts/volcengine_tos_probe.py --resources build/volcengine-account-verification/tos-poc-resources.json --report build/volcengine-account-verification/tos-poc-result.json
```

准备资源 JSON：`installation` 为随机 12 位小写十六进制字符串，
`region` 为 `cn-beijing`，`bucket` 为 `shotpaste-tmp-poc-<installation>-debug`，
`prefix` 为 `transcription/v1/<installation>/`。运行前授权对应的资源受限 IAM 策略。
命令安全提示输入密钥，创建私有测试桶与生命周期，仅上传官方公开样本，检查未签名/签名访问，
执行 ASR 并验证删除。桶会保留；命令不删除桶，也不改动其它对象前缀。
重试前检查失败报告：`--resume-setup` 仅适用于尚未上传的阶段；
`--cleanup-only` 只重试已记录对象的删除，不新建 ASR 提交。

macOS 的 AI 功能 → AI 转写及两个录制入口均使用原生 ASR/TOS 组件。
配置语音 Key 和专用 IAM AK/SK。“保存”在本地持久化凭据；“保存并测试”还会初始化私有存储，
执行付费公开样本验证，并保留已完成的配置阶段供重试。高级选项可配置已有私有存储。
One Shot 录制准备面板负责录屏转写、AI 开关和语音语言，开始时记住并随本次录制传递，
后续修改默认值不改变本次后处理。取消准备会丢弃草稿。GIF 与无音频录制不能开启转写，
自动上传仍须单独主动开启。

转写凭据与 `AgentCredentialStore` 一样使用按构建身份隔离的 UserDefaults 档案，
不调用 Keychain API。仅存在于旧 Keychain 的值需重新输入。
档案 ID 将旧任务绑定到原密钥，直至清理结束。TOML 和任务导出不写入明文秘密。

私有云回执与待处理 M4A 分段位于对应构建身份的 Application Support 下 `CloudTranscription`。
父媒体引用、完整时间线及 AI 派生内容位于私有 `RecordingTranscriptionSessions`。
录音结果仍保留在已有 AudioAdapter 会话目录。结果浏览器读取两类存储，
仅将历史 UUID 关联持久化到 `AudioAdapter/transcription-history-links.json`。
这三类路径均使用 `AppDataLocations` 隔离 Debug/Release。
启动和定期恢复查询已有请求 ID，并清理已完成/失败/取消任务的对象。
菜单将“开始录音”与“转写结果”分组；设置不再列出云任务或转写内容，
任务进度与导出由“转写结果”负责。
原生测试注入 HTTP 测试数据；公开样本按钮执行真实 Swift 签名、AVFoundation 导出、
本地凭据存储和 HTTP 链路。

运行测试：

```bash
./scripts/run-tests.sh
```

构建并启动：

```bash
./scripts/build_and_run.sh
```

产物：

- Debug：`.build/macos/Debug/ShotPaste Debug.app`
- Release：`.build/macos/Release/ShotPaste.app`

<a id="debug-and-release-isolation"></a>

### Debug 与 Release 隔离

macOS 两种配置是可同时运行的独立应用。Release 保留已有身份与路径，Debug 使用专属值：

| 项目 | Release | Debug |
| --- | --- | --- |
| Bundle ID | `com.ahtcfg24.shotpaste` | `com.ahtcfg24.shotpaste.debug` |
| 可执行文件 | `ShotPaste` | `ShotPasteDebug` |
| Application Support | `~/Library/Application Support/ShotPaste` | `~/Library/Application Support/ShotPaste Debug` |
| 诊断日志 | `~/Library/Logs/ShotPaste` | `~/Library/Logs/ShotPaste Debug` |
| 托管 TOML | `~/.config/shotpaste/config.toml` | `~/.config/shotpaste-debug/config.toml` |
| 默认导出目录 | `~/Desktop/ShotPaste` | `~/Desktop/ShotPaste Debug` |
| URL Scheme | `shotpaste://` | `shotpaste-debug://` |
| 默认 MCP 端口 | `48123` | `48124` |
| 复制的 MCP 客户端键名 | `shotpaste` | `shotpaste-debug` |
| 菜单栏图标 | `MenubarIcon` 双框标志 | `MenubarIconDebug` 双框标志，中央带 `D` |

两者的 UserDefaults、隐私权限、登录项、历史数据库、缩略图、剪贴板归档、临时捕获、
录制元数据、日志、问题报告归档与默认输出目录不重叠。
内部剪贴板标记与 Quick Access 拖拽类型也按构建身份隔离；
Quick Access 载荷仅在来源进程内暴露。每个应用只接受自身注册的 URL Scheme。
应用及菜单栏图标使用相同品牌几何图形，Debug 增加可见 `D`。
Debug 默认全局快捷键额外使用 Option，避免与 Release 默认值争用。
不自动迁移旧数据；用户在两应用中显式选择同一目录时，有意共享该目录。

标准构建身份定义位于
`platforms/mac/ShotPaste/Config/AppVariant-{Debug,Release}.xcconfig`。
Xcode、本地构建/签名脚本与两种测试配置共同使用这些文件；
签名构建被接受前，产物验证必须与 `AppVariant` 一致。

<a id="audio-transcription-diagnostics"></a>

### 音频转写诊断

开启诊断后，macOS 音频处理向上述构建身份的日志目录写入任务/会话 ID、音源角色、分段索引与时间、
导出/识别阶段，以及错误域/错误码。保留底层错误域和错误码，不包含错误描述、任意错误载荷、
音频路径或转写文字。取消与失败分别记录。分段开始/完成及任务失败记录可在不读取录音内容的情况下关联故障。
这些日志用于诊断后续运行，不能恢复旧版本已丢弃的框架错误详情。

提取阶段还按会话/分段/音源记录容器和音频时长、轨道起点、差值与允许容差，并显式记录拒绝原因。
识别链路使用火山文件 ASR；未使用的 Apple Speech 引擎与权限桥接已移除。
文件切分归文件 ASR 服务，音频转写器负责音源角色与时间线归一化。
正常停止和启动恢复共用持久化处理回执事务，完成后才允许删除私有捕获媒体。
云转写需要 AI 转写中的语音 API Key、TOS AK/SK、已初始化私有存储及成功样本验证。
真实验证使用公开、非私密音频；协议测试数据不能证明真实服务验收。
AI 整理使用 Agent 配置的端点、模型、协议及凭据，仅发送文字载荷。

<a id="release-signing-identity"></a>

### Release 签名身份

取得 Apple Developer ID 证书前，正式发布构建使用固定自签名身份
`ShotPaste Release Self-Signed`，SHA-1 指纹为
`8CBB386A17831C9C093C6BA693C4F60BC239A213`。
公开证书位于 `.github/signing/ShotPaste-Release-Self-Signed.crt`，
维护者无需接触私有材料即可审计身份。

可导出身份与密码仅存于仓库 Actions Secrets `SELF_SIGNED_CERT_P12` 和 `SELF_SIGNED_CERT_PASSWORD`。
P12 含私钥，严禁提交。发布凭据仅限维护者，本地构建不需要。
禁止更换、重建、重命名或轮换发布证书；macOS 隐私权限绑定到应用签名身份。

<a id="automated-releases"></a>

### 自动发布

macOS 与 Windows 各自维护稳定发布流。标签必须指向包含于 `release` 的提交，格式为：

- `macos-vMAJOR.MINOR.PATCH`，例如 `macos-v1.3.0`，触发 `.github/workflows/release-macos.yml`。
- `windows-vMAJOR.MINOR.PATCH`，例如 `windows-v1.2.4`，触发 `.github/workflows/release-windows.yml`。

每个工作流仅运行对应平台的原生测试与 Release 构建，生成包并验证 `SHA256SUMS.txt`，
发布带对应启动指南的非草稿 GitHub Release。因此两平台版本与发布时间可以独立推进。
改动推送到 `main` 后，仓库 Owner 通过发布 PR 直接将 `main` 合入 `release`，不创建中间晋级分支。
指向 `release` 的 PR 仍运行两个平台验证，确保稳定源码可在两端构建。

macOS 工作流需要上述两个 Actions Secrets，并在构建前核对导入证书的固定指纹。
标签无效、提交不属于 `release`、缺少凭据、测试/构建失败或产物缺失时，
在创建 GitHub Release 前停止对应工作流。正式平台标签不可变，仅仓库 Owner 可创建。

## Windows

产品 UI 文案（包括 GIF 等本地化格式名称）在 XAML 中显式通过 `loc:Localized` 绑定已有短语目录，
切换语言时更新。用户文字、媒体名和转写绑定不自动改写；代码生成的产品状态文案显式调用
`LocalizationService`。不使用全局 Loaded 处理器或属性观察器翻译任意 TextBlock/Content/Header。
Quick Access 每张活动卡片只拥有一个可取消的可见性修复任务，关闭或挂起时取消。

录制转写使用原生文件 ASR/TOS、DPAPI 凭据和捕获时账户快照，不打包 Python 运行时或云 SDK。
原生 WASAPI 录音将私有恢复 PCM 写入 `AudioRecordingSessions`，
经验证的 M4A 按录制输出设置保存，音源专用 M4A 保留供转写。
持久化任务与转写/AI 内容位于 `TranscriptionResults`，独立于剪贴板历史保留。
录屏至转写的交接回执在持久化任务存在前保留原始同意状态。
所有路径来自 `AppPaths.Root`，遵循 Debug/Release 身份隔离。

在录制设置保存语音与受限 TOS 凭据，显式确认付费公开样本测试。
录制准备时选择转写、语言和 AI。测试使用协议/签名数据与本地合成数据，
不能证明真实云服务权限或原生录制质量。以下标准验证须在原生 Windows 主机执行。

环境要求：

- Windows 10 2004 或更高版本，x64
- PowerShell 5.1 或 PowerShell 7
- .NET 8 SDK（`dotnet --info` 应显示已安装 SDK）
- 从仓库根目录执行以下命令

构建前确认 SDK：

```powershell
dotnet --info
```

`scripts/build-windows.ps1` 是统一验证入口：还原并构建 x64 的
`platforms/windows/ShotPaste.Windows.sln`，检查所选配置的应用身份，
将测试交给 `test-windows-parity.ps1 -Tier Headless -FullSuite`。
普通组与独立原生内存/数据库组互补，每个测试只运行一次，包含一致性契约测试。
单独运行 Headless 且不传 `-FullSuite` 时只运行聚焦契约子集。
每份摘要包含新的运行 ID 和实际执行的筛选条件。
`Category=NativeDesktop` 测试与捕获、剪贴板、OCR、本地化、录制 E2E 一起在已登录桌面的 Interactive 层执行。
默认产物路径解析 MSBuild 配置身份，不硬编码 Release 文件名。
聚焦交互重跑可传 `-Suites Localization` 或套件名称的 PowerShell 数组。
未选套件显式记为 `NotRun`；默认仍执行所有套件。
传入 `-RequireDpiScale` 的聚焦运行必须包含负责真实 DPI 检查的 Localization。

在 PowerShell 执行完整 Debug 验证：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Configuration Debug
```

执行 Release 验证但不发布：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Configuration Release
```

生成自包含、单文件的 win-x64 发布产物：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Configuration Release -Publish
```

主要产物：

- Debug：`platforms/windows/src/ShotPaste.Windows/bin/x64/Debug/net8.0-windows10.0.19041.0/win-x64/ShotPasteDebug.exe`
- Release：`platforms/windows/src/ShotPaste.Windows/bin/x64/Release/net8.0-windows10.0.19041.0/win-x64/ShotPaste.exe`
- Release 发布产物：`platforms/windows/src/ShotPaste.Windows/bin/x64/Release/net8.0-windows10.0.19041.0/win-x64/publish/ShotPaste.exe`

Headless 一致性摘要位于 `build/e2e/windows-parity/summary.json`。
构建脚本成功不能证明交互捕获、录制、权限、快捷键、DPI 或窗口管理通过。
这些检查应在真实 Windows 控制台执行，在改动说明中记录系统/硬件及简明人工验收步骤。

Debug 构建完成后，交互一致性运行须显式传入 Debug 可执行文件：

```powershell
$product = (Resolve-Path '.\platforms\windows\src\ShotPaste.Windows\bin\x64\Debug\net8.0-windows10.0.19041.0\win-x64\ShotPasteDebug.exe').Path
.\scripts\test-windows-parity.ps1 -Configuration Debug -Tier Interactive -SkipBuild -ProductExecutable $product -RequireDpiScale 1.5
```

Recording E2E 通过真实 Windows 播放端点播放低音量生成测试音，验证独立录音的 WASAPI 回环、
暂停/继续、重复停止、丢弃/重启、原生 AAC 编码、音源角色及恢复文件清理。
产品准备窗口与结果窗口使用本地测试数据渲染，检查音源限制、搜索/筛选和已保存内容。
传入产品可执行文件后，还使用隔离的真实产品进程检查可见准备/开始/停止流程、Quick Access、
历史开启/关闭和退出前保存。既有 `--ui-test-surface` 仅打开准备窗口，不增加生产 URL/MCP 启动操作。
这些检查不录制麦克风、不发送云请求，不能替代真实托盘/快捷键或麦克风验收。
标准构建后仅重跑音频检查：

```powershell
dotnet run --project .\platforms\windows\tests\ShotPaste.Windows.RecordingE2E\ShotPaste.Windows.RecordingE2E.csproj -c Debug -p:Platform=x64 --no-build -- build/e2e/windows-parity/recording $product --audio-only
```

`build-windows.ps1` 在测试前显式构建完整解决方案；新检出环境只执行 `dotnet test` 不会生成独立 E2E 程序。
交互验证须在已登录桌面会话执行，不能使用 SSH Session 0，并保留会话、系统、显示和音频端点证据。
Localization E2E 保留原生窗口截图，检查窗口/控件边界及重叠。
文字宽度检查只采用 UI Automation 报告的字体和单行范围，不以猜测字号替代缺失字体信息。
报告区分 `MeasuredSingleLineTexts` 与全部可见文字。

若无法识别 `dotnet`，安装 .NET 8 SDK 后重新打开 PowerShell，或仅在当前会话将已有
`dotnet.exe` 所在目录加入 PATH 前部。将占位符替换为真实 SDK 目录：

```powershell
$dotnetRoot = 'C:\path\to\directory-containing-dotnet.exe'
if (-not (Test-Path (Join-Path $dotnetRoot 'dotnet.exe'))) {
    throw "dotnet.exe was not found under $dotnetRoot"
}
$env:PATH = "$dotnetRoot;$env:PATH"
dotnet --info
```

<a id="main-code-areas"></a>

## 主要代码区域

macOS：

- `App/`：进程生命周期、菜单栏和 URL 命令
- `Features/`：捕获、One Shot、标注、录制、历史、Quick Access 和设置
- `Services/`：捕获/媒体、剪贴板、持久化、配置、诊断和快捷键
- `Shared/`：本地化与可复用 UI/支持代码

Windows：

- `Views/`：WPF 窗口与控件
- `Services/`：捕获、录制、OCR、历史、剪贴板、设置与应用协调
- `Models/`：设置与工作流数据
- `Interop/`：Win32 边界
- `tests/`：单元与原生端到端测试项目

<a id="audio-recording-and-transcription-ownership"></a>

## 录音与转写职责

用户设置及恢复行为见[录音与转写指南](RECORDING_TRANSCRIPTION.md)。
实现将捕获完成与云处理完成分开：音频通过验证且交接状态持久化后，才能删除恢复媒体。
转写或 AI 失败不能撤销已成功的本地保存。

| 职责 | macOS | Windows |
| --- | --- | --- |
| 音频捕获与本地保存 | `AudioRecordingCoordinator`、`TinyRegionRecordingAdapter`、`AudioAdapterSessionStore`、`AudioExtractionPipeline` | `AppController.AudioRecording`、`AudioRecordingService` |
| 共用原生录制类型 | `Services/Capture/RecordingCaptureTypes.swift`；活动捕获位于 `RecordingSession` | `ScreenRecordingService`、`RecordingRequest` |
| 语音 HTTP、私有上传、恢复与清理 | `VolcengineFileASRClient`、`VolcengineCloudJobs`、`VolcengineRecordingWorkStore` | `VolcengineRecordingTranscriptionService`、`RecordingTranscriptionJobs`、`ScreenRecordingTranscriptionReceipts` |
| 仅文字的 AI 整理 | `LocalAudioLLMProcessor`、`AgentAudioLanguageModelProvider` | `RecordingTranscriptAiProcessor` |
| 结果浏览与历史关联 | `TranscriptionResultsRepository`、`TranscriptionResultsWindow` | `TranscriptionResultsWindow`、`RecordingTranscriptWindow` |

macOS 的 `LocalAudioTranscriber` 名称不表示离线识别，生产引擎实际调用文件 ASR。
音频子回执包含显式父会话 ID，禁止通过改写云请求 ID 推导父任务。
Windows 回执保留 DPAPI 保护的捕获时账户快照，防止后续设置变化将恢复/清理转到另一账户。

相关改动使用上述标准平台命令。协议测试验证签名、回执/恢复和输出校验，不证明麦克风捕获、
操作系统权限或服务授权。原生系统音频/麦克风验收、中断/重启恢复，以及显式授权的真实云检查须分别记录证据。
禁止将历史公开样本结果描述为后续源码版本的验收。
工程审计历史与后续重构见[工程简化方案](ENGINEERING_SIMPLIFICATION_PLAN.md)。

<a id="configuration-files"></a>

## 配置文件

macOS 用户可编辑配置位于：

```text
~/.config/shotpaste/config.toml
```

通过验证的直接编辑在下次启动时生效。应用内修改会在后台同步，若文件存在需审查的外部改动则不覆盖。
捕获历史、剪贴板载荷、凭据、安全作用域书签、缓存及其它设备私有状态不进入该文件。

Windows 内部设置位于 `%LOCALAPPDATA%\ShotPaste\settings.json`，不提供 TOML 导入/导出契约。

<a id="localization"></a>

## 本地化

`resources/localization/Shared` 与 `resources/localization/Features` 下的分拆目录是两端共享运行时资源。
`resources/localization/manifest.json` 将每个键前缀分配给所属目录。编辑对应目录并验证所有权与漂移：

```bash
swift -module-cache-path build/swift-module-cache platforms/mac/Tools/Localization/CatalogTool.swift verify
```

不要将生成的本地化产物加入仓库。

<a id="contribution-rule"></a>

## 贡献规则

产品行为变化时检查两个原生客户端，在受影响平台构建和测试，记录有意保留的操作系统差异。

<a id="resource-limited-transcription-iam-policy-template"></a>

### 转写资源受限 IAM 策略模板

将 `ACCOUNT_ID`、`BUCKET` 和 `INSTALLATION` 替换为账户 ID 与应用显示的准确资源名称。
不要授予客户端 IAM 管理、公开 ACL 或删桶权限。
已有资源模式须显式选择，仍通过相同私有存储检查。
历史真实 PoC 使用专用子用户和此动作集合，并验证了前缀外访问被拒绝。

```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["tos:CreateBucket", "tos:HeadBucket", "tos:GetBucketLocation", "tos:GetBucketACL", "tos:GetBucketVersioning", "tos:GetLifecycleConfiguration", "tos:PutLifecycleConfiguration"],
      "Resource": ["trn:tos:cn-beijing:ACCOUNT_ID:BUCKET"]
    },
    {
      "Effect": "Allow",
      "Action": ["tos:PutObject", "tos:GetObject", "tos:DeleteObject"],
      "Resource": ["trn:tos:cn-beijing:ACCOUNT_ID:BUCKET/transcription/v1/INSTALLATION/*"]
    }
  ]
}
```

初始化成功后可移除初始化权限；正常验证和运行仍需桶/ACL/版本控制只读检查与对象前缀权限。
生命周期仅为兜底，不能证明即时删除成功。
