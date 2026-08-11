# AGENTS.md
# 项目
ShotPaste 包含彼此独立的 macOS 与 Windows 原生实现，核心范围为截图、滚动截屏、录屏、截图/剪贴板历史，并要求两个平台保持产品体验对齐。

# 准则
* 凡是改动 Windows（`platforms/windows/**`）或 macOS（`platforms/mac/**`）代码的任务，在任务收尾前必须构建当前操作系统对应版本：macOS 环境只构建 macOS 版本，Windows 环境只构建 Windows 版本，无需跨平台构建；并在最终回复中给出产物绝对路径和构建/测试结果摘要。构建失败视为任务未完成，先修复编译或测试错误再交付
* macOS 的可运行构建统一使用 `./scripts/build_and_run.sh build`，Debug 与 Release 分别只保留在 `.build/macos/Debug` 和 `.build/macos/Release`，不得新增可运行副本或 ad-hoc 签名回退
* 本地命令行构建必须复用 `.build/macos/DerivedData`，测试必须复用 `build/DerivedData`、固定日志和固定结果包；不要在仓库内创建 `one-shot-*`、独立 DerivedData 或其他隔离构建目录。遇到并行构建时等待已有构建完成，不用新目录绕开
* mac 版本和 Windows 版本应该始终保持功能、实现逻辑、UI、UE、用户体验几乎一致，除非是因为操作系统本身的差异才不进行对齐
* 更新 README 需要同时更新所有语言版本的 README
* macOS 将隐私权限绑定到签名身份，严禁更换、重建、重命名或轮换发布证书；当前尚未获得 Apple Developer ID 证书，允许使用固定的自签名证书构建。公开证书存放于 `.github/signing/ShotPaste-Release-Self-Signed.crt`，含私钥的 P12 与密码仅托管于 GitHub Actions Repository Secrets `SELF_SIGNED_CERT_P12`/`SELF_SIGNED_CERT_PASSWORD`，固定 SHA-1 指纹为 `8CBB386A17831C9C093C6BA693C4F60BC239A213`，详情见 `docs/DEVELOPMENT.md` 的 “Release signing identity”
