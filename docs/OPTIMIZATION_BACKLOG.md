# CodebaseIndex Optimization & Best Practices Review

## Context

CodebaseIndex is a runtime-aware Rails codebase extraction system (~2,700 lines across 7 extractors). The extraction layer is complete and well-designed. This review identifies **23 concrete improvements** across performance, security, correctness, and best practices — prioritized by impact.

---

## Critical: Performance

### 1. Git Data Extraction — N+1 Shell Commands
**Files:** `lib/codebase_index/extractor.rb:191-247`

Currently spawns **6-7 shell processes per unit file** (`git log`, `git rev-list`, `git shortlog`). For a codebase with 200 units, that's ~1,400 subprocess spawns — easily the biggest bottleneck.

**Fix:** Batch git operations into 1-2 calls:
- Single `git log --all --name-only --format=...` to gather per-file stats
- Parse the output in Ruby instead of per-file subprocess calls
- Also eliminates the duplicate `git rev-list --count HEAD` call (appears in both `extract_git_data` and `calculate_change_frequency`)

### 2. Repeated File Reads Within Each Extractor
**Files:** All 7 extractors

Each extractor reads the same file 3-5 times during a single extraction:
- `model_extractor.rb`: `source_file_for` → `build_composite_source` → `extract_scopes` → `extract_dependencies` → `count_loc` (each calls `File.read`)
- `controller_extractor.rb`: `build_composite_source` → `extract_respond_formats` → `extract_permitted_params` → `extract_dependencies` → `extract_action_source` per action

**Fix:** Read file once, pass `source` string through all methods. Several extractors (service, job) already partially do this — apply consistently.

### 3. O(n^2) Model Name Scanning in Dependency Extraction
**Files:** `model_extractor.rb:393-400`, `controller_extractor.rb:279-284`, `service_extractor.rb:280-287`, `job_extractor.rb:343-350`, `mailer_extractor.rb:231-238`, `phlex_extractor.rb:212-222`

Every extractor iterates **all** `ActiveRecord::Base.descendants` for **every** unit to find model name references. With 100 models and 150 total units, that's 15,000 regex matches.

**Fix:**
- Precompute model names list once (a frozen Set or Array)
- Build a single compiled regex: `/\b(?:User|Order|Product|...)\b/`
- Share across all extractors via dependency injection or module-level cache

### 4. O(n) Linear `find_unit` in Dependency Resolution
**File:** `lib/codebase_index/extractor.rb:164-166`

`resolve_dependents` calls `find_unit` (linear scan) for every dependency of every unit.

**Fix:** Build a `{ identifier => unit }` hash before the loop. One-liner change, major improvement for large codebases.

---

## Critical: Security

### 5. Shell Injection in Git Commands
**File:** `lib/codebase_index/extractor.rb:195-197, 214, 224, 235-238`

File paths are string-interpolated into backtick shell commands:
```ruby
`git log -1 --format=%cI -- "#{relative_path}" 2>/dev/null`
```

A file path containing `"$(rm -rf /)` or backticks would execute arbitrary commands.

**Fix:** Use `Open3.capture2("git", "log", "-1", ...)` with argument arrays. No shell interpretation, no injection risk.

---

## Critical: Missing Fundamentals

### 6. No Test Suite
**Status:** rspec listed in gemspec but zero spec files exist

For a gem doing runtime introspection and structured data extraction, tests are essential. Priority test areas:
- `ExtractedUnit` (serialization, chunking, token estimation)
- `DependencyGraph` (registration, BFS traversal, serialization round-trip)
- Individual extractors with fixture classes
- Integration test for full extraction pipeline

---

## High: Correctness Bugs

### 7. DependencyGraph Key Mismatch After JSON Round-Trip
**File:** `lib/codebase_index/dependency_graph.rb:174-181`

`@type_index` uses symbol keys (`:model`) during extraction, but `from_h` loads string keys from JSON. After saving and reloading, `units_of_type(:model)` returns nothing because keys are `"model"`.

**Fix:** Symbolize keys in `from_h`, or use `with_indifferent_access`.

### 8. Incremental Extraction Doesn't Update Index Files
**File:** `lib/codebase_index/extractor.rb:107-128`

`extract_changed` re-writes individual unit JSON files and the dependency graph, but skips `_index.json` files and `SUMMARY.md`. Downstream consumers relying on the index get stale data.

**Fix:** Regenerate affected type `_index.json` files after incremental extraction.

### 9. Inconsistent `:via` Key in Dependencies
Model extractor includes `:via` (`:association`, `:code_reference`), but controller, service, job, and mailer extractors omit it. This inconsistency makes relationship types ambiguous for downstream consumers.

**Fix:** Add `:via` consistently across all extractors.

---

## High: Best Practices

### 10. Bare `rescue` Blocks (17+ instances)
**Files:** `model_extractor.rb:70,108,116,196,219,231,246,533`, `controller_extractor.rb:106`, `mailer_extractor.rb:72,87,144,166,184`, `phlex_extractor.rb:98,187`, `job_extractor.rb:153`

Bare `rescue` catches `Exception` (including `SystemExit`, `SignalException`, `NoMemoryError`). This can mask critical failures and prevent clean shutdowns.

**Fix:** Use `rescue StandardError => e` or specific exception classes everywhere.

### 11. Repeated `eager_load!` Calls
**Files:** `model_extractor.rb:29`, `controller_extractor.rb:28`, `mailer_extractor.rb:26`, `phlex_extractor.rb:39`, `job_extractor.rb:52`

Called 5 times when the orchestrator runs all extractors sequentially. Redundant after the first call but adds startup overhead.

