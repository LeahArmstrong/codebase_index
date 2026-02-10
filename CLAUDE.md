# CodebaseIndex

Ruby gem that extracts structured data from Rails applications for AI-assisted development. Uses runtime introspection (not static parsing) to produce version-accurate representations: inlined concerns, resolved callback chains, schema-aware associations, dependency graphs. The extraction layer is complete. Retrieval, embedding, and storage layers are in design — see `docs/` for planning.

## Commands

```bash
# Development
bundle install
bundle exec rake spec                            # Full test suite
bundle exec rake spec SPEC=spec/extractors/model_extractor_spec.rb  # Single file
bundle exec rubocop -a                            # Lint + autofix
bundle exec rubocop --auto-gen-config             # Update .rubocop_todo.yml

# In a host Rails app (extraction requires Rails boot)
bundle exec rake codebase_index:extract           # Full extraction
bundle exec rake codebase_index:incremental       # Changed files only
bundle exec rake codebase_index:extract_framework # Rails/gem sources
bundle exec rake codebase_index:validate          # Index integrity check
bundle exec rake codebase_index:stats             # Show extraction stats
bundle exec rake codebase_index:clean             # Remove index output
```

## Architecture

```
lib/
├── codebase_index.rb              # Module interface, Configuration class, entry point
├── codebase_index/
│   ├── extractor.rb               # Orchestrator — coordinates all extractors, builds graph
│   ├── extracted_unit.rb          # Value object — single code unit (model/controller/service/etc)
│   ├── dependency_graph.rb        # Directed graph of unit relationships
│   └── extractors/                # One extractor per Rails concept
│       ├── model_extractor.rb     # ActiveRecord models — inlines concerns, resolves schema
│       ├── controller_extractor.rb # Controllers — maps routes, resolves filter chains
│       ├── service_extractor.rb   # Service objects — scans conventional directories
│       ├── job_extractor.rb       # ActiveJob/Sidekiq workers
│       ├── mailer_extractor.rb    # ActionMailer classes
│       ├── phlex_extractor.rb     # Phlex view components
│       └── rails_source_extractor.rb # Framework source from installed gems
├── tasks/
│   └── codebase_index.rake        # Rake task definitions
docs/                              # Planning & design documents (see docs/README.md)
```

## Key Design Decisions

- **Runtime introspection over static parsing.** Extractors require a booted Rails environment. This is intentional — `ActiveRecord::Base.descendants`, `Rails.application.routes`, and reflection APIs give us data that no parser can.
- **Backend agnostic.** The gem must work equally well with MySQL or PostgreSQL, Qdrant or pgvector, Sidekiq or Solid Queue, OpenAI or Ollama. Never hardcode or default to a single backend. See `docs/BACKEND_MATRIX.md`.
- **ExtractedUnit is the universal currency.** Everything flows through `ExtractedUnit` — extractors produce them, the dependency graph connects them, the indexing pipeline consumes them. Don't bypass this abstraction.
- **Concerns get inlined.** When extracting a model, all `include`d concerns are resolved and their source is inlined into the unit's source_code. This is the key differentiator from file-level tools.
- **Dependency graph is bidirectional.** First pass: each extractor records forward dependencies. Second pass: the graph resolves reverse edges (dependents). Both directions matter for retrieval.

## Code Conventions

- `frozen_string_literal: true` on every file
- YARD documentation on every public method and class
- Extractors follow a consistent interface: `initialize`, `extract_all`, `extract_<type>_file(path)`
- All extractors return `Array<ExtractedUnit>`
- Use `Rails.root.join()` for paths, never string concatenation
- JSON output uses string keys, snake_case
- Token estimation: `(string.length / 4.0).ceil` — rough but consistent
- Error handling: raise `CodebaseIndex::ExtractionError` for recoverable extraction failures, let unexpected errors propagate

## Testing

- RSpec with `rubocop-rspec` enforcement
- Test extractors against fixture Rails apps (small apps with known structure)
- Every extractor needs tests for: happy path extraction, edge cases (empty files, namespaced classes, STI), concern inlining, dependency detection
- Test `ExtractedUnit#to_h` serialization round-trips
- Test `DependencyGraph` for cycle detection and bidirectional edge resolution

## Planning Documents

The `docs/` directory contains the full design for unbuilt layers. Read `docs/README.md` for the index and reading order. These documents are the source of truth for architectural decisions, backend selection, and implementation sequencing. When implementing retrieval or storage features, read the relevant doc first — don't invent patterns that conflict with the established design.

Key references by topic:
- Backend selection → `docs/BACKEND_MATRIX.md`
- Retrieval pipeline → `docs/RETRIEVAL_ARCHITECTURE.md`
- Chunking and LLM context formatting → `docs/CONTEXT_AND_CHUNKING.md`
- Schema management, error handling, observability → `docs/OPERATIONS.md`
- Agent/MCP integration → `docs/AGENTIC_STRATEGY.md`
- Cost analysis → `docs/BACKEND_MATRIX.md` (bottom section)

## Gotchas

- Extraction **must** run inside a Rails app — the gem has no standalone extraction mode. All extractors assume `Rails`, `ActiveRecord::Base`, etc. are defined.
- `rails_source_extractor.rb` reads source from installed gem paths (`Gem.loaded_specs`). This is read-only and path-sensitive — don't assume gem install locations.
- Service discovery scans `app/services`, `app/interactors`, `app/operations`, `app/commands`, `app/use_cases`. If a host app uses a non-standard directory, it won't be found without configuration.
- The dependency graph can have cycles (A depends on B depends on A). Graph traversal must handle this — see `DependencyGraph#visited` tracking.
- MySQL and PostgreSQL have different JSON querying, indexing, and CTE syntax. Any database-touching code must handle both. Never write PostgreSQL-only SQL and assume it works.
