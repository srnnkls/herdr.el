# Claude integration parity ledger

Committed protocol evidence lives under `testdata/claude/`:

- `client-originated.json` records observed and probed Claude WebSocket messages.
- `compatibility-probed.json` records discovery and transport behavior.
- `herdr-decided.json` records Herdr-owned protocol responses, tools, errors, and cleanup semantics.

| Workflow | Verification | State |
| --- | --- | --- |
| harness registration | ERT: `herdr-claude-has-one-built-in-phase-aware-harness-adapter` | covered |
| stable session identity | ERT: `herdr-claude-keeps-one-session-state-from-prepare-through-attach` | covered |
| same terminal label on distinct servers | ERT: `herdr-agent-adoption-separates-same-label-terminal-on-explicit-servers` | covered |
| start, continue, resume | ERT: `herdr-agent-native-start-continue-and-resume-use-harness-arguments` | covered |
| adopt without duplicate launch | ERT: `herdr-agent-adoption-reuses-three-kinds-and-cleans-a-failed-attachment` | covered |
| detach without stopping Herdr | ERT: `herdr-agent-detach-and-attachment-death-keep-herdr-open-and-retry-cleanup` | covered |
| discovery lockfile and environment | ERT: `herdr-claude-protocol-prepare-publishes-discovery-and-environment` | covered |
| owned-artifact cleanup | ERT: `herdr-claude-discovery-rollback-and-detach-remove-only-owned-artifacts` | covered |
| MCP initialize and capabilities | ERT: `herdr-claude-protocol-mcp-initialize-and-listing-contract` | covered |
| JSON-RPC errors | ERT: `herdr-claude-protocol-mcp-errors-are-json-rpc-specific` | covered |
| owner-local cancellation | ERT: `herdr-claude-client-supersession-cancels-only-the-owning-client` | covered |
| stale deferred completion | ERT: `herdr-claude-stale-deferred-completion-sends-nothing` | covered |
| reconnect and incomplete cleanup | ERT: `herdr-claude-protocol-reconnect-deadline-is-current-client-scoped` | covered |
| wire-to-editor normalization | ERT: `herdr-claude-normalizes-wire-input-before-editor-dispatch` | covered |
| project context targeting | ERT: `herdr-claude-protocol-context-broadcast-and-selection-target-project` | covered |
| at-mention targeting | ERT: `herdr-claude-protocol-at-mention-targets-session-or-composite` | covered |
| selection debounce and deduplication | ERT: `herdr-claude-editor-selection-debounces-and-deduplicates-snapshots` | covered |
| project path confinement | ERT: `herdr-claude-editor-confines-paths-to-the-project-root` | covered |
| open and close shared views | ERT: `herdr-claude-editor-open-and-close-preserves-shared-views` | covered |
| visited-buffer diagnostics | ERT: `herdr-claude-editor-diagnostics-use-only-visited-project-buffers` | covered |
| diagnostic normalization | ERT: `herdr-claude-editor-normalizes-flymake-plain-and-flycheck-diagnostics` | covered |
| editable diff accept and reject | ERT: `herdr-claude-editor-deferred-diffs-accept-edits-and-reject-distinctly` | covered |
| diff rollback and cleanup | ERT: `herdr-claude-editor-rolls-back-a-failed-diff-start` | covered |
| owner-local editor cleanup | ERT: `herdr-claude-editor-cancel-is-owner-local` | covered |
| opt-in Elisp execution | ERT: `herdr-claude-editor-execute-requires-explicit-opt-in` | covered |
| canonical transient routing | ERT: `herdr-transient-routes-workflows-without-spawning-processes` | covered |
| generic integration status | ERT: `herdr-transient-status-formatting-is-agent-specific` | covered |
| lazy transient loading | ERT: `herdr-agent-public-modules-load-canonical-transient-lazily` | covered |
| opt-in protocol logging | ERT: `herdr-claude-raw-logging-keeps-context-and-cleans-up` | covered |
| platform matrix | `.github/workflows/test.yml` | configured |

The unused Streamable HTTP MCP listener and its xref, Imenu, project, and tree-sitter catalog are outside the Claude IDE contract and have been removed. Claude compatibility remains isolated in the loopback WebSocket protocol boundary.

The deterministic suite covers lifecycle, wire behavior, resource ownership, transport security, editor operations, and lazy UI loading. `herdr-live-server-answers-ping` remains an explicit live-server check. CI covers Ubuntu, macOS, and Windows on Emacs 29.1 and 30.1, with a soft-failing Ubuntu snapshot job.
