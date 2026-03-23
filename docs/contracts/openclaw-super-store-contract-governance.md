# OpenClaw Super Store Contract Governance

Date: 2026-03-23
Status: Frozen for vNext baseline
Scope: `openclaw-setup-cn` + `aip`

## Purpose

This document freezes the governance rules for the cross-repo contracts used by
the OpenClaw super store program.

The goal is to stop schema drift before implementation expands beyond the
current workflow-pack store.

## Source Of Truth

```ascii
Contract ownership
├─ Machine-readable schema source of truth
│  └─ openclaw-setup-cn/docs/contracts/*.schema.json
├─ Runtime TypeScript mirror
│  └─ aip/packages/shared/src/openclaw-store-contracts.ts
└─ Product implementation
   ├─ openclaw-setup-cn build / catalog scripts
   └─ aip api / desktop / tauri code
```

Rules:

- `openclaw-setup-cn` owns the canonical machine-readable contract definitions.
- `aip` mirrors those contracts for compile-time and runtime consumption.
- Product code may depend on the contracts, but may not invent new top-level
  contract names or enum tokens ad hoc.

## Canonical Contract Set

```ascii
vNext contract set
├─ market-item
├─ fulfillment-strategy
├─ trust-lane-policy
├─ wallet-ledger
├─ entitlement
├─ fulfillment-job
└─ install-registry-vnext
```

## Naming Rules

```ascii
Naming policy
├─ file names: lower-kebab-case
├─ JSON property names: camelCase
├─ enum values: lower-kebab-case
├─ TypeScript type names: PascalCase
└─ human labels: free-form presentation strings
```

Non-negotiable rule:

```text
The same semantic enum value must never appear in one repo as kebab-case and in
the other repo as snake_case, title case, or a translated string.
```

## Versioning Rule

Every schema file must expose a top-level `schemaVersion` integer.

Versioning policy:

- documentation-only clarifications do not change `schemaVersion`
- additive optional fields may stay within the same `schemaVersion`
- relaxing validation may stay within the same `schemaVersion`
- new required fields require a new `schemaVersion`
- renamed, removed, or retyped fields require a new `schemaVersion`
- enum additions are treated as breaking unless every known consumer has already
  shipped tolerant handling for unknown values
- changing the meaning of an existing enum token is always breaking

## Compatibility Rule

```ascii
Allowed without version bump
├─ add optional field
├─ add optional object section
└─ relax validation in a backward-compatible way

Breaking change
├─ add required field
├─ remove field
├─ rename field
├─ tighten validation
├─ add enum token without tolerant consumers
├─ change enum semantics
└─ change canonical state ids
```

## Review Gate

Before a contract change may ship:

1. update the machine-readable schema in `openclaw-setup-cn`
2. update the mirror TypeScript contract in `aip`
3. update the consuming code in both repos if needed
4. record the change in the relevant stage plan or implementation note

## Frozen Cross-Repo Vocabulary

```ascii
Frozen vocabulary families
├─ item kinds
├─ fulfillment strategies
├─ trust lanes
├─ delivery modes
├─ wallet ledger directions / reasons / statuses
├─ entitlement kinds / statuses
├─ fulfillment job actions / states
└─ local install registry lanes / readiness ids / remote secret states
```

## Source Ownership By Domain

```ascii
Ownership map
├─ openclaw-setup-cn
│  ├─ official item publishing contract
│  ├─ artifact metadata contract
│  ├─ trust metadata contract
│  └─ local install registry schema
└─ aip
   ├─ wallet / purchase runtime mirror
   ├─ fulfillment runtime mirror
   └─ desktop / api consumption
```

## Breaking-Change Rule

```text
No later stage may introduce a new top-level contract name, state family, or
enum family unless Stage 0 is explicitly amended first.
```
