
## Fleet roles

cctrl ships one reusable orchestration role as a generic skill (single source of
truth; see also [AGENTS.md](./AGENTS.md)):
- **[skills/cctrl-fleet-manager/SKILL.md](./skills/cctrl-fleet-manager/SKILL.md)** — orchestrate
  a fleet of concurrent cctrl sessions (monitor → decide → sequence; delegate all
  hands-on work; two-mode autonomy model; session-close gate).

`docs/cctrl-fleet-manager.md` is a thin pointer; `skills/README.md` covers the
symlink setup. The skill carries **no environment specifics** (cctrl is public);
concrete probe endpoints, service inventory, and SSH map live only in the operator's
private infra repo. A companion stack-watcher (sentinel) role is environment-specific
and kept private, not here.

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Author a backlog-ready spec/issue → invoke /spec
