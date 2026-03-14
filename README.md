# OpenClaw Windows 一键安装包装层

> 基于 [OpenClaw](https://github.com/openclaw/openclaw) 的 Windows 一键安装、启动、更新、修复与 Dashboard 打开包装层。

本仓库不是 OpenClaw 官方仓库，而是一个面向 Windows 使用场景的工程化包装项目。  
它的目标很直接：把原本需要手动跑命令、配置环境、排查安装路径、处理更新/修复的流程，收敛成更稳定、更适合普通用户的 Windows 一键体验。

## 这个仓库解决什么问题

- 提供 Windows 图形安装器，而不是只让用户手动跑 PowerShell
- 提供 `一键启动`、`一键更新`、`一键修复` 桌面入口
- 自动探测已有安装目录，而不是只依赖单一固定路径
- 启动后自动打开正确的 OpenClaw Dashboard
- 将维护流程尽量对齐官方 CLI，减少包装层与上游脱节
- 为 Windows 打包、图标、入口脚本和维护链路提供统一工程结构

## 我们主要做了什么

```text
Windows Wrapper
+--------------------------------------------------------------+
| 安装器 UI                                                    |
| 一键启动 / 更新 / 修复 EXE                                   |
| PowerShell 维护脚本                                          |
| Dashboard 自动打开                                           |
| 安装目录智能发现                                             |
| Windows 图标 / 清单 / 打包脚本                               |
| 与 OpenClaw 上游版本变更的兼容性适配                         |
+--------------------------------------------------------------+
```

更具体地说，本项目主要包含以下工作：

- **安装器包装**：把安装、提权、日志、进度、外部窗口协同整合到一个 Windows 安装体验里
- **维护链路工程化**：为启动、更新、修复分别提供独立入口，并统一落到维护脚本
- **Dashboard 打开链路**：优先使用官方 CLI 获取正确 URL，避免自己拼接旧路径或过时参数
- **Windows 兼容适配**：围绕 Node 版本、Gateway 持久化、更新判断、健康检查做兼容处理
- **构建与发布资产**：提供图标、manifest、打包脚本和根目录兼容入口

## 与上游 OpenClaw 的关系

- **上游项目**：`OpenClaw`
- **上游仓库**：<https://github.com/openclaw/openclaw>
- **上游许可**：`MIT`
- **当前仓库定位**：Windows 包装层 / 安装层 / 维护层，不是 OpenClaw 核心源码主仓

本仓库中保留了一个用于兼容构建的 OpenClaw vendored snapshot，位置在 `client/package`。  
这样做的目的，是让 Windows 包装层在适配特定上游版本时有稳定、可复现的构建基线，而不是每次都依赖外部环境临时拉取。

## 开源与许可

- 本仓库包装层代码采用 `MIT` 协议发布，见 `LICENSE`
- 本仓库包含基于 OpenClaw 修改、适配或再包装的内容，归属说明见 `NOTICE`
- OpenClaw 上游许可文件保留在 `client/package/LICENSE`

换句话说：

```text
Open Source Boundary
+--------------------------------------------------------------+
| 我们开源自己的 Windows 包装层代码                            |
| 我们明确标注项目基于 OpenClaw 开发                           |
| 我们保留上游许可与归属说明                                   |
| 我们不把自己描述成 OpenClaw 官方                             |
+--------------------------------------------------------------+
```

## 仓库结构

- `client/`：Windows 包装层源码、图标、构建脚本、维护脚本、兼容清单
- `client/package/`：用于兼容构建的 OpenClaw 上游快照
- `build-windows-oneclick-installer.ps1`：根目录兼容入口，转发到 `client/`
- `install-windows.ps1` / `install-windows-en.ps1`：根目录兼容安装入口
- `install-windows-core.ps1`：根目录兼容核心入口

## 本地构建

### 构建 Windows 一键安装包

```powershell
powershell -ExecutionPolicy Bypass -File .\client\build-windows-oneclick-installer.ps1 -Channel latest -Locale zh-CN
```

默认产物位于：

```text
client\dist\windows-oneclick\
```

通常会生成：

- Windows 安装器 EXE
- `一键启动` EXE
- `一键更新` EXE
- `一键修复` EXE

## Release 发布

如果要让用户直接从 GitHub 下载，请使用仓库的 `Releases`：

```text
git tag v0.1.0
git push origin main
git push origin v0.1.0
```

推送 `v*` tag 后，GitHub Actions 会自动：

- 构建 Windows 安装包
- 生成 `SHA256` 校验文件
- 创建或更新对应的 GitHub Release
- 上传可直接下载的安装文件

默认上传的主文件名为：

```text
OpenClaw-Setup-Windows-x64.exe
```

本地也可以直接运行发布脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-release-assets.ps1 -ReleaseTag v0.1.0
```

## 设计原则

- **官方优先**：优先复用 OpenClaw 官方 CLI 合同，而不是自己维护一套分叉行为
- **Windows 友好**：把复杂命令行流程尽量收敛为普通用户可理解的入口
- **失败可恢复**：安装、更新、修复尽量可回退、可重试、可定位日志
- **兼容先于炫技**：遇到上游更新时，优先保证包装层继续可用

## 不包含什么

这个公开版本不再包含以下方向的实现：

- 商业授权中心服务端
- DRM / 授权码门禁逻辑
- 与当前 Windows 直装版无关的私有运营逻辑

## 致谢

感谢 OpenClaw 上游项目及其贡献者提供的核心能力与开源基础。  
如果你要了解 OpenClaw 本身，请优先访问：

- 上游仓库：<https://github.com/openclaw/openclaw>
- 官方文档：<https://docs.openclaw.ai>

---

如果你在这个仓库里遇到问题，请默认把它理解为**Windows 包装层问题**；  
如果问题发生在 OpenClaw 核心功能本身，请优先到上游仓库确认。
