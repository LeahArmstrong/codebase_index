# CodebaseIndex

A Rails codebase extraction and indexing system designed to provide accurate, version-specific context for AI-assisted development tooling.

## The Problem

LLMs working with Rails codebases face a fundamental accuracy gap. Training data contains documentation and examples from many Rails versions, but a production app runs on *one* version. When a developer asks "what options does `has_many` support?" or "what callbacks fire when a record is saved?", the answer depends on their exact Rails version — and generic LLM responses often get it wrong.

Beyond version accuracy, Rails conventions hide enormous amounts of implementation behind "magic." A model file might be 50 lines, but with concerns inlined, schema context, callbacks, validations, and association behavior, the *actual* surface area is 10x that. AI tools that only see the source file miss most of what matters.

CodebaseIndex solves this by:

- **Running inside Rails** to leverage runtime introspection (not just static parsing)
- **Inlining concerns** directly into model source so the full picture is visible
- **Prepending schema comments** with column types, indexes, and foreign keys
- **Mapping routes to controllers** so HTTP → action flow is explicit
- **Indexing the exact Rails/gem source** for the versions in `Gemfile.lock`
- **Tracking dependencies** bidirectionally so you can trace impact across the codebase
- **Enriching with git data** so you know what's actively changing vs. dormant

## Target Environment

Designed for Rails applications of any scale, with particular strength in large monoliths:

- Any database (MySQL, PostgreSQL, SQLite)
- Any background job system (Sidekiq, Solid Queue, GoodJob, inline)
- Any view layer (ERB, Phlex, ViewComponent)
- Docker or bare metal, CI or manual
- Continuous or one-shot indexing

See [docs/BACKEND_MATRIX.md](../../docs/BACKEND_MATRIX.md) for supported infrastructure combinations.

## Use Cases

**1. Coding & Debugging** — Primary context for AI coding assistants. Answer "how does our checkout flow work?" with the actual service, model callbacks, controller actions, and framework behavior for the running version.

**2. Performance Analysis** — Correlate code structure with runtime behavior. Identify models with high write volume and complex callback chains, find N+1-prone association patterns, surface hot code paths.

**3. Deeper Analytics** — Query frequency by scope, error rates by action, background job characteristics. Bridge the gap between code structure and operational data.

**4. Support & Marketing Tooling** — Domain-concept retrieval for non-developers. Map business terms to code paths, surface feature flags, document user-facing behavior.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CodebaseIndex                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐ │
│  │   Extraction    │───▶│     Storage     │◀───│    Retrieval    │ │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘ │
│          │                      │                      │           │
│          ▼                      ▼                      ▼           │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐ │
│  │   Extractors    │    │  JSON per unit  │    │ Query Classifier│ │
│  │  · Model        │    │  Vector Index   │    │ Context Assembly│ │
│  │  · Controller   │    │  Metadata Index │    │ Result Ranking  │ │
│  │  · Service      │    │  Dep Graph      │    │                 │ │
│  │  · Component    │    │                 │    │                 │ │
│  │  · Rails Source │    │                 │    │                 │ │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘ │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Extraction Pipeline

Extraction runs inside the Rails application (via rake task) to access runtime introspection — `ActiveRecord::Base.descendants`, `Rails.application.routes`, reflection APIs, etc. This is fundamentally more accurate than static parsing.

**Four phases:**

1. **Extract** — Each extractor produces `ExtractedUnit` objects with source, metadata, and dependencies
2. **Resolve dependents** — Build reverse dependency edges (who calls what)
3. **Enrich with git** — Last modified, contributors, change frequency, recent commits
4. **Write output** — JSON per unit, dependency graph, manifest, structural summary

### Extractors

| Extractor | What it captures |
|-----------|-----------------|
| **ModelExtractor** | Schema (columns, indexes, FKs), associations with options, validations, callbacks (all 13 types), scopes, enums, inlined concerns. Chunks large models into summary/associations/callbacks/validations. |
| **ControllerExtractor** | Route mapping (verb → path → action), filter chain resolution per action, response formats, permitted params. Creates per-action chunks with applicable filters and route context. |
| **ServiceExtractor** | Scans `app/services`, `app/interactors`, `app/operations`, `app/commands`, `app/use_cases`. Extracts entry points (call/perform/execute), dependency injection patterns, custom errors, return type inference. |
| **JobExtractor** | ActiveJob and Sidekiq workers from `app/jobs` and `app/workers`. Queue configuration, retry/concurrency options, perform arguments, callbacks. Critical for understanding async behavior. |
| **MailerExtractor** | ActionMailer classes with default settings, per-action templates, callbacks, helper usage. Creates per-action chunks with template associations. |
| **PhlexExtractor** | Component slots, initialize params, rendered sub-components, model dependencies, Stimulus controller references, route helpers. |
| **RailsSourceExtractor** | High-value Rails framework paths (associations, callbacks, validations, relations) and gem source (Devise, Pundit, Sidekiq, etc.) pinned to exact installed versions. Rates importance for retrieval ranking. |

