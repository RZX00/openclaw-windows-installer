# OpenClaw Plugin Market Research Report

Date: 2026-03-20
Status: Research round 1 complete
Scope: OpenClaw desktop plugin market only

## Executive Summary

The main conclusion is simple:

```text
OpenClaw already has much of the plugin substrate.
What it lacks is the productized desktop store layer.
```

OpenClaw already has:

- plugin install / enable / disable / update / uninstall / doctor
- plugin manifests and validation
- plugin-shipped skills
- skills precedence rules
- ClawHub as a public skill registry
- bundle compatibility import
- onboarding flows that already install and configure capabilities

What OpenClaw lacks:

- a desktop store entrypoint
- a curated official catalog
- item detail pages that carry setup burden
- a clear install state machine
- explicit readiness and repair semantics
- a unified way to represent packaged capability outcomes

## Core Finding

The research conclusion is not "rewrite plugins".

It is:

```text
OpenClaw should build:
  existing plugin substrate
  + desktop store UX
  + install orchestration
  + readiness / repair state model
```

## OpenClaw Current State

Based on the official OpenClaw docs, the current substrate is already meaningful.

### 1. Native plugin system

OpenClaw already supports:

- `openclaw plugins install`
- `openclaw plugins enable`
- `openclaw plugins disable`
- `openclaw plugins uninstall`
- `openclaw plugins update`
- `openclaw plugins doctor`
- `openclaw plugins info`

It already supports:

- local directory install
- local archive install
- npm install for plugins
- manifest-based config validation before runtime code executes

### 2. Skills system

OpenClaw already supports:

- bundled skills
- managed local skills
- workspace skills
- plugin-shipped skills
- skill precedence rules

This is a major reason the future store should not reduce everything to "just plugin packages".

### 3. ClawHub already acts like a skills market

ClawHub already provides:

- skill discovery
- install
- update
- publish
- version history
- registry semantics

So OpenClaw is not starting from zero on the idea of an ecosystem catalog.

### 4. Onboarding already installs and configures capabilities

OpenClaw onboarding already configures:

- workspace
- gateway
- channels
- daemon
- skills

This means the product already accepts the idea that some capabilities need a guided setup flow beyond raw file install.

## Benchmark Findings

### VS Code

Most useful patterns:

- marketplace inside the product
- install from marketplace and from local package
- extension packs and recommendations
- private marketplace and enterprise control

OpenClaw implication:

```text
V1 should support both official catalog install
and local package import.
```

### Obsidian

Most useful patterns:

- third-party plugin risk is explicit
- install is not the same as enable
- safe usage and trust are surfaced clearly

OpenClaw implication:

```text
Installed != Ready
```

This is one of the most important product lessons for OpenClaw.

### JetBrains

Most useful patterns:

- install from disk
- custom repositories
- policy control
- compatibility discipline
- governance around review and approval

OpenClaw implication:

```text
Even before community scale,
OpenClaw should have a first-class curated catalog
with compatibility and policy semantics.
```

### Raycast

Most useful patterns:

- desktop-native store UX
- metadata-rich detail pages
- detail page as onboarding surface
- host-managed runtime model

OpenClaw implication:

```text
The detail page must teach the user
what is included, what is required,
and what still needs manual setup.
```

## Pattern Extraction

The benchmark set converges on six product rules.

### 1. In-app store first

The main user journey should happen inside OpenClaw desktop, not on a website.

### 2. Install state must be explicit

The store must distinguish:

- installed
- ready
- needs setup
- needs repair
- blocked
- update available

### 3. The real install unit is a capability outcome

For OpenClaw, a store item often needs to include:

- plugin payload
- skills payload
- runtime payload
- provisioning actions
- prerequisite checks
- verification checks

### 4. Host-managed runtime is more stable

OpenClaw should prefer runtime profiles owned by the host product, not plugin-by-plugin runtime acquisition.

### 5. Trust must be productized

Users should see:

- source
- publisher
- package type
- capabilities
- risk notes
- setup requirements

### 6. Official curated catalog first

The first version should not be an open community marketplace.
It should be an official curated OpenClaw catalog.

## Local Repo Implication

This repo already contains a strong local pattern that supports the research conclusion:

```text
workflow pack
  -> packaged payload
  -> source lock
  -> runtime profile
  -> provisioning
  -> prerequisite checks
  -> readiness verification
  -> repair semantics
```

The clearest current example is:

- [client/workflow-packs/foundation-common/pack-manifest.json](/E:/app/openclaw-setup-cn/client/workflow-packs/foundation-common/pack-manifest.json)

This strongly suggests that the future store should support a first-class
`capability-pack` item type instead of forcing everything into a plain plugin model.

## Strategic Recommendation

The research recommendation is:

```text
Do not start by rewriting the plugin core.

Start by building:
  - an official curated desktop store
  - a unified item contract
  - an install state machine
  - update / repair / uninstall flows
  - a capability-pack model that reuses current installer work
```

## Follow-On Document

This report is the round-1 research synthesis.
The concrete V1 product and architecture recommendation is captured here:

- [docs/plans/2026-03-20-openclaw-plugin-market-v1-architecture.md](/E:/app/openclaw-setup-cn/docs/plans/2026-03-20-openclaw-plugin-market-v1-architecture.md)

## Sources

### OpenClaw

- [OpenClaw Plugins](https://docs.openclaw.ai/tools/plugin)
- [OpenClaw CLI plugins](https://docs.openclaw.ai/cli/plugins)
- [OpenClaw Plugin Manifest](https://docs.openclaw.ai/plugins/manifest)
- [OpenClaw Plugin Bundles](https://docs.openclaw.ai/plugins/bundles)
- [OpenClaw Skills](https://docs.openclaw.ai/tools/skills)
- [OpenClaw ClawHub](https://docs.openclaw.ai/tools/clawhub)
- [OpenClaw Community plugins](https://docs.openclaw.ai/plugins/community)
- [OpenClaw Onboarding Wizard](https://docs.openclaw.ai/start/wizard)

### Benchmarks

- [VS Code Extension Marketplace](https://code.visualstudio.com/docs/configure/extensions/extension-marketplace)
- [VS Code Extension Runtime Security](https://code.visualstudio.com/docs/configure/extensions/extension-runtime-security)
- [VS Code Enterprise Extensions](https://code.visualstudio.com/docs/enterprise/extensions)
- [VS Code Private Marketplace announcement](https://code.visualstudio.com/blogs/2025/11/18/PrivateMarketplace/)
- [Obsidian Community Plugins](https://help.obsidian.md/community-plugins)
- [Obsidian Plugin Security](https://help.obsidian.md/plugin-security)
- [JetBrains Managing Plugins](https://www.jetbrains.com/help/webstorm/managing-plugins.html)
- [JetBrains Install Plugins From the Command Line](https://www.jetbrains.com/help/idea/install-plugins-from-the-command-line.html)
- [JetBrains Marketplace Approval Guidelines](https://plugins.jetbrains.com/docs/marketplace/jetbrains-marketplace-approval-guidelines.html)
- [JetBrains Plugin Control Rules](https://www.jetbrains.com/help/ide-services/manage-available-plugins.html)
- [Raycast Install an Extension](https://developers.raycast.com/basics/install-an-extension)
- [Raycast Security](https://developers.raycast.com/information/security)
- [Raycast Prepare an Extension for Store](https://developers.raycast.com/basics/prepare-an-extension-for-store)
