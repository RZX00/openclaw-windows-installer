# Cross-Repo Context

This repository is one half of the current OpenClaw platform.

```text
Platform repos
├─ /mnt/e/app/openclaw-setup-cn
│  └─ installer / workflow-pack / release authority
└─ /mnt/e/app/aip
   └─ desktop shell / payment / entitlement / store control plane
```

## Repo Role

`openclaw-setup-cn` owns:

- Windows one-click installer outputs
- workflow-pack and capability-pack build pipelines
- install / repair / maintenance authority
- official release assets
- store catalog and store-item release metadata
- install-registry export logic

## Sibling Repo Role

`/mnt/e/app/aip` owns:

- signed-in desktop shell
- payment and entitlement system
- desktop store UI
- local Tauri bridge
- backend APIs used by the desktop app

## Canonical Integration Seams

When tasks span both repos, treat these as the shared contracts:

- `release/openclaw-store-catalog.json`
- `release/store-items/*.json`
- `%ProgramData%/OpenClaw/reports/store/install-registry.json`
- workflow-pack installer/report contracts
- future `release-manifest.json` / launcher action bridge

## Working Rule

If a task mentions any of the following, inspect the sibling repo before making architectural decisions:

- desktop store
- ownership / install state
- workflow-pack install UX
- release assets
- payment-gated install
- launcher Start / Update / Repair integration

## Key Reference Docs

- `/mnt/e/app/openclaw-setup-cn/docs/plans/2026-03-21-aip-openclaw-integration-research.md`
- `/mnt/e/app/openclaw-setup-cn/docs/plans/2026-03-23-aip-openclaw-repo-convergence-plan.md`

## Default Decision

Do not assume this repo is standalone.
Assume it is part of the same product as `/mnt/e/app/aip`, with separate execution authority.
