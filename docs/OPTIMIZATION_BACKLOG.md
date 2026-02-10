# CodebaseIndex Optimization & Best Practices Review

## Context

CodebaseIndex is a runtime-aware Rails codebase extraction system (~2,700 lines across 7 extractors). The extraction layer is complete and well-designed. This review identifies **29 items** across performance, security, correctness, coverage, and best practices — prioritized by impact. **Batches 1-4 fully resolved** (items #1-5, #7-11, #15-17) in commit `cab9061`. Item #6 is partially resolved (86 gem specs + 87 integration specs; extractor-level fixture specs still needed).

---

## Critical: Performance

### 1. ✅ Git Data Extraction — N+1 Shell Commands — RESOLVED
**Files:** `lib/codebase_index/extractor.rb:191-247`
**Resolution:** Replaced per-file subprocess spawns with `batch_git_data` — two git commands total (`git log --all --name-only` + parsing). Commit `cab9061`.

~~Currently spawns **6-7 shell processes per unit file** (`git log`, `git rev-list`, `git shortlog`). For a codebase with 200 units, that's ~1,400 subprocess spawns — easily the biggest bottleneck.~~

### 2. ✅ Repeated File Reads Within Each Extractor — RESOLVED
**Files:** All 7 extractors
**Resolution:** Each extractor now reads source once and passes the string through all methods. Commit `cab9061`.

~~Each extractor reads the same file 3-5 times during a single extraction.~~

### 3. ✅ O(n^2) Model Name Scanning in Dependency Extraction — RESOLVED
**Files:** All extractors
**Resolution:** `ModelNameCache` precomputes model names and builds a single compiled regex shared across all extractors. Commit `cab9061`.

~~Every extractor iterates all `ActiveRecord::Base.descendants` for every unit to find model name references.~~

### 4. ✅ O(n) Linear `find_unit` in Dependency Resolution — RESOLVED
**File:** `lib/codebase_index/extractor.rb`
**Resolution:** `resolve_dependents` now builds a `{ identifier => unit }` hash via `index_by` before the loop. Commit `cab9061`.

~~`resolve_dependents` calls `find_unit` (linear scan) for every dependency of every unit.~~

---

## Critical: Security

### 5. ✅ Shell Injection in Git Commands — RESOLVED
**File:** `lib/codebase_index/extractor.rb:195-197, 214, 224, 235-238`
**Resolution:** Backtick git commands replaced with `Open3.capture2` argument arrays. No shell interpretation, no injection risk.

~~File paths were string-interpolated into backtick shell commands. A file path containing `"$(rm -rf /)` or backticks would execute arbitrary commands.~~

---

## Critical: Missing Fundamentals

### 6. 🔶 Test Suite — PARTIALLY RESOLVED
**Status:** 86 unit specs in the gem (`spec/`) + 87 integration specs in the test app (`host-app/spec/`). Unit-level coverage for core value objects, graph analysis, ModelNameCache, and json_serialize. Integration coverage for full extraction pipeline, incremental extraction, `:via` assertions, `_index.json` regeneration, git metadata structure, and `pretty_json` config.

**Remaining:** Extractor-level specs against fixture Rails apps are still needed. Priority areas:
- Individual extractors with fixture classes (requires a booted Rails environment)
- Edge cases: empty files, namespaced classes, STI, concern inlining

---

## High: Correctness Bugs

### 7. ✅ DependencyGraph Key Mismatch After JSON Round-Trip — RESOLVED
**File:** `lib/codebase_index/dependency_graph.rb`
**Resolution:** `from_h` now uses `symbolize_node` and `transform_keys` to ensure symbol keys after JSON deserialization. `units_of_type(:model)` works correctly after round-trip.

~~`@type_index` used symbol keys (`:model`) during extraction, but `from_h` loaded string keys from JSON.~~

### 8. ✅ Incremental Extraction Doesn't Update Index Files — RESOLVED
**File:** `lib/codebase_index/extractor.rb`
**Resolution:** `extract_changed` now tracks `affected_types` and calls `regenerate_type_index` for each. Commit `cab9061`.

~~`extract_changed` re-writes individual unit JSON files and the dependency graph, but skips `_index.json` files.~~

### 9. ✅ Inconsistent `:via` Key in Dependencies — RESOLVED
**Resolution:** All extractors now include `:via` key (`:association`, `:code_reference`) consistently. Commit `cab9061`.

~~Model extractor includes `:via`, but controller, service, job, and mailer extractors omit it.~~

---

## High: Best Practices

### 10. ✅ Bare `rescue` Blocks — RESOLVED
**Files:** All extractors
**Resolution:** All bare `rescue` blocks changed to `rescue StandardError`. Critical exceptions (`SystemExit`, `SignalException`, `NoMemoryError`) now propagate correctly.

~~17+ instances of bare `rescue` across all extractors caught `Exception`, masking critical failures.~~

### 11. ✅ Repeated `eager_load!` Calls — RESOLVED
**Files:** `lib/codebase_index/extractor.rb` (orchestrator), all extractors
**Resolution:** `Rails.application.eager_load!` consolidated to the orchestrator. No longer called redundantly by each individual extractor.

~~Called 5 times when the orchestrator ran all extractors sequentially.~~

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

### 14. ✅ Concern Detection Heuristic — RESOLVED
**File:** `model_extractor.rb:176-197`
**Resolution:** Improved concern detection to check module source location first (cheaper), with method-level checks as fallback. Filters out third-party gem concerns more reliably.

~~`mod.name.include?("Concerns")` matches any module with "Concerns" in its name, including third-party gems. `defined_in_app?` iterates all instance methods checking source locations (expensive).~~

### 15. ✅ Redundant `extract_public_api`/`extract_dsl_methods` Calls — RESOLVED
**File:** `lib/codebase_index/extractors/rails_source_extractor.rb`
**Resolution:** `rate_importance` now receives pre-computed metadata instead of re-extracting. Commit `cab9061`.

~~`rate_importance` calls `extract_public_api(source)` and `extract_dsl_methods(source)` even though the same data was just computed.~~

### 16. ✅ `JSON.pretty_generate` for All Output — RESOLVED
**File:** `lib/codebase_index/extractor.rb`
**Resolution:** Added `config.pretty_json` (defaults to `true` for backward compat). `json_serialize` dispatches to `pretty_generate` or `generate` based on config. Commit `cab9061`.

~~Pretty-printed JSON adds ~30-40% size overhead from whitespace.~~

---

## Low: Minor Improvements

### 17. ✅ Cache `git_available?` Result — RESOLVED
**File:** `lib/codebase_index/extractor.rb`
**Resolution:** Memoized with `defined?(@git_available)` guard. Commit `cab9061`.

~~Spawns a subprocess every time it's called.~~

### 18. ✅ Memoize `estimated_tokens` — RESOLVED
**File:** `lib/codebase_index/extracted_unit.rb`
**Resolution:** Memoized with `@estimated_tokens ||=`. Safe because `source_code` is set once during extraction.

~~Recalculates on every call.~~

### 19. ✅ Use Set for Job Deduplication — RESOLVED
**File:** `lib/codebase_index/extractors/job_extractor.rb`
**Resolution:** Replaced O(n) `units.any?` with a `Set` of seen identifiers for O(1) lookup.

~~`units.any? { |u| u.identifier == job_class.name }` is O(n) per check.~~

### 20. ✅ Configuration Validation — RESOLVED
**File:** `lib/codebase_index.rb:35-58`
**Resolution:** Added `validate!` method with checks for positive integers, valid ranges, and writable paths. Called before extraction runs.

~~No validation on `max_context_tokens`, `similarity_threshold`, `output_dir`, etc.~~

### 21. Token Estimation Accuracy
**File:** `lib/codebase_index/extracted_unit.rb:66-69`

`(length / 4.0).ceil` is a rough heuristic. Ruby code tokenizes differently than natural language.

**Fix:** Consider `tiktoken_ruby` gem for accurate token counting, with the 4-char heuristic as fallback.

### 22. No Concurrent Extraction
**File:** `lib/codebase_index/extractor.rb:62-76`

Extractors run sequentially but are independent.

**Fix:** Use `Concurrent::Promises` or `Thread.new` with `Queue` for parallel extraction. Guard with a config flag.

### 23. ✅ Missing Mailer/Job Types in `re_extract_unit` — RESOLVED
**File:** `lib/codebase_index/extractor.rb`
**Resolution:** `re_extract_unit` now uses `TYPE_TO_EXTRACTOR_KEY` mapping and handles all types including `:job`, `:mailer`, and GraphQL types. Commit `cab9061`.

~~The `case` statement for re-extraction only handles `:model`, `:controller`, `:service`, `:component`.~~

---

## New: Extraction Coverage Gaps

### 24. ✅ No Serializer/Decorator Extractor — RESOLVED
**Resolution:** Added `SerializerExtractor` covering ActiveModelSerializers, Blueprinter, Alba, and Draper. Auto-detects loaded gems and extracts accordingly. Includes dependency tracking to underlying models.

~~No extractor exists for serializer or decorator patterns.~~

### 25. ✅ No ViewComponent Extractor — RESOLVED
**Resolution:** Added `ViewComponentExtractor` for `ViewComponent::Base` descendants. Extracts component slots, template paths, preview classes, and collection support. Registered alongside Phlex extractor.

~~Only Phlex view components are extracted.~~

---

## New: Documentation & Design Drift

### 26. ✅ Voyage Code 2 → Code 3 in Doc Examples — RESOLVED
**Resolution:** Updated all docs to lead with Voyage Code 3 (1024 dims, 32K context). Code 2 retained as legacy option where referenced. Cost figures updated across BACKEND_MATRIX.md, RETRIEVAL_ARCHITECTURE.md, and CONTEXT_AND_CHUNKING.md.

~~All embedding model references in docs still reference Voyage Code 2.~~

### 27. ✅ Scale Assumptions Outdated Throughout Docs — RESOLVED
**Resolution:** Updated prose references from "300" to "993"/"~1,000" across BACKEND_MATRIX.md and other docs. Cost projections recalculated for 1000-unit baseline. Tabular data retained at varying sizes (50-1000) for comparison.

~~Docs reference "300+ models" as the scale target.~~

---

## New: Retrieval Pipeline Gaps

### 28. ✅ RRF Should Replace Ad-Hoc Score Fusion — RESOLVED
**Resolution:** Replaced `merge_candidates` in RETRIEVAL_ARCHITECTURE.md with Reciprocal Rank Fusion (RRF) implementation: `score(d) = Σ 1/(k + rank_i(d))` with k=60. Eliminates need for cross-backend score normalization.

~~`HybridSearch` uses ad-hoc weighted score fusion.~~

### 29. ✅ Cross-Encoder Reranking Missing from Ranking Pipeline — RESOLVED
**Resolution:** Added cross-encoder reranking section to RETRIEVAL_ARCHITECTURE.md as an optional stage between initial ranking and context assembly. Defined `Reranker::Interface`, documented Cohere Rerank and Voyage Reranker as candidates, with configuration for enabling/disabling.

~~The retrieval pipeline has no reranking stage.~~

---

## Recommended Implementation Order

**Batch 1 — High-impact, low-risk:** ✅ ALL RESOLVED
1. ~~Fix bare `rescue` blocks (#10)~~ ✅
2. ~~Fix `find_unit` O(n) scan (#4)~~ ✅ `cab9061`
3. ~~Fix DependencyGraph key mismatch (#7)~~ ✅
4. Fix missing types in `re_extract_unit` (#23) ✅ `cab9061`
5. ~~Fix incremental index file updates (#8)~~ ✅ `cab9061`

**Batch 2 — Performance wins:** ✅ ALL RESOLVED
6. ~~Eliminate repeated file reads (#2)~~ ✅ `cab9061`
7. ~~Precompute model names for dependency scanning (#3)~~ ✅ `cab9061`
8. ~~Move `eager_load!` to orchestrator (#11)~~ ✅
9. ~~Cache `git_available?` (#17)~~ ✅ `cab9061`

**Batch 3 — Security + Git performance:** ✅ ALL RESOLVED
10. ~~Fix shell injection in git commands (#5)~~ ✅
11. ~~Batch git data extraction (#1)~~ ✅ `cab9061`

**Batch 4 — Code quality:** ✅ ALL RESOLVED
12. ~~Add consistent `:via` key (#9)~~ ✅ `cab9061`
13. ~~Reduce `JSON.pretty_generate` overhead (#16)~~ ✅ `cab9061`
14. ~~Fix redundant analysis calls (#15)~~ ✅ `cab9061`

**Batch 5 — Extraction coverage:** ✅ ALL RESOLVED
15. ~~Add serializer/decorator extractor (#24)~~ ✅
16. ~~Add ViewComponent extractor (#25)~~ ✅

**Batch 6 — Retrieval pipeline design:** ✅ ALL RESOLVED
17. ~~Replace ad-hoc score fusion with RRF (#28)~~ ✅
18. ~~Add cross-encoder reranking stage (#29)~~ ✅

**Batch 7 — Documentation & code quality:** ✅ ALL RESOLVED
19. ~~Update Voyage Code 2 → Code 3 references (#26)~~ ✅
20. ~~Update scale assumptions to 993-model baseline (#27)~~ ✅
21. ~~Improve concern detection (#14)~~ ✅
22. ~~Add configuration validation (#20)~~ ✅

**Deferred (needs more design):**
- Test suite (#6) — 86 gem + 87 integration specs; extractor-level fixture specs still needed
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
