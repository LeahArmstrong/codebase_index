---
name: validate-in-host
description: Spawns a host-app-validator agent to run extraction validation in test_app or compose-dev/admin
argument-hint: "[test_app|admin] [what-to-validate]"
allowed-tools: Task, Read
---
# Validate in Host App

Spawn a `host-app-validator` agent to validate extraction in a host Rails environment.

## Usage

`/validate-in-host [environment] [description]`

- `$ARGUMENTS[0]` = environment: `test_app` (default) or `admin`
- Remaining arguments = what to validate (e.g., "full pipeline", "model_extractor output", "new event_extractor")

If no arguments, default to `test_app` with full integration spec run.

## Workflow

1. **Parse arguments** — Determine environment and validation scope.
2. **Read the rules** — Read `.claude/rules/integration-testing.md` to get environment-specific commands.
3. **Build the plan** — Construct a validation plan based on the scope:

### For `test_app`

| Scope | Commands |
|---|---|
| Full pipeline | `cd ~/work/test_app && bundle exec rspec spec/integration/ --format json --out tmp/test_results.json` |
| Specific extractor | `cd ~/work/test_app && bundle exec rake codebase_index:extract` then inspect `tmp/codebase_index/` output |
| Stats/health | `cd ~/work/test_app && bundle exec rake codebase_index:stats && bundle exec rake codebase_index:validate` |

### For `admin`

| Scope | Commands |
|---|---|
| Full extraction | `cd ~/work/compose-dev && docker compose exec admin bin/rails codebase_index:extract` |
| Stats/health | `cd ~/work/compose-dev && docker compose exec admin bin/rails codebase_index:stats` |
| Console check | `cd ~/work/compose-dev && docker compose exec admin bin/rails codebase_index:validate` |

4. **Spawn the agent** — Use the Task tool with:
   - `subagent_type: "host-app-validator"`
   - A prompt containing: the environment, commands to run, what to look for, and what to report back

5. **Report results** — Summarize the agent's findings to the user.

## Example Prompts to Agent

### Full test_app validation
```
Validate CodebaseIndex extraction in test_app:
1. cd ~/work/test_app
2. Run: bundle exec rspec spec/integration/ --format progress --format json --out tmp/test_results.json
3. If any failures, read tmp/test_results.json and report the failing specs with error messages.
4. Run: bundle exec rake codebase_index:stats
5. Report: spec pass/fail counts and extraction stats.
```

### Specific extractor in admin
```
Validate the EventExtractor in compose-dev/admin:
1. cd ~/work/compose-dev
2. Verify container: docker compose ps
3. Run: docker compose exec admin bin/rails codebase_index:extract
4. Check output for event-type units: docker compose exec admin bin/rails runner "puts CodebaseIndex::Extractor.new.extract_all.select { |u| u.unit_type == 'event' }.count"
5. Report: count of event units, any errors during extraction.
```
