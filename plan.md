# Implementation Plan: Rake Task Extraction & Temporal Index

Two features, implemented in sequence. The rake task extractor is self-contained and follows existing patterns. The temporal index is a new subsystem that touches storage, extraction, and MCP layers.

---

## Feature 1: RakeTaskExtractor (Estimated: 6 files new, 3 files modified)

### Step 1: Write failing specs first (TDD)

**Create `spec/extractors/rake_task_extractor_spec.rb`**

Test cases to cover:
- `#initialize` handles missing `lib/tasks/` directory gracefully (returns `[]`)
- `#extract_all` discovers `.rake` files in `lib/tasks/`
- `#extract_all` returns one `ExtractedUnit` per task definition (multiple tasks per file)
- `#extract_rake_file(path)` extracts a simple namespaced task (`namespace :foo do task :bar`)
- `#extract_rake_file(path)` extracts top-level tasks (no namespace) with identifier = task name
- `#extract_rake_file(path)` extracts nested namespaces (`namespace :a do namespace :b do task :c` → `"a:b:c"`)
- `#extract_rake_file(path)` captures `desc` description into `metadata[:description]`
- `#extract_rake_file(path)` captures task dependencies (`:environment`, other tasks)
- `#extract_rake_file(path)` captures task arguments (`task :name, [:arg1, :arg2]`)
- `#extract_rake_file(path)` detects model/service/job dependencies via source scanning
- `#extract_rake_file(path)` detects cross-task invocations (`Rake::Task["foo:bar"].invoke`)
- `#extract_rake_file(path)` sets `unit.type` to `:rake_task`
- `#extract_rake_file(path)` sets `unit.file_path` to the `.rake` file path
- `#extract_rake_file(path)` sets `unit.namespace` to the task's namespace
- `#extract_rake_file(path)` handles read errors gracefully (returns `[]`)
- `#extract_rake_file(path)` returns `[]` for non-rake files
- `#extract_rake_file(path)` excludes the gem's own rake tasks (filter `codebase_index` namespace)
- Units have correct `source_code` with annotation header
- Units have `dependencies` array with `:via` key on each entry
- `to_h` / `json_serialize` round-trips correctly

### Step 2: Implement the extractor

**Create `lib/codebase_index/extractors/rake_task_extractor.rb`**

Design decisions:
- **File-based pattern** (like `I18nExtractor`, `MigrationExtractor`) — scan `lib/tasks/**/*.rake`
- **Static parsing via regex** — never eval or load rake files. Parse `namespace`, `task`, `desc` DSL calls
- **One unit per task**, not one per file — matches `ScheduledJobExtractor` pattern (multiple units per file)
- **Identifier format**: `"namespace:task_name"` (e.g., `"db:migrate"`, `"cleanup:stale_orders"`), top-level tasks use just the name
- **Include `SharedDependencyScanner`** for model/service/job/mailer dependency detection

Key implementation details:

```ruby
class RakeTaskExtractor
  RAKE_DIRECTORIES = %w[lib/tasks].freeze

  def initialize
    @directories = RAKE_DIRECTORIES.map { |d| Rails.root.join(d) }.select(&:directory?)
  end

  def extract_all
    @directories.flat_map do |dir|
      Dir[dir.join('**/*.rake')].flat_map { |file| extract_rake_file(file) }
    end
  end

  def extract_rake_file(file_path)
    # 1. Read source
    # 2. Parse namespace/task/desc blocks via regex state machine
    # 3. For each task: build ExtractedUnit with metadata + dependencies
    # 4. Return Array<ExtractedUnit>
  end
end
```

Parsing strategy — track namespace stack with a simple state machine:
- `namespace :name do` → push onto namespace stack
- `end` at matching depth → pop from namespace stack
- `desc 'text'` → buffer for next task
- `task :name` / `task name: deps` → emit task with current namespace stack
- Extract the task block body as `source_code`

Metadata schema:
```ruby
{
  task_name: "migrate",           # Short name
  full_name: "db:migrate",       # Namespace-qualified
  description: "Run migrations",  # From desc
  task_namespace: "db",           # Namespace string
  task_dependencies: ["environment"],  # From => :environment
  arguments: [],                  # From [:arg1, :arg2]
  has_environment_dependency: true,
  source_lines: 15
}
```

### Step 3: Register the extractor