### Key Design Decisions

**Concern inlining.** When extracting a model, included concerns are read from disk and embedded as formatted comments directly in the model's source. This means the full behavioral picture is in one unit — no separate lookups needed during retrieval.

**Route prepending.** Controller source gets a header block showing the HTTP routes that map to it, so the relationship between URLs and actions is immediately visible.

**Semantic chunking.** Large models are split into purpose-specific chunks (summary, associations, callbacks, validations) rather than arbitrary size-based splits. Controllers chunk per-action with the relevant filters and route attached.

**Dependency graph with BFS blast radius.** The graph tracks both forward dependencies (what this unit uses) and reverse dependencies (what uses this unit). Changed-file impact is computed via breadth-first traversal — if a concern changes, every model including it gets re-indexed.

## Context Assembly

When serving context to an LLM, token budget is allocated in layers:

```
Budget Allocation:
├── 10%  Structural overview (always included)
├── 50%  Primary relevant units
├── 25%  Supporting context (dependencies)
└── 15%  Framework reference (when needed)
```

Queries are classified to determine whether framework source context is needed. "What options does has_many support?" routes to Rails source; "how do we handle checkout?" routes to application code.

## Usage

### Full Extraction

```bash
bundle exec rake codebase_index:extract
```

### Incremental (CI)

```bash
# Auto-detects GitHub Actions / GitLab CI environment
bundle exec rake codebase_index:incremental
```

```yaml
# .github/workflows/index.yml
jobs:
  index:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2
      - name: Update index
        run: bundle exec rake codebase_index:incremental
        env:
          GITHUB_BASE_REF: ${{ github.base_ref }}
```

### Framework-Only (on dependency changes)

```bash
bundle exec rake codebase_index:extract_framework
```

### Other Tasks

```bash
rake codebase_index:validate  # Check index integrity
rake codebase_index:stats     # Show unit counts, sizes, graph stats
rake codebase_index:clean     # Remove index
```

### Ruby API

```ruby
# Full extraction
CodebaseIndex.extract!

# Incremental
CodebaseIndex.extract_changed!(["app/models/user.rb", "app/services/checkout.rb"])

# Configuration
CodebaseIndex.configure do |config|
  config.output_dir = Rails.root.join("tmp/codebase_index")
  config.max_context_tokens = 8000
  config.include_framework_sources = true
  config.add_gem "devise", paths: ["lib/devise/models"], priority: :high
end
```

## Output Structure

```
tmp/codebase_index/
├── manifest.json              # Extraction metadata, git SHA, checksums
├── dependency_graph.json      # Full graph with forward/reverse edges
├── SUMMARY.md                 # Human-readable structural overview
├── models/
│   ├── _index.json            # Quick lookup index
│   ├── User.json              # Full extracted unit
│   └── Order.json
├── controllers/
│   ├── _index.json
│   └── OrdersController.json
├── services/
│   ├── _index.json
│   └── CheckoutService.json
├── components/
│   └── ...
└── rails_source/
    └── ...
```

Each unit JSON contains: `identifier`, `type`, `file_path`, `source_code` (annotated), `metadata` (rich structured data), `dependencies`, `dependents`, `chunks` (if applicable), and `estimated_tokens`.

## File Inventory

```
lib/
├── codebase_index.rb                              # Entry point & configuration
├── codebase_index/
│   ├── extracted_unit.rb                           # Core data structure
│   ├── dependency_graph.rb                         # Graph with BFS traversal
│   ├── extractor.rb                                # Main orchestrator
│   └── extractors/
│       ├── model_extractor.rb                      # ActiveRecord models
│       ├── controller_extractor.rb                 # ActionController
│       ├── service_extractor.rb                    # Service objects
│       ├── job_extractor.rb                        # ActiveJob/Sidekiq workers
│       ├── mailer_extractor.rb                     # ActionMailer
│       ├── phlex_extractor.rb                      # Phlex/ViewComponent
│       └── rails_source_extractor.rb               # Framework & gems
└── tasks/
    └── codebase_index.rake                         # Rake interface
```

## What's Next

The extraction layer is complete. See [docs/](../../docs/) for the full planning and proposal:

- [PROPOSAL.md](../../docs/PROPOSAL.md) — System design, evaluation strategy, implementation roadmap
- [BACKEND_MATRIX.md](../../docs/BACKEND_MATRIX.md) — Infrastructure options and selection guidance
- [AGENTIC_STRATEGY.md](../../docs/AGENTIC_STRATEGY.md) — AI agent consumption patterns and MCP server design
- [RETRIEVAL_ARCHITECTURE.md](../../docs/RETRIEVAL_ARCHITECTURE.md) — Detailed retrieval layer technical design