**Fix:** Call `Rails.application.eager_load!` once in the Extractor orchestrator, before running individual extractors. Add a guard in each extractor for standalone use.

---

## Medium: Code Quality

### 12. Fragile Method Boundary Detection
**Files:** `controller_extractor.rb:370-412`, `mailer_extractor.rb:283-319`

Uses indentation heuristics to find method `end`. Fails for:
- Multi-line method signatures
- `rescue`/`ensure` blocks (same indent as `def`)
- Heredocs containing `end` at method indent level

**Fix:** Use `method_source` gem (already available via `pry`) or `RubyVM::AbstractSyntaxTree.of(method)` for robust method boundary detection.

### 13. Fragile Scope Extraction Regex
**File:** `model_extractor.rb:346`

```ruby
source.scan(/scope\s+:(\w+)(?:,\s*->.*?(?:do|{).*?(?:end|})|,\s*->.*$)/m)
```

Breaks on multi-line lambda bodies, nested blocks, scopes with comments inside, and `Proc.new` syntax.

**Fix:** Use `model.defined_scopes` (if available in target Rails versions) or parse with AST.

### 14. Concern Detection Heuristic
**File:** `model_extractor.rb:176-197`

`mod.name.include?("Concerns")` matches any module with "Concerns" in its name, including third-party gems. `defined_in_app?` iterates all instance methods checking source locations (expensive).

**Fix:** Check module source location first (cheaper), then fall back to method-level checks.

### 15. Redundant `extract_public_api`/`extract_dsl_methods` Calls
**File:** `lib/codebase_index/extractors/rails_source_extractor.rb:406-427`

`rate_importance` calls `extract_public_api(source)` and `extract_dsl_methods(source)` even though the same data was just computed for `metadata`.

**Fix:** Pass the already-extracted metadata to `rate_importance`.

### 16. `JSON.pretty_generate` for All Output
**File:** `lib/codebase_index/extractor.rb:261-288`

Pretty-printed JSON adds ~30-40% size overhead from whitespace. For large codebases with hundreds of units, this adds up.

**Fix:** Default to `JSON.generate`, add a config option for pretty output (useful for debugging).

---

## Low: Minor Improvements

### 17. Cache `git_available?` Result
**File:** `lib/codebase_index/extractor.rb:187-189`

Spawns a subprocess every time it's called. Won't change during an extraction run.

**Fix:** Memoize: `@git_available ||= system(...)`.

### 18. Memoize `estimated_tokens`
**File:** `lib/codebase_index/extracted_unit.rb:66-69`

Recalculates on every call. Minor, but called multiple times during chunking decisions.

**Fix:** `@estimated_tokens ||= (source_code.length / 4.0).ceil`

### 19. Use Set for Job Deduplication
**File:** `lib/codebase_index/extractors/job_extractor.rb:55`

`units.any? { |u| u.identifier == job_class.name }` is O(n) per check. Use a Set of identifiers for O(1).

### 20. Configuration Validation
**File:** `lib/codebase_index.rb:35-58`

No validation on `max_context_tokens`, `similarity_threshold`, `output_dir`, etc.

**Fix:** Add basic validation in setters (positive integers, valid ranges, writable paths).

### 21. Token Estimation Accuracy
**File:** `lib/codebase_index/extracted_unit.rb:66-69`

`(length / 4.0).ceil` is a rough heuristic. Ruby code tokenizes differently than natural language.

**Fix:** Consider `tiktoken_ruby` gem for accurate token counting, with the 4-char heuristic as fallback.

### 22. No Concurrent Extraction
**File:** `lib/codebase_index/extractor.rb:62-76`

Extractors run sequentially but are independent.

**Fix:** Use `Concurrent::Promises` or `Thread.new` with `Queue` for parallel extraction. Guard with a config flag.

### 23. Missing Mailer/Job Types in `re_extract_unit`
**File:** `lib/codebase_index/extractor.rb:417-429`

The `case` statement for re-extraction only handles `:model`, `:controller`, `:service`, `:component`. Missing `:job` and `:mailer` types means incremental extraction silently skips these.

**Fix:** Add `:job` and `:mailer` cases.

---

## Recommended Implementation Order

**Batch 1 — High-impact, low-risk:**
1. Fix bare `rescue` blocks (#10)
2. Fix `find_unit` O(n) scan (#4)
3. Fix DependencyGraph key mismatch (#7)
4. Fix missing types in `re_extract_unit` (#23)
5. Fix incremental index file updates (#8)

**Batch 2 — Performance wins:**
6. Eliminate repeated file reads (#2)
7. Precompute model names for dependency scanning (#3)
8. Move `eager_load!` to orchestrator (#11)
9. Cache `git_available?` (#17)

**Batch 3 — Security + git performance:**
10. Fix shell injection in git commands (#5)
11. Batch git data extraction (#1)

**Batch 4 — Code quality:**
12. Add consistent `:via` key (#9)
13. Reduce `JSON.pretty_generate` overhead (#16)
14. Fix redundant analysis calls (#15)

**Deferred (needs more design):**
- Test suite (#6) — substantial effort, should be its own initiative
- Method boundary detection (#12) — needs gem dependency decision
- Concurrent extraction (#22) — needs thread-safety audit
- Token estimation (#21) — needs benchmarking

---

## Verification

After each batch:
1. Run `rake codebase_index:extract` on a real Rails app
2. Run `rake codebase_index:validate` to verify output integrity
3. Compare output JSON files before/after (should be identical except for timing fields)
4. Run `rake codebase_index:incremental` with a known changed file
5. Verify `_index.json` and `SUMMARY.md` are consistent with unit files
