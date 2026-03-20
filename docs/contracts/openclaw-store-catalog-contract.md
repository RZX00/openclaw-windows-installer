# OpenClaw Store Catalog Contract

Date: 2026-03-20
Status: Frozen for V1
Scope: Official curated OpenClaw desktop catalog

## Purpose

This contract defines the structure of the official catalog JSON emitted by
this repo and consumed by the desktop shell.

The catalog must be:

- deterministic
- machine-readable
- sufficient for install and readiness UX
- independent from any specific UI framework

## Catalog Shape

```text
Catalog
|
+-- catalogVersion
+-- generatedAt
+-- publisher
+-- channel
+-- items[]
+-- collections[]
+-- metadata
     - generator
     - sourceRepo
     - schemaVersion
```

## Required Top-Level Fields

```text
catalogVersion
generatedAt
publisher
channel
items[]
```

## Top-Level Semantics

```text
catalogVersion
  -> semantic version of the catalog payload format or release set

generatedAt
  -> ISO 8601 UTC timestamp for the generated artifact

publisher
  -> catalog owner label, for example:
     OpenClaw Official

channel
  -> catalog release channel, for example:
     official
     beta

items[]
  -> array of StoreItem objects

collections[]
  -> optional curated collections for Store Home
```

## StoreItem Coverage In Catalog

Each catalog item must cover these categories of information:

```text
identity
presentation
classification
source
trust
compatibility
contents
install
prerequisites
verification
support
```

## Source Contract

Every catalog item must include a `source` section that can answer:

```text
what manifest produced this item
what build metadata produced this item
what source lock was used
which artifacts belong to this item
```

Recommended shape:

```text
source
  manifestPath
  buildMetadataFile
  sourceLockFile
  releaseArtifacts[]
```

## Artifact Reference Contract

Every installable or support file exposed to the desktop shell must use the
same `artifactRef` shape:

```text
artifactRef
  kind
  fileName
  relativePath
  sha256
  sizeBytes
  required
```

Recommended `kind` values:

```text
installer
archive
build-metadata
source-lock
catalog-item
```

## Trust Contract

Catalog trust metadata must surface:

```text
publisher
trustLevel
auditStatus
auditSummary
sourcePinned
releaseBlocked
```

## Compatibility Contract

Compatibility must be explicit, not inferred in desktop code.

Required compatibility fields:

```text
platforms[]
architectures[]
openClawVersionRange
requiresAdmin
supportsOfflineInstall
```

## Contents Contract

Each item must explicitly disclose what the install produces:

```text
pluginIds[]
skillIds[]
runtimeProfiles[]
includedItems[]
```

## Install Contract

Each item must define how desktop initiates installation:

```text
install
  strategy
  primaryArtifact
  artifactRefs[]
  supportsRepair
  supportsUninstall
```

## Prerequisite Contract

Prerequisites must be structured so the desktop shell can explain why an item
is not ready.

Recommended fields per prerequisite:

```text
id
type
severity
message
manual
```

## Verification Contract

Verification must expose both checks and readiness rules:

```text
verification
  checks[]
  readinessRules[]
  expectedReadinessStates[]
```

For V1, `expectedReadinessStates[]` must always be:

```text
Ready
Needs Setup
Needs Repair
```

## Support Contract

Support metadata must be safe to show directly in desktop UI:

```text
docsUrl
supportUrl
knownIssues[]
repairHints[]
```

## Collections Contract

Collections are optional in Task 2 but reserved now for Store Home.

Recommended shape:

```text
collection
  id
  title
  summary
  itemIds[]
```

## Non-Negotiable Rule

```text
The catalog must be self-describing enough that the desktop app
does not need hidden repo knowledge to install, verify, or explain an item.
```
