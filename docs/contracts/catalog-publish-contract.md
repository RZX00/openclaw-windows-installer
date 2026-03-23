# OpenClaw Catalog Publish Contract

Date: 2026-03-23
Status: Frozen for Stage 1
Scope: official publish pipeline in `openclaw-setup-cn`

## Purpose

This contract defines the publish outputs emitted by the Stage 1 catalog and
artifact pipeline.

The system now publishes both legacy store-facing assets and vNext market-facing
assets in parallel.

## Output Set

```ascii
Legacy outputs
├─ release/openclaw-store-catalog.json
└─ release/store-items/*.json

vNext outputs
├─ release/openclaw-market-catalog.json
├─ release/store-items-vnext/*.json
├─ release/openclaw-market-artifact-index.json
└─ release/openclaw-market-trust-snapshot.json
```

## Publish Rule

```text
Legacy catalog outputs remain backward-compatible while vNext outputs grow the
market_item, artifact, and trust surface needed by the desktop fulfillment
engine.
```

## Data Flow

```mermaid
flowchart LR
    A["workflow-packs/*/pack-manifest.json"] --> B["legacy + vNext builders"]
    C["client/catalog/items/*.json"] --> B
    D["release installers / archives / build metadata / source locks"] --> B
    B --> E["openclaw-store-catalog.json"]
    B --> F["store-items/*.json"]
    B --> G["openclaw-market-catalog.json"]
    B --> H["store-items-vnext/*.json"]
    B --> I["openclaw-market-artifact-index.json"]
    B --> J["openclaw-market-trust-snapshot.json"]
```

## Compatibility Rule

- legacy desktop consumers continue to read `openclaw-store-catalog.json`
- vNext desktop / fulfillment consumers must prefer the vNext output set
- both output families must be generated from the same pinned manifest,
  artifact, and audit inputs in the same release run

## Artifact Addressing Rule

Every vNext publish artifact must be addressable by:

```text
artifactId + sha256 + relativePath
```

## Trust Rule

The trust snapshot is the canonical publish-time summary for:

- trust lane
- release channel
- audit status
- audit summary
- source pinning status
- release-blocking state
