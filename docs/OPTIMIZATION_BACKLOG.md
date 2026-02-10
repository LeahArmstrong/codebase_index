# CodebaseIndex Optimization & Best Practices Review

## Context

CodebaseIndex is a runtime-aware Rails codebase extraction system (~2,700 lines across 7 extractors). The extraction layer is complete and well-designed. This review identifies **29 items** across performance, security, correctness, coverage, and best practices — prioritized by impact. Items #5, #7, #10, #11 are resolved. Item #6 is partially resolved (49 specs exist, extractor-level specs still needed).

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

### 5. ✅ Shell Injection in Git Commands — RESOLVED
**File:** `lib/codebase_index/extractor.rb:195-197, 214, 224, 235-238`
**Resolution:** Backtick git commands replaced with `Open3.capture2` argument arrays. No shell interpretation, no injection risk.

~~File paths were string-interpolated into backtick shell commands. A file path containing `"$(rm -rf /)` or backticks would execute arbitrary commands.~~

---

## Critical: Missing Fundamentals

### 6. 🔶 Test Suite — PARTIALLY RESOLVED
**Status:** 49 specs exist across `spec/extracted_unit_spec.rb`, `spec/dependency_graph_spec.rb`, and `spec/graph_analyzer_spec.rb`. Unit-level coverage for core value objects and graph analysis is in place.

**Remaining:** Extractor-level specs against fixture Rails apps are still needed. Priority areas:
- Individual extractors with fixture classes (requires a booted Rails environment)
- Integration test for full extraction pipeline
- Edge cases: empty files, namespaced classes, STI, concern inlining

---

## High: Correctness Bugs

### 7. ✅ DependencyGraph Key Mismatch After JSON Round-Trip — RESOLVED
**File:** `lib/codebase_index/dependency_graph.rb`
**Resolution:** `from_h` now uses `symbolize_node` and `transform_keys` to ensure symbol keys after JSON deserialization. `units_of_type(:model)` works correctly after round-trip.

~~`@type_index` used symbol keys (`:model`) during extraction, but `from_h` loaded string keys from JSON.~~

### 8. Incremental Extraction Doesn't Update Index Files
**File:** `lib/codebase_index/extractor.rb:107-128`

`extract_changed` re-writes individual unit JSON files and the dependency graph, but skips `_index.json` files and `SUMMARY.md`. Downstream consumers relying on the index get stale data.

**Fix:** Regenerate affected type `_index.json` files after incremental extraction.

### 9. Inconsistent `:via` Key in Dependencies
Model extractor includes `:via` (`:association`, `:code_reference`), but controller, service, job, and mailer extractors omit it. This inconsistency makes relationship types ambiguous for downstream consumers.

**Fix:** Add `:via` consistently across all extractors.

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

## New: Extraction Coverage Gaps

### 24. No Serializer/Decorator Extractor
No extractor exists for serializer or decorator patterns. ActiveModelSerializers, Blueprinter, and Draper are widely used in Rails apps to shape API responses and presentation logic. These are first-class Rails concepts that the dependency graph should capture.

**Fix:** Add a `SerializerExtractor` covering ActiveModelSerializers (`ApplicationSerializer` descendants), Blueprinter (`Blueprinter::Base` descendants), and Draper (`Draper::Decorator` descendants). Detect which gems are loaded and extract accordingly.

### 25. No ViewComponent Extractor
Only Phlex view components are extracted. ViewComponent (`ViewComponent::Base`) is more widely adopted in the Rails ecosystem and should be supported alongside Phlex.

**Fix:** Add a `ViewComponentExtractor` or extend `PhlexExtractor` to also handle `ViewComponent::Base` descendants. Extract component slots, template paths, and preview classes.

---

## New: Documentation & Design Drift

### 26. Voyage Code 2 → Code 3 in Doc Examples
All embedding model references in docs still reference Voyage Code 2. Voyage Code 3 is the current model and should be used in examples, cost calculations, and backend comparisons.

**Fix:** Update all Voyage Code 2 references to Voyage Code 3 across `BACKEND_MATRIX.md`, `RETRIEVAL_ARCHITECTURE.md`, `CONTEXT_AND_CHUNKING.md`, and any other docs referencing embedding models. Verify cost figures are current.

### 27. Scale Assumptions Outdated Throughout Docs
Docs reference "300+ models" as the scale target, but real-world extraction shows 993 models in a production app. Sizing assumptions, cost projections, and performance targets should reflect actual observed scale.

**Fix:** Audit all docs for scale references and update to reflect 993-model baseline. Recalculate storage estimates, query latency targets, and cost projections accordingly.

---

## New: Retrieval Pipeline Gaps

### 28. RRF Should Replace Ad-Hoc Score Fusion
`HybridSearch` (as designed in `RETRIEVAL_ARCHITECTURE.md`) uses ad-hoc weighted score fusion to combine vector and keyword results. Reciprocal Rank Fusion (RRF) is a more robust, parameter-free alternative that doesn't require score normalization.

**Fix:** Replace the weighted fusion design with RRF: `score(d) = Σ 1/(k + rank_i(d))` where `k` is typically 60. This eliminates the need to normalize scores across different retrieval backends.

### 29. Cross-Encoder Reranking Missing from Ranking Pipeline
The retrieval pipeline has no reranking stage. After initial retrieval (vector + keyword), results go directly to context assembly. A cross-encoder reranker between retrieval and assembly would significantly improve precision, especially for code search where bi-encoder similarity is noisy.

**Fix:** Add a reranking stage to the retrieval pipeline design. Candidates: Cohere Rerank, Voyage Reranker, or a cross-encoder model. This should be optional and configurable, consistent with the backend-agnostic principle.

---

## Recommended Implementation Order

**Batch 1 — High-impact, low-risk (3 remaining):**
1. ~~Fix bare `rescue` blocks (#10)~~ ✅
2. Fix `find_unit` O(n) scan (#4)
3. ~~Fix DependencyGraph key mismatch (#7)~~ ✅
4. Fix missing types in `re_extract_unit` (#23)
5. Fix incremental index file updates (#8)

**Batch 2 — Performance wins (3 remaining):**
6. Eliminate repeated file reads (#2)
7. Precompute model names for dependency scanning (#3)
8. ~~Move `eager_load!` to orchestrator (#11)~~ ✅
9. Cache `git_available?` (#17)

**Batch 3 — ~~Security +~~ Git performance (1 remaining):**
10. ~~Fix shell injection in git commands (#5)~~ ✅
11. Batch git data extraction (#1)

**Batch 4 — Code quality:**
12. Add consistent `:via` key (#9)
13. Reduce `JSON.pretty_generate` overhead (#16)
14. Fix redundant analysis calls (#15)

**Batch 5 — Extraction coverage:**
15. Add serializer/decorator extractor (#24)
16. Add ViewComponent extractor (#25)

**Batch 6 — Retrieval pipeline design:**
17. Replace ad-hoc score fusion with RRF (#28)
18. Add cross-encoder reranking stage (#29)

**Batch 7 — Documentation updates:**
19. Update Voyage Code 2 → Code 3 references (#26)
20. Update scale assumptions to 993-model baseline (#27)

**Deferred (needs more design):**
- Test suite (#6) — partially resolved, extractor-level specs still needed
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
