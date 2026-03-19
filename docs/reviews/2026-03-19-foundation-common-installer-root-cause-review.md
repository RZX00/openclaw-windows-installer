# Foundation Common Installer Root Cause Review

Date: 2026-03-19
Branch: `codex/release-v0.1.3`
Scope: Windows `foundation-common` one-click installer root-cause review only

## Verdict

The current failure reported by the user is not a primary install failure.

```text
archive build/layout      -> fixed enough for current package install
plugin install            -> succeeds
plugin enable             -> succeeds
config write              -> succeeds
installer reporting       -> fails
post-install verification -> still has a secondary blocker
release completeness      -> still incomplete
```

## Findings

### [P1] Installer treats successful OpenClaw stderr warnings as fatal errors

Files:
- `client/install-windows-workflow-pack.ps1`
- `C:\ProgramData\OpenClaw\bundles\latest-2026.3.13-x64\node_modules\openclaw\dist\auth-profiles-DRjqKE3G.js`

Evidence:
- `Invoke-Probe()` runs native commands with `2>&1` under `$ErrorActionPreference = "Stop"`.
- On Windows PowerShell 5.1, stderr records from native commands become `ErrorRecord` objects.
- This aborts execution before `$LASTEXITCODE` is read.
- OpenClaw emits `Config overwrite: ...` as `logger.warn(...)` after a successful config write.

Relevant code:
- `client/install-windows-workflow-pack.ps1:515`
- `client/install-windows-workflow-pack.ps1:529`
- `client/install-windows-workflow-pack.ps1:536`
- `auth-profiles-DRjqKE3G.js:14079`
- `auth-profiles-DRjqKE3G.js:14085`
- `auth-profiles-DRjqKE3G.js:14154`

Impact:
- The installer reports failure even when the plugin is already installed and enabled.
- Final install-state writeback and readiness reporting do not run.
- User sees `Error: Config overwrite...` and reasonably concludes installation failed.

Why this is root cause:
- `openclaw.json` shows `foundation-common` in `plugins.allow`, `plugins.entries`, and `plugins.installs`.
- `config-audit.jsonl` records successful `rename` writes for both `plugins install` and `plugins enable`.

### [P1] `agent-reach` validation is not Windows-console safe under the current wrapper

Files:
- `client/install-windows-workflow-pack.ps1`
- `C:\ProgramData\OpenClaw\bin\agent-reach.cmd`
- `C:\ProgramData\OpenClaw\workflow-packs\foundation-common\runtime\tools\python\Lib\site-packages\agent_reach\cli.py`

Evidence:
- The generated wrapper launches Python without forcing UTF-8 console output.
- `agent_reach.cli` help and doctor output contain emoji.
- In the current GBK console environment, `agent-reach --help` and `agent-reach doctor` raise `UnicodeEncodeError`.

Relevant code:
- `client/install-windows-workflow-pack.ps1:613`
- `client/install-windows-workflow-pack.ps1:668`
- `client/install-windows-workflow-pack.ps1:673`
- `agent_reach/cli.py:117`
- `agent_reach/cli.py:146`
- `agent_reach/cli.py:243`
- `agent_reach/cli.py:872`

Impact:
- Even after fixing the false failure above, post-install verification will still fail on this machine.
- This is a real verification blocker, not just a reporting issue.

### [P2] The shipped `foundation-common` artifact is not release-complete

Files:
- `client/workflow-packs/foundation-common/pack-manifest.json`
- `C:\ProgramData\OpenClaw\support\workflow-packs\foundation-common\workflow-pack-source-lock.json`
- `client/build-windows-workflow-pack.ps1`
- `client/install-windows-workflow-pack.ps1`

Evidence:
- `pack-manifest.json` still declares exact target skills including `proactive-agent` and `memory-setup`.
- The source lock in the shipped artifact marks both as `unresolved`.
- The artifact was built with `allowUnresolvedSkillSources = true`.
- The installer readiness logic correctly classifies unresolved required sources as not ready.

Relevant code:
- `client/build-windows-workflow-pack.ps1:10`
- `client/build-windows-workflow-pack.ps1:705`
- `client/build-windows-workflow-pack.ps1:773`
- `client/install-windows-workflow-pack.ps1:1257`
- `client/install-windows-workflow-pack.ps1:1261`

Impact:
- The package can appear partially successful while still missing declared capabilities.
- This matches the user complaint that installation may look done while some skills/capabilities are absent.

## Confirmed Non-Findings

These were investigated and are not the primary cause of the current reported failure:

- Wrong OpenClaw root detection
  - Current install root, user state root, and plugin install path are aligned.
- Plugin archive root layout for the current build
  - The current builder emits `package/...` layout and the installed plugin is loadable.
- OpenClaw plugin install failure
  - The plugin is already installed and enabled in user config.

## Current Machine State

```text
foundation-common plugin        installed + enabled
core plugin files               present
runtime wrappers                present
OpenClaw-recognized ready skills
  - agent-browser
  - agent-reach
  - clawdefender
  - find-skills
  - security-auditor
  - self-improving
  - skill-vetter
filesystem-only present but not clearly recognized
  - clawFeed
missing from shipped artifact
  - proactive-agent
  - memory-setup
```

## Recommended Fix Order

```text
1. Fix native-command invocation semantics in installer
2. Fix Windows-safe agent-reach verification path
3. Enforce release gating on unresolved required skills
4. Add explicit path confirmation + readiness summary UX
```

## Review Summary

The current implementation has already solved a secondary archive-layout problem, but the user-visible failure now comes from a deeper contract mismatch:

- OpenClaw uses stderr for successful warnings.
- The PowerShell installer currently treats stderr as fatal.
- The runtime verification path uses a console-unsafe `agent-reach` invocation.
- The shipped artifact is still a development-validation build, not a complete release build.
