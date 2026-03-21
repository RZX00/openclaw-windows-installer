# OpenClaw Store Catalog Assets

This directory stores the curated catalog inputs used by
`client/build-openclaw-store-catalog.ps1`.

```text
client/catalog/
+-- catalog.schema.json
+-- items/
|   +-- <item-id>.json
+-- collections/
    +-- <collection-id>.json
```

## Asset Roles

- `catalog.schema.json`
  - freezes the machine-readable catalog payload consumed by desktop
- `items/*.json`
  - per-item override metadata layered on top of workflow-pack manifests
- `collections/*.json`
  - curated store-home groupings for the official desktop demo

## Build Flow

```mermaid
flowchart LR
    A["workflow-packs/*/pack-manifest.json"] --> B["build-openclaw-store-catalog.ps1"]
    C["client/catalog/items/*.json"] --> B
    D["client/catalog/collections/*.json"] --> B
    E["release installers + archives + metadata"] --> B
    B --> F["release/openclaw-store-catalog.json"]
    B --> G["release/store-items/*.json"]
```

## Collection Behavior

Collection files are filtered against the item ids actually present in the
current build.

This lets the same catalog builder handle a single-pack demo release and future
multi-pack releases without duplicating collection logic.

## Release Outputs

The release pipeline should now be understood as producing these store-facing
artifacts together:

```text
installers
archives
build metadata
source locks
store item metadata
store catalog metadata
```


## Local Install Registry

The store layer now also has a local install-registry projection contract:

```text
catalog + install-state + latest store report
  -> export-openclaw-store-install-registry.ps1
  -> install-registry.json
```

```mermaid
flowchart LR
    A["release/openclaw-store-catalog.json"] --> D["export-openclaw-store-install-registry.ps1"]
    B["<OpenClaw>/install-state.json"] --> D
    C["<OpenClaw>/reports/store/<item>/latest.json"] --> D
    D --> E["<OpenClaw>/reports/store/install-registry.json"]
```

Registry purpose:

- freezes one store-facing local contract for `installed`, `readiness`, and `available actions`
- lets desktop UI read one merged registry instead of joining 3 data sources itself
- preserves a lane distinction between curated catalog items and imported local-only packs

Contract files:

- `client/catalog/catalog.schema.json`
  - release catalog contract
- `client/catalog/install-registry.schema.json`
  - local install-registry contract