**Modify `lib/codebase_index/extractor.rb`** — 4 insertion points:

1. Add `require_relative 'extractors/rake_task_extractor'` (after line 35)
2. Add `rake_tasks: Extractors::RakeTaskExtractor` to `EXTRACTORS` hash (line ~101)
3. Add `rake_task: :rake_tasks` to `TYPE_TO_EXTRACTOR_KEY` hash (line ~136)
4. Add `rake_task: :extract_rake_file` to `FILE_BASED` hash (line ~156)

### Step 4: Wire into retrieval

**Modify `lib/codebase_index/retrieval/query_classifier.rb`**

Add to `TARGET_PATTERNS` hash (after `scheduled_job` pattern):
```ruby
rake_task: /\b(rake|task|lib.?tasks?|maintenance|batch.?script|data.?migration.?task)\b/i,
```

### Step 5: Run specs, iterate until green

```bash
bundle exec rake spec SPEC=spec/extractors/rake_task_extractor_spec.rb
bundle exec rubocop -a lib/codebase_index/extractors/rake_task_extractor.rb spec/extractors/rake_task_extractor_spec.rb
```

---

## Feature 2: Temporal Index / Snapshot System (Estimated: 8 files new, 4 files modified)

### Step 1: Write failing specs first (TDD)

**Create `spec/db/snapshot_migration_spec.rb`**

- Migration creates `codebase_snapshots` table with correct columns and indexes
- Migration creates `snapshot_units` table with correct columns and indexes
- Both migrations are idempotent (IF NOT EXISTS)

**Create `spec/temporal/snapshot_store_spec.rb`**

- `#capture(manifest, unit_hashes)` stores a snapshot record keyed by git SHA
- `#capture` stores per-unit records (identifier, type, source_hash) linked to snapshot
- `#capture` is idempotent — same git SHA overwrites cleanly
- `#capture` computes diff stats vs. previous snapshot (units added/modified/deleted)
- `#list(limit:, branch:)` returns snapshots sorted by `extracted_at` descending
- `#find(git_sha)` returns snapshot metadata
- `#diff(sha_a, sha_b)` returns `{added: [...], modified: [...], deleted: [...]}` per unit
- `#unit_history(identifier, limit:)` returns all versions of a unit across snapshots
- `#unit_history` includes `source_hash`, `extracted_at`, `git_sha` per entry
- Handles first-ever snapshot (no previous to diff against) gracefully
- Thread-safe (uses transactions)

### Step 2: Add database migrations

**Create `lib/codebase_index/db/migrations/004_create_snapshots.rb`**

```sql
CREATE TABLE IF NOT EXISTS codebase_snapshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  git_sha TEXT NOT NULL,
  git_branch TEXT,
  extracted_at TEXT NOT NULL,
  rails_version TEXT,
  ruby_version TEXT,
  total_units INTEGER NOT NULL DEFAULT 0,
  unit_counts TEXT,                    -- JSON: {"model": 5, ...}
  gemfile_lock_sha TEXT,
  schema_sha TEXT,
  units_added INTEGER DEFAULT 0,
  units_modified INTEGER DEFAULT 0,
  units_deleted INTEGER DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE(git_sha)
);
CREATE INDEX IF NOT EXISTS idx_snapshots_extracted_at ON codebase_snapshots(extracted_at);
CREATE INDEX IF NOT EXISTS idx_snapshots_branch ON codebase_snapshots(git_branch);
```

**Create `lib/codebase_index/db/migrations/005_create_snapshot_units.rb`**

```sql
CREATE TABLE IF NOT EXISTS codebase_snapshot_units (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id INTEGER NOT NULL,
  identifier TEXT NOT NULL,
  unit_type TEXT NOT NULL,
  source_hash TEXT,
  metadata_hash TEXT,                  -- SHA256 of JSON-serialized metadata
  dependencies_hash TEXT,              -- SHA256 of JSON-serialized dependencies
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  FOREIGN KEY (snapshot_id) REFERENCES codebase_snapshots(id),
  UNIQUE(snapshot_id, identifier)
);
CREATE INDEX IF NOT EXISTS idx_snapshot_units_identifier ON codebase_snapshot_units(identifier);
CREATE INDEX IF NOT EXISTS idx_snapshot_units_snapshot ON codebase_snapshot_units(snapshot_id);
```

