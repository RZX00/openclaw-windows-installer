# 发布说明

## 发布目标

当前 Release 不再只是 Windows 安装器 EXE，而是一个最小可演示的
OpenClaw desktop store release set。

```text
Release Assets
release/
+-- OpenClaw-Setup-Windows-x64.exe
+-- OpenClaw-Start.exe
+-- OpenClaw-Update.exe
+-- OpenClaw-Repair.exe
+-- OpenClaw-Workflow-Pack-Foundation-Common.exe
+-- OpenClaw-Workflow-Pack-Foundation-Common.zip
+-- workflow-pack-build-metadata-foundation-common.json
+-- workflow-pack-source-lock-foundation-common.json
+-- openclaw-store-catalog.json
+-- store-items/
    +-- foundation-common.json
```

当前默认官方 starter pack 是 `foundation-common`。
如果需要继续发布兼容型旧包，例如 `workflow-zone`，请显式传入
`-PackIds workflow-zone` 或组合多个 `PackIds`。

## 当前发布门槛

`foundation-common` 仍然包含两个 `required` 但尚未确认权威源的 skills：

- `proactive-agent`
- `memory-setup`

因此当前仓库必须区分两种构建语义：

- 正式发布构建
  不允许带放行参数；若 source gate 未解除，构建应失败。
- 开发态 demo 构建
  可以显式使用放行参数生成本地演示资产，但 catalog / item metadata 会保留 `releaseBlocked: true`。

## 手动发布流程

```text
1. 确保 main 已更新
2. 确认 foundation-common 的 required source 全部已锁定
3. 创建 tag，例如 v0.1.3
4. push main
5. push tag
6. 等待 GitHub Actions 运行 release build
```

命令示例：

```powershell
git checkout main
git pull --ff-only
git tag v0.1.3
git push origin main
git push origin v0.1.3
```

## 本地预构建

正式发布构建：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-release-assets.ps1 -ReleaseTag v0.1.3
```

当前开发态 demo 构建：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-release-assets.ps1 -ReleaseTag v0.1.3 -AllowUnresolvedSkillSources -AllowReleaseBlockedCatalogItems
```

如果要显式构建多个 capability-pack：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-release-assets.ps1 -ReleaseTag v0.1.3 -PackIds foundation-common,workflow-zone -AllowUnresolvedSkillSources -AllowReleaseBlockedCatalogItems
```

## 默认输出目录

```text
release/
├─ OpenClaw-Setup-Windows-x64.exe
├─ OpenClaw-Start.exe
├─ OpenClaw-Update.exe
├─ OpenClaw-Repair.exe
├─ OpenClaw-Workflow-Pack-Foundation-Common.exe
├─ OpenClaw-Workflow-Pack-Foundation-Common.zip
├─ workflow-pack-build-metadata-foundation-common.json
├─ workflow-pack-source-lock-foundation-common.json
├─ openclaw-store-catalog.json
└─ store-items/
   └─ foundation-common.json
```

## Store Catalog Inputs

Catalog metadata comes from three layers:

```text
client/workflow-packs/*/pack-manifest.json
client/catalog/items/*.json
client/catalog/collections/*.json
```

The catalog builder maps them onto release artifacts so the desktop shell can
understand:

- which installer/archive belongs to each item
- which collection should surface on Store Home
- which readiness states the installer and maintenance scripts persist
- which items are still release-blocked by source or audit state

## CI / GitHub Release

- workflow 文件：`.github/workflows/windows-release.yml`
- tag 规则：`v*`
- tag push 会触发 Windows release build
- 正式对外发布前，必须先确认 `foundation-common` 的 source gate 已解除
- 本地 demo 资产应优先用上面的开发态命令生成和验证

## English Release Notes

Current release set for the first desktop store demo:

- `OpenClaw-Setup-Windows-x64.exe`
- `OpenClaw-Start.exe`
- `OpenClaw-Update.exe`
- `OpenClaw-Repair.exe`
- `OpenClaw-Workflow-Pack-Foundation-Common.exe`
- `OpenClaw-Workflow-Pack-Foundation-Common.zip`
- `workflow-pack-build-metadata-foundation-common.json`
- `workflow-pack-source-lock-foundation-common.json`
- `openclaw-store-catalog.json`
- `store-items/foundation-common.json`

Official release remains blocked until `proactive-agent` and `memory-setup` are
pinned to authoritative upstream sources. Development demo builds may still be
generated locally with the explicit override flags described above.
