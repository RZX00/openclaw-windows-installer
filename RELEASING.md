# 发布说明

## 发布目标

将 Windows 安装包发布到 GitHub Releases，让用户可以直接下载：

- `OpenClaw-Setup-Windows-x64.exe`
- `OpenClaw-Setup-Windows-x64.exe.sha256`

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

## 自动发布规则

- workflow 文件：`.github/workflows/windows-release.yml`
- tag 规则：`v*`
- tag push 后自动创建/更新 GitHub Release
- 同时上传 EXE、SHA256 和 `release-manifest.json`