Design note: We store **hashes** of source/metadata/dependencies per snapshot, not full copies. This keeps storage compact. Full source is in the current extraction output. For diffs, hash comparison tells us *what* changed; the current extraction output has the *current* state; and for historical state, the user can check out the git SHA.

### Step 3: Register migrations in Migrator

**Modify `lib/codebase_index/db/migrator.rb`**

Add requires and append to `MIGRATIONS` array:
```ruby
require_relative 'migrations/004_create_snapshots'
require_relative 'migrations/005_create_snapshot_units'

MIGRATIONS = [
  Migrations::CreateUnits,
  Migrations::CreateEdges,
  Migrations::CreateEmbeddings,
  Migrations::CreateSnapshots,          # NEW
  Migrations::CreateSnapshotUnits       # NEW
].freeze
```

### Step 4: Implement SnapshotStore

**Create `lib/codebase_index/temporal/snapshot_store.rb`**

```ruby
module CodebaseIndex
  module Temporal
    class SnapshotStore
      def initialize(connection:)
        @db = connection
      end

      # Capture a snapshot after extraction completes.
      # @param manifest [Hash] The manifest data (git_sha, extracted_at, counts, etc.)
      # @param unit_hashes [Array<Hash>] Per-unit: {identifier:, type:, source_hash:, metadata_hash:, dependencies_hash:}
      # @return [Hash] Snapshot record with diff stats
      def capture(manifest, unit_hashes)
        # 1. Find previous snapshot (most recent by extracted_at)
        # 2. INSERT snapshot record
        # 3. INSERT snapshot_units records (batch)
        # 4. Compute diff vs previous: added/modified/deleted counts
        # 5. UPDATE snapshot with diff stats
        # Return snapshot metadata
      end

      # List snapshots, optionally filtered by branch.
      # @param limit [Integer] Max results (default 20)
      # @param branch [String, nil] Filter by branch name
      # @return [Array<Hash>] Snapshot summaries
      def list(limit: 20, branch: nil)
      end

      # Find a specific snapshot by git SHA.
      # @param git_sha [String]
      # @return [Hash, nil]
      def find(git_sha)
      end

      # Compute diff between two snapshots.
      # @param sha_a [String] Before snapshot git SHA
      # @param sha_b [String] After snapshot git SHA
      # @return [Hash] {added: [...], modified: [...], deleted: [...]}
      def diff(sha_a, sha_b)
        # JOIN snapshot_units for both snapshots
        # Compare by identifier:
        #   - In B but not A → added
        #   - In both, source_hash differs → modified
        #   - In A but not B → deleted
      end

      # History of a single unit across snapshots.
      # @param identifier [String] Unit identifier
      # @param limit [Integer] Max snapshots to return
      # @return [Array<Hash>] {git_sha:, extracted_at:, source_hash:, changed: bool}
      def unit_history(identifier, limit: 20)
        # SELECT from snapshot_units JOIN snapshots
        # ORDER BY extracted_at DESC
        # Mark changed = true where source_hash differs from next newer snapshot
      end
    end
  end
end
```

### Step 5: Add configuration

**Modify `lib/codebase_index.rb`** (Configuration class):

Add to `attr_accessor`: `enable_snapshots`
Initialize in `#initialize`: `@enable_snapshots = false`

### Step 6: Wire into extraction pipeline

**Modify `lib/codebase_index/extractor.rb`** — after `write_manifest` in `extract_all`:

```ruby
# After write_manifest (line ~647):
capture_snapshot if CodebaseIndex.configuration.enable_snapshots
```

New private method:
```ruby
def capture_snapshot
  return unless defined?(CodebaseIndex::Temporal::SnapshotStore)

  manifest = JSON.parse(File.read(@output_dir.join('manifest.json')))

  # Build per-unit hash summaries from @results
  unit_hashes = @results.values.flatten.map do |unit|
    h = unit.to_h
    {
      identifier: unit.identifier,
      type: unit.type.to_s,
      source_hash: unit.source_hash,
      metadata_hash: Digest::SHA256.hexdigest(JSON.generate(h['metadata'] || {})),
      dependencies_hash: Digest::SHA256.hexdigest(JSON.generate(h['dependencies'] || []))
    }
  end

  store = build_snapshot_store
  store.capture(manifest, unit_hashes)
end
```

### Step 7: Add MCP tools for temporal queries

