# AGENTS.md

本文件面向 Claude、Codex 等研发 Agent，是 ShotPaste 开发、评审、验证和文档维护的根级执行入口。面向用户的产品介绍位于各语言 `README*.md`，功能契约位于 [`docs/FEATURES.md`](docs/FEATURES.md)，构建与发布细节位于 [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)。

## 1. 项目概览

### 产品边界

ShotPaste 是面向 macOS 与 Windows 的原生、本地优先截屏与录屏工具。两个客户端共享产品目标、交互语义和本地化资源，分别使用各自操作系统的原生技术实现，不共享应用代码或跨平台 UI 框架。
- 核心能力：One Shot、截图与标注、滚动截屏、录屏、Quick Access、贴图、截图/剪贴板历史、本地 OCR/QR、设置与受限自动化

### 核心产品流程

```text
菜单栏/托盘 · 全局快捷键 · 受限自动化入口
                      │
                      ▼
             One Shot 冻结选区
                      │
          ┌───────────┼───────────┐
          ▼           ▼           ▼
        截图        滚动截屏       录屏
      标注/OCR/QR   拼接与预览    音视频与实时标注
          └───────────┼───────────┘
                      ▼
       保存 · 复制 · Quick Access · 贴图
                      │
                      ▼
          本地截图与剪贴板历史
```

One Shot 的核心语义是“选区一次，再决定截图、滚动截屏或录屏”；不得把三条流程重新拆成相互冲突的独立入口。操作系统能力差异可以影响实现和控件样式，不能无理由改变共享产品流程。

### 当前目录

```text
.
├── platforms/mac/              # macOS 应用、XCTest 与本地工具
├── platforms/windows/          # Windows 应用、单元测试与原生 E2E
├── resources/localization/     # 两个平台共享的本地化源目录与所有权清单
├── assets/                     # 共享品牌与 README 素材
├── scripts/                    # 构建、测试、签名、发布和基准脚本
├── docs/                       # 功能、自动化、开发和发布说明
└── .github/                    # CI、发布工作流与公开签名证书
```

## 2. 权威层级与冲突处理

1. 用户当前任务、适用的 `AGENTS.md` 和明确授权决定本次工作的范围与操作边界。
2. [`docs/FEATURES.md`](docs/FEATURES.md) 定义跨平台产品行为和隐私边界；新增或改变用户可见能力时必须先核对它。
3. 原生源码、测试和实际运行结果是当前实现证据。macOS 的现状不能自动代表 Windows，反之亦然。
4. [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) 与仓库脚本定义构建、测试、产物、签名和发布入口；不得另造平行流程绕过它们。
5. [`docs/AUTOMATION.md`](docs/AUTOMATION.md)、[`SECURITY.md`](SECURITY.md) 和 [`CONTRIBUTING.md`](CONTRIBUTING.md) 分别拥有自动化、安全与协作规则。
6. `README*.md` 面向用户，负责稳定介绍与导航，不作为详细实现设计的唯一依据。

文档、测试与实现不一致时，先确认受影响平台的真实行为和产品意图，再在本次任务范围内同步 Owner 文档、测试和代码。不得把单个平台的缺陷复制到另一平台来制造表面对齐，也不得静默保留无法解释的差异。

## 3. 设计原则

- **原生实现，产品对齐**：两个客户端独立实现，但功能、流程、信息层级、默认行为、快捷键语义、文案和主要视觉反馈应尽量一致。只记录由操作系统能力或规范导致的差异。
- **本地优先与最小暴露**：捕获内容、剪贴板、历史和诊断数据按设备私有数据处理。新增会发送用户内容的网络能力必须由用户显式配置并最小化发送范围；凭据与敏感数据不得进入源码、普通配置、日志和提交。
- **One Shot 是共享入口**：冻结选区、模式切换、取消恢复和临时状态清理属于同一产品契约；改动任一模式时检查其它模式是否被破坏。
- **原生平台证据优先**：编译成功不等于截屏、录屏、权限、快捷键、窗口层级、DPI 或剪贴板行为正确。涉及这些边界时必须在对应原生系统上运行并验收。
- **状态与用户数据安全**：历史数据库、托管剪贴板文件、临时捕获、录屏恢复文件和用户配置的迁移、删除与清理必须可预测；失败时优先保留用户数据并提供可恢复路径。
- **自动化能力受限且可见**：URL Scheme 与 MCP 只允许文档列出的动作，必须保持参数校验、最小权限、鉴权和可见 UI 反馈；不得扩展为 shell、任意文件访问或无人值守屏幕控制。
- **构建身份集中管理**：macOS Debug/Release 差异只能通过 `AppVariant`、`AppDataLocations` 和对应 xcconfig 集中提供；Windows 通过 `AppBuildIdentity` 和对应 props 集中提供。业务代码不得散落编译类型判断。
- **性能敏感链路有回归保护**：滚动拼接、帧处理、OCR、录制编码、缩略图和历史数据库改动应保留确定性单元测试，并按风险运行现有基准或原生 E2E。
- **本地化与可访问性是功能组成部分**：新增用户可见文本必须进入正确目录的本地化资源；UI 改动同时检查键盘操作、焦点、对比度、缩放和系统辅助能力。

