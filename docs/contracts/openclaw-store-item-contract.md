# OpenClaw Store Item Contract

Date: 2026-03-20
Status: Frozen for V1
Scope: OpenClaw official desktop store

## Purpose

This contract defines the canonical `StoreItem` shape shared by:

- catalog generation in this repo
- installer / repair report generation in this repo
- desktop store rendering in the future desktop shell

The contract is intentionally UI-agnostic.

## V1 Item Types

```text
native-plugin
  -> standard OpenClaw plugin item

bundle-plugin
  -> imported compatible bundle item
  -> reserved in V1 contract even if first demo defers runtime support

capability-pack
  -> packaged capability outcome
  -> may include plugin payload, skills, runtime, provisioning, and verification
```

## Canonical Shape

```text
StoreItem
|
+-- identity
|    - id
|    - slug
|    - version
|
+-- presentation
|    - title
|    - summary
|    - description
|    - publisher
|    - icons / screenshots
|
+-- classification
|    - itemType
|    - categories[]
|    - tags[]
|
+-- trust
|    - channel
|    - trustLevel
|    - audit
|
+-- compatibility
|    - platforms[]
|    - architectures[]
|    - openClawVersionRange
|
+-- contents
|    - pluginIds[]
|    - skillIds[]
|    - runtimeProfiles[]
|    - includedItemIds[]
|
+-- install
|    - installStrategy
|    - artifactRefs[]
|    - supportsOfflineInstall
|    - supportsRepair
|    - supportsUninstall
|
+-- prerequisites
|    - checks[]
|
+-- verification
|    - checks[]
|    - readinessRules[]
|
+-- support
     - docsUrl
     - supportUrl
     - knownIssues[]
```

## Required Fields

The following fields are mandatory for every V1 store item:

```text
id
slug
version
title
summary
publisher
itemType
categories[]
tags[]
trust
compatibility
contents
install
prerequisites
verification
support
```

## Field Semantics

### identity

```text
id
  -> stable machine-readable identifier
  -> unique within the official catalog
  -> recommended to match packId for capability-pack items

slug
  -> stable human-readable identifier for URLs and routing
  -> must remain immutable once published

version
  -> semantic version string of the store item artifact
```

### presentation

```text
title
  -> user-facing name

summary
  -> one-line concise description

description
  -> optional longer detail text

publisher
  -> user-visible publisher label such as "OpenClaw Official"
```

### classification

```text
itemType
  -> one of:
     native-plugin
     bundle-plugin
     capability-pack

categories[]
  -> curated browsing buckets

tags[]
  -> search and filtering labels
```

### trust

```text
channel
  -> release channel, for example:
     official
     beta
     local

trustLevel
  -> coarse trust label, for example:
     official-curated
     reviewed-compatible

audit
  -> audit status, audit source, and blocking findings summary
```

### compatibility

```text
platforms[]
  -> supported operating systems

architectures[]
  -> supported CPU architectures

openClawVersionRange
  -> supported OpenClaw version range
```

### contents

```text
pluginIds[]
  -> OpenClaw plugin ids installed or enabled by this item

skillIds[]
  -> skills expected after install

runtimeProfiles[]
  -> named runtime profiles required by this item

includedItemIds[]
  -> reserved for bundle-style compositions
```

### install

```text
installStrategy
  -> concrete install path, for example:
     workflow-pack-installer
     local-plugin-archive
     bundle-import

artifactRefs[]
  -> all installable and support artifacts for this item

supportsOfflineInstall
  -> install can complete without OpenClaw fetching the payload online

supportsRepair
  -> repair flow is first-class

supportsUninstall
  -> uninstall flow is supported and should preserve state consistency
```

### prerequisites

```text
checks[]
  -> machine or manual prerequisites that may block readiness
```

### verification

```text
checks[]
  -> post-install checks run by install or repair

readinessRules[]
  -> deterministic mapping into:
     Ready
     Needs Setup
     Needs Repair
```

### support

```text
docsUrl
  -> primary item documentation

supportUrl
  -> support or issue reporting destination

knownIssues[]
  -> explicit caveats safe to surface in desktop UI
```

## Item-Type Mapping

```text
workflow-pack manifest today
  -> capability-pack item tomorrow

openclaw plugin archive
  -> native-plugin item

compatible imported external bundle
  -> bundle-plugin item
```

## Non-Negotiable Rule

```text
StoreItem represents a capability outcome,
not only a downloadable file.
```

That means an item contract must be able to answer:

- what gets installed
- what still needs setup
- how readiness is verified
- how repair is performed
