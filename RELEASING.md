# 发布说明

## 发布目标

将 Windows 安装包发布到 GitHub Releases，让用户只看到并下载一个安装文件：

- `OpenClaw-Setup-Windows-x64.exe`

现在 Release 还会附带 3 个维护包：

- `OpenClaw-Start.exe`
- `OpenClaw-Update.exe`
- `OpenClaw-Repair.exe`

## 手动发布流程

```text
1. 确保 main 已更新
2. 创建 tag，例如 v0.1.0
3. push main
4. push tag
5. 等待 GitHub Actions 自动构建并上传 Release 资产
```

命令示例：

```powershell
git checkout main
git pull --ff-only
git tag v0.1.0
git push origin main
git push origin v0.1.0
```

## 本地预构建

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-release-assets.ps1 -ReleaseTag v0.1.0
```

默认输出目录：

```text
release\
```

默认只产出一个安装包：

```text
release\OpenClaw-Setup-Windows-x64.exe
```

同时产出 3 个一键维护包：

```text
release\OpenClaw-Start.exe
release\OpenClaw-Update.exe
release\OpenClaw-Repair.exe
```

## 自动发布规则

- workflow 文件：`.github/workflows/windows-release.yml`
- tag 规则：`v*`
- tag push 后自动创建/更新 GitHub Release
- Release 上传 4 个 EXE：安装器 + 一键启动/更新/修复

其中：

- `OpenClaw-Start.exe` 对应一键启动
- `OpenClaw-Update.exe` 对应一键更新
- `OpenClaw-Repair.exe` 对应一键修复

首次安装请使用 `OpenClaw-Setup-Windows-x64.exe`；其余 3 个 EXE 面向已经安装好的环境。