## 4. 研发 Agent 工作流


### 实施规则

- 保持改动聚焦，不顺手格式化、重命名或清理无关文件；脏工作树中的既有内容属于用户。
- 用户可见行为变更默认同时评估两个平台。若任务明确限定单平台，仍需检查另一平台，并在交付中说明无需同步、受操作系统限制或尚待处理的具体原因。
- 优先在现有 Feature、Service、Model、Interop 和 Shared 边界内扩展；跨层依赖或新抽象必须有明确所有权，不能把平台特例堆进公共主流程。
- 修复缺陷时增加能复现问题的最小测试；高风险流程同时覆盖取消、失败、重试、恢复和数据清理。
- 修改持久化结构、配置字段、默认目录、URL Scheme、端口、快捷键或构建身份时，必须检查兼容性、迁移、Debug/Release 隔离和双实例共存。
- 修改自动化工具、路由或协议时，同步协议测试与 [`docs/AUTOMATION.md`](docs/AUTOMATION.md)，并保留 allow-list、loopback、Bearer Token、Host/Origin 校验等安全边界。
- 新增或升级依赖时检查许可证、平台打包影响和供应链风险，并按需同步 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
- 不提交构建产物、结果包、诊断日志、捕获内容、真实剪贴板数据、凭据、私钥、P12 或用户设备路径。

### 文档同步

- 跨平台功能契约变化：更新 [`docs/FEATURES.md`](docs/FEATURES.md)。
- 构建、测试、目录、签名或发布流程变化：更新 [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)。
- URL Scheme 或 MCP 行为变化：更新 [`docs/AUTOMATION.md`](docs/AUTOMATION.md)。
- 面向用户的产品介绍、平台要求、构建入口或下载说明变化：同步全部 10 个 `README*.md`，不得只更新单一语言。
- 安全边界、漏洞处理或发布信任变化：更新 [`SECURITY.md`](SECURITY.md)。
- 贡献与分支流程变化：更新 [`CONTRIBUTING.md`](CONTRIBUTING.md)。
- 发布启动说明或固定发布文案变化：同步 `docs/release/` 下对应平台文件。

## 5. 构建、测试与验收门禁

### 通用要求

- 凡改动 `platforms/mac/**` 或 `platforms/windows/**` 代码，任务收尾前必须在对应原生操作系统完成 Debug 构建。构建失败视为任务未完成，先修复编译或测试错误再交付。
- 共享行为、共享本地化、构建脚本或 CI 变更可能同时影响两个平台；按实际影响运行两个平台的验证，不以当前主机方便程度缩小范围。
- 只报告本次实际执行的命令和结果。未运行的原生交互验收必须明确列为未验证，不能用单元测试、headless E2E、交叉编译或 CI 状态代替。
- 最终回复必须给出：验证命令、通过/失败摘要、对应 Debug 产物绝对路径，以及尚未完成的原生或硬件验收。

### macOS

代码变更的最低验证：

```bash
./scripts/run-tests.sh
./scripts/build_and_run.sh build --configuration Debug
```

标准 Debug 产物只能位于：

```text
.build/macos/Debug/ShotPaste Debug.app
```

- 可运行构建必须使用 `scripts/build_and_run.sh`，并复用 `.build/macos/DerivedData`。
- 测试必须使用 `scripts/run-tests.sh`，并复用 `build/DerivedData`、`build/ci-test.log` 和 `build/ci-test.xcresult`。
- 不得创建 `one-shot-*`、独立 DerivedData、额外可运行 App 副本或 ad-hoc 签名回退。发现并行构建时等待已有构建结束。
- 改动本地化时运行：

  ```bash
  swift -module-cache-path build/swift-module-cache platforms/mac/Tools/Localization/CatalogTool.swift verify
  ```

- 改动 Release 身份、签名、配置、打包或发布链时，额外运行：

  ```bash
  ./scripts/build_and_run.sh build --configuration Release
  codesign --verify --deep --strict --verbose=2 '.build/macos/Release/ShotPaste.app'
  ```

- UI、截屏、录屏、OCR、权限、全局快捷键、窗口层级、菜单栏、URL Scheme 或 MCP 变更，需要启动标准 Debug App 做真实运行验收。

