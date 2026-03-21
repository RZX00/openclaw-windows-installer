# Launcher Support Self-Update Plan

## Goal

Make updated `OpenClaw-Start.exe`, `OpenClaw-Update.exe`, and `OpenClaw-Repair.exe` automatically refresh the installed `support` scripts before they invoke maintenance, so old installs immediately receive the startup-speed fixes.

## Root Cause Graph

```text
User runs new Start.exe
   |
   +-- launcher resolves install root = C:\ProgramData\OpenClaw
   |
   +-- launcher still invokes installed support\OpenClaw-Maintenance.ps1
          |
          +-- installed support scripts are from 2026-03-14
          |      |
          |      +-- still run 13+ serial --help capability probes
          |      +-- still fail to parse mixed plugin+JSON output
          |
          +-- install-state.json is from 2026-03-19 and lacks
                 capabilities + capabilitiesRuntimeVersion
```

```mermaid
flowchart TD
    A["New Start/Update/Repair.exe"] --> B["Old installed support scripts still selected"]
    B --> C["Cold-start capability help probes"]
    B --> D["Mixed plugin logs break JSON parse"]
    C --> E["~40s startup tax before real checks"]
    D --> F["Readiness misclassified and repeated probes"]
    E --> G["Perceived startup is still slow"]
    F --> G
```

## Solution

```text
New launcher package
   |
   +-- ship latest support/OpenClaw-Maintenance.ps1
   +-- ship latest support/install-windows-core.ps1
   |
   +-- before launching maintenance:
          |
          +-- compare adjacent support payload vs installed support payload
          +-- copy newer/different files into C:\ProgramData\OpenClaw\support
          +-- then resolve and invoke maintenance normally
```

```mermaid
flowchart TD
    A["Launcher starts as admin"] --> B["Find adjacent support payload"]
    B --> C{"Payload exists?"}
    C -->|No| D["Use installed support scripts"]
    C -->|Yes| E["Refresh installRoot/support scripts"]
    E --> F["Invoke refreshed maintenance script"]
    F --> G["Maintenance seeds capabilities + uses fast JSON path"]
```

## Acceptance Criteria

- New standalone launcher package updates old `ProgramData\\OpenClaw\\support` scripts automatically.
- First run from the refreshed launcher no longer depends on a separate hotfix step.
- Release artifacts include the `support` payload next to the three launchers.
- The delivery ZIPs include the `support` directory so extracted launchers are self-sufficient.