**Modify `lib/codebase_index/mcp/server.rb`** — add 4 new tools:

1. **`list_snapshots`** — Calls `SnapshotStore#list(limit:, branch:)`
   - Params: `limit` (integer, optional, default 20), `branch` (string, optional)
   - Returns: JSON array of snapshot summaries

2. **`snapshot_diff`** — Calls `SnapshotStore#diff(sha_a, sha_b)`
   - Params: `sha_a` (string, required), `sha_b` (string, required)
   - Returns: JSON with `added`, `modified`, `deleted` arrays

3. **`unit_history`** — Calls `SnapshotStore#unit_history(identifier, limit:)`
   - Params: `identifier` (string, required), `limit` (integer, optional, default 20)
   - Returns: JSON array of snapshot entries for that unit

4. **`snapshot_detail`** — Calls `SnapshotStore#find(git_sha)`
   - Params: `git_sha` (string, required)
   - Returns: Full snapshot metadata including unit counts and diff stats

These tools are only registered when a snapshot store is provided (nil-guarded, like operator/feedback tools).

Add `snapshot_store:` parameter to `Server.build()`.

### Step 8: Write MCP tool specs

**Create `spec/mcp/snapshot_tools_spec.rb`**

- `list_snapshots` returns formatted snapshot list
- `snapshot_diff` returns added/modified/deleted
- `unit_history` returns chronological versions
- `snapshot_detail` returns full metadata
- All tools return helpful message when snapshot store is nil (not configured)

### Step 9: Run full suite, lint, iterate

```bash
bundle exec rake spec
bundle exec rubocop -a
```

---

## File Summary

### New files (14 total):

| File | Feature | Purpose |
|------|---------|---------|
| `lib/codebase_index/extractors/rake_task_extractor.rb` | Rake | Extractor implementation |
| `spec/extractors/rake_task_extractor_spec.rb` | Rake | Extractor specs |
| `lib/codebase_index/db/migrations/004_create_snapshots.rb` | Temporal | Snapshots table migration |
| `lib/codebase_index/db/migrations/005_create_snapshot_units.rb` | Temporal | Snapshot units table migration |
| `lib/codebase_index/temporal/snapshot_store.rb` | Temporal | Core snapshot store |
| `spec/db/snapshot_migration_spec.rb` | Temporal | Migration specs |
| `spec/temporal/snapshot_store_spec.rb` | Temporal | Snapshot store specs |
| `spec/mcp/snapshot_tools_spec.rb` | Temporal | MCP tool specs |

### Modified files (4 total):

| File | Changes |
|------|---------|
| `lib/codebase_index/extractor.rb` | Register rake extractor (4 locations) + snapshot capture hook |
| `lib/codebase_index/retrieval/query_classifier.rb` | Add `:rake_task` to `TARGET_PATTERNS` |
| `lib/codebase_index/db/migrator.rb` | Register migrations 004 + 005 |
| `lib/codebase_index.rb` | Add `enable_snapshots` config flag |
| `lib/codebase_index/mcp/server.rb` | Add 4 snapshot MCP tools + `snapshot_store:` param |

---

## Implementation Order

1. **Rake extractor specs** → implementation → registration → retrieval wiring → green suite
2. **Temporal migration specs** → migrations → migrator registration → green suite
3. **Snapshot store specs** → implementation → green suite
4. **Configuration flag** → extraction pipeline hook → green suite
5. **MCP tool specs** → MCP tool implementation → green suite
6. **Full suite + rubocop** → commit

Each step is a commit checkpoint. Feature 1 (rake) can be committed independently before starting Feature 2 (temporal).

---

## Design Constraints Respected

- `frozen_string_literal: true` on every file
- YARD documentation on every public method
- `rescue StandardError`, never bare `rescue`
- No `eval`/`load` of rake files — static regex parsing only
- `Open3.capture2` for any shell commands (not backticks)
- MySQL + PostgreSQL compatible SQL (temporal tables use SQLite-compatible syntax matching existing migrations)
- Temporal snapshots store **hashes** not full copies — keeps storage proportional to unit count, not source size
- Snapshot store is opt-in (`enable_snapshots: false` default) — zero overhead when disabled
- MCP tools nil-guard against missing snapshot store — graceful degradation
- `ExtractedUnit` is the universal currency — rake extractor produces `ExtractedUnit` instances
- Dependencies include `:via` key on every entry