### Windows

代码变更必须在 Windows x64 环境从仓库根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Configuration Debug
```

标准 Debug 产物为：

```text
platforms/windows/src/ShotPaste.Windows/bin/x64/Debug/net8.0-windows10.0.19041.0/win-x64/ShotPasteDebug.exe
```

- 该脚本是 Windows restore、测试、构建身份检查、E2E 编译和 headless parity 的统一入口；摘要位于 `build/e2e/windows-parity/summary.json`。
- UI、截屏、滚动、录屏、OCR、剪贴板、权限、快捷键、DPI 或窗口管理变更必须在已登录的真实 Windows 桌面运行交互验证，并显式传入 Debug 产物：

  ```powershell
  $product = (Resolve-Path '.\platforms\windows\src\ShotPaste.Windows\bin\x64\Debug\net8.0-windows10.0.19041.0\win-x64\ShotPasteDebug.exe').Path
  .\scripts\test-windows-parity.ps1 -Configuration Debug -Tier Interactive -SkipBuild -ProductExecutable $product
  ```

  同时记录系统、DPI 和硬件条件；要求 150% DPI 时增加 `-RequireDpiScale 1.5`。
- hosted `windows-latest` 构建只能证明非交互验证通过，不能作为真实桌面交互验收。
- Release、打包或构建身份变更额外运行 `scripts/build-windows.ps1 -Configuration Release`；发布流程变化还需验证 self-contained single-file 产物。

### 文档与仓库质量

- 纯文档变更不强制构建原生 App；检查所有相对链接、命令、路径、平台名称和跨语言同步范围。
- 所有任务交付前运行 `git diff --check`，再检查 `git status --short` 与最终 diff，确认没有无关修改和生成产物。

## 6. 签名、发布与 Git 边界

- macOS 可运行构建拒绝 ad-hoc 签名。没有 Apple 开发身份时，只能用 `scripts/create-signing-cert.sh` 创建本地开发专用的 `ShotPaste Local Development` 身份。
- 正式 macOS Release 当前使用固定自签名身份 `ShotPaste Release Self-Signed`，SHA-1 指纹为 `8CBB386A17831C9C093C6BA693C4F60BC239A213`，公开证书位于 `.github/signing/ShotPaste-Release-Self-Signed.crt`。
- 严禁更换、重建、重命名或轮换正式发布证书。含私钥 P12 与密码只能存在于 GitHub Actions Secrets `SELF_SIGNED_CERT_P12` 和 `SELF_SIGNED_CERT_PASSWORD`，不得读取、导出、打印或提交。
- `main` 是日常开发分支；`release` 只接受由仓库 Owner 发起的 `main → release` 直接 Pull Request，不创建 promotion/staging 中间分支，不向 `release` 直接提交或推送。
- 正式标签只允许仓库 Owner 在已验收且属于 `release` 的提交上创建，格式为 `macos-vMAJOR.MINOR.PATCH` 或 `windows-vMAJOR.MINOR.PATCH`；标签不可变，每个平台独立发布。
- 未经用户明确授权，不执行提交、推送、rebase、历史重写、建/删分支、建标签、发布或 GitHub Release 操作。即使获得发布授权，也必须先核对分支、目标提交、CI、原生产物和人工验收状态。

## 7. Owner 文档地图

- [`README.md`](README.md) 与其余语言 `README*.md`：面向用户的项目介绍、平台、构建和下载导航。
- [`docs/FEATURES.md`](docs/FEATURES.md)：共享功能契约、语言与隐私边界。
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)：目录、依赖、构建、测试、Debug/Release 隔离、签名、本地化与自动发布。
- [`docs/AUTOMATION.md`](docs/AUTOMATION.md)：URL Scheme、MCP 协议、工具 allow-list 与传输安全。
- [`CONTRIBUTING.md`](CONTRIBUTING.md)：贡献验证、分支管理、Pull Request 与 `main → release` 流程。
- [`SECURITY.md`](SECURITY.md)：安全模型、漏洞报告、发布信任和依赖边界。
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)：第三方版权与许可证归属。
- [`.github/workflows/ci.yml`](.github/workflows/ci.yml)：Pull Request、`main`、`release` 的平台验证矩阵。
- [`.github/workflows/release-macos.yml`](.github/workflows/release-macos.yml) 与 [`.github/workflows/release-windows.yml`](.github/workflows/release-windows.yml)：两个平台独立的正式发布流水线。

## 8. 任务范围提示

- 做历史数据恢复兼容方案前，先判断是否有必要做，未合入 release 分支意味着没有真实用户，不要过度考虑兼容。

