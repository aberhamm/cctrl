# Documentation

Start with the task below, then follow the reference only as far as needed.
The [main README](../README.md) owns user-facing command and configuration
guidance. [AGENTS.md](../AGENTS.md) owns the agent operating contract; the
[role skills](../skills/README.md) own fleet doctrine. Findings record evidence
and limitations at their stated baselines; they do not override those contracts
or promise that a proposed capability is implemented.

## Choose a task

| I need to… | Start here | Go deeper when needed |
|---|---|---|
| Install or configure cctrl | [Install](../README.md#install), [Profiles](../README.md#profiles) | [Requirements and testing](../README.md#requirements-and-testing) |
| Launch, inspect, or restore sessions | [Sessions](../README.md#sessions) | [Task lifecycle and ownership](findings/codex-task-lifecycle-contract.md), [terminal receipt recovery](findings/terminal-receipt-recovery.md) |
| Send, receive, reply, or ACK peer mail | [Agent peer contract](../AGENTS.md#peer-messaging), [peer commands](../README.md#peers) | [MCP bridge](../README.md#peer-mcp-bridge), [app-owned Codex peers](../README.md#app-owned-codex-peers) |
| Understand or extend Claude/Codex messaging | [Native messaging overview](findings/native-agent-messaging-protocols.md) | [Current adapters and bridge gaps](findings/native-agent-messaging-protocols.md#existing-cctrl-behavior-and-bridge-gaps), then the [Claude](findings/native-agent-messaging-claude.md) or [Codex](findings/native-agent-messaging-codex.md) wire reference; [evidence](findings/native-agent-messaging-evidence.md) only to check or refresh a claim |
| Run or end a fleet session | [Role skills](../skills/README.md) | The selected role's `SKILL.md`; the files beside this index are compatibility pointers |
| Use a second tmux server | [User configuration](../README.md#a-second-tmux-server-tmuxserver) | [Routing and behavior reference](tmux-second-server.md) |
| Change or validate cctrl | [Extending](../README.md#extending), [testing](../README.md#requirements-and-testing) | Relevant findings below; [plans](plans/) record implementation work rather than command authority |

For agents: read the relevant contract first. Open protocol details only for
provider integration or diagnosis, and open extraction/evidence details only
when checking a claim or refreshing the baseline. Ordinary peer operation does
not require reading every provider protocol.

## Findings by question

| Question | Reference |
|---|---|
| Which native messaging protocol can a bridge use? | [Claude Code and Codex messaging protocols](findings/native-agent-messaging-protocols.md) |
| What proves ownership of a Codex task? | [Task lifecycle and ownership signal contract](findings/codex-task-lifecycle-contract.md) |
| How can a provisional terminal receipt be recovered? | [Terminal receipt recovery](findings/terminal-receipt-recovery.md) |
| Why must tests explicitly select a tmux socket? | [Untargeted tmux default-server behavior](findings/tmux-untargeted-default-server.md) |
| How do provider selection and bounded discovery work? | [Provider-neutral launch and discovery](findings/provider-neutral-incident.md) |
| What did the profile-settings experiment establish? | [Profile settings spike](findings/profile-settings-spike.md) |
| What motivated stronger peer identity binding? | [Session reuse and agent attribution investigation](findings/peer-identity-reuse-and-agent-mislabel.md) |

Read each finding's baseline and verification scope before applying it to a
different provider version. Historical defects and proposed fixes are evidence,
not a current feature inventory.

## Investigation and planning records

[Plans](plans/), [archived plans](plans/archive/),
[debug reports](debug-reports/), and [reviews](reviews/) retain work history.
Consult them for a specific investigation or decision after checking the current
README, contract, or skill. They are not the first stop for routine operation.
[Rate-limit research](max-plan-rate-limits-research.md) is also a research
snapshot, rather than a current provider limit guarantee.
