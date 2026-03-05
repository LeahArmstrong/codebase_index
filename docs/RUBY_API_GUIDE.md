# Ruby API Guide

CodebaseIndex provides a Ruby API for programmatic access to extraction output. Use it when you need to script queries, build custom tooling, or integrate codebase data into your own workflows.

**When to use what:**

| Interface | Best for |
|-----------|----------|
| MCP servers | AI tools (Claude Code, Cursor, Windsurf) — no Ruby needed |
| Rake tasks | CLI extraction and validation |
| Ruby API | Custom scripts, CI pipelines, programmatic queries |

---

## Programmatic Extraction

Extraction requires a booted Rails environment. Run these from a Rails console or a rake task inside your app.

### Full Extraction

```ruby
# Extract everything — all 34 extractors run, output written to configured dir
result = CodebaseIndex.extract!

# Override output directory
result = CodebaseIndex.extract!(output_dir: Rails.root.join("tmp/custom_index"))
```

### Incremental Extraction

```ruby
# Only re-extract units whose files changed
changed = %w[app/models/order.rb app/services/checkout_service.rb]
re_extracted = CodebaseIndex.extract_changed!(changed)
# => ["Order", "CheckoutService"]
```

---

## Reading Extraction Output with IndexReader

`IndexReader` reads the JSON files produced by extraction. It does **not** require Rails — it works anywhere that can read the output directory.

```ruby
require 'codebase_index/mcp/index_reader'

reader = CodebaseIndex::MCP::IndexReader.new("/path/to/tmp/codebase_index")
```

### Manifest and Summary

```ruby
reader.manifest
# => {
#   "extracted_at" => "2025-03-01T14:30:00Z",
#   "git_sha" => "abc1234",
#   "unit_counts" => { "model" => 42, "controller" => 18, "service" => 25, ... },
#   "total_units" => 210
# }

reader.summary
# => "# Codebase Summary\n\n42 models, 18 controllers, 25 services..."
```

---

## Listing All Models with Schema

```ruby
models = reader.list_units(type: "model")
# => [
#   { "identifier" => "User", "file_path" => "app/models/user.rb" },
#   { "identifier" => "Order", "file_path" => "app/models/order.rb" },
#   ...
# ]

# Get full details for each model (includes schema, associations, callbacks)
models.each do |entry|
  unit = reader.find_unit(entry["identifier"])
  puts "#{unit['identifier']}:"
  puts "  Columns: #{unit.dig('metadata', 'columns')&.map { |c| c['name'] }&.join(', ')}"
  puts "  Associations: #{unit.dig('metadata', 'associations')&.map { |a| "#{a['type']} :#{a['name']}" }&.join(', ')}"
end
# Output:
#   User:
#     Columns: id, email, name, created_at, updated_at
#     Associations: has_many :orders, has_many :comments
#   Order:
#     Columns: id, user_id, status, total_cents, created_at, updated_at
#     Associations: belongs_to :user, has_many :line_items
```

---

## Extracting a Single Model with Inlined Concerns

```ruby
unit = reader.find_unit("Order")

# Full source with concerns inlined and schema prepended
puts unit["source_code"]
# => "# == Schema Information\n# id :bigint not null, pk\n# user_id :bigint\n# status :string\n# total_cents :integer\n#\nclass Order < ApplicationRecord\n  include Auditable\n  belongs_to :user\n  has_many :line_items\n  ...\nend\n\n# --- Concern: Auditable ---\nmodule Auditable\n  extend ActiveSupport::Concern\n  included do\n    before_save :set_audit_trail\n  end\n  ...\nend"

# Structured metadata
unit["metadata"]["associations"]
# => [
#   { "type" => "belongs_to", "name" => "user", "model" => "User" },
#   { "type" => "has_many", "name" => "line_items", "model" => "LineItem" }
# ]

unit["metadata"]["callbacks"]
# => [
#   {
#     "type" => "after_commit",
#     "method" => "send_confirmation_email",
#     "on" => ["create"],
#     "side_effects" => { "jobs_enqueued" => ["OrderConfirmationJob"], "services_called" => [] }
#   }
# ]

unit["metadata"]["validations"]
# => [
#   { "attribute" => "status", "kind" => "inclusion", "in" => ["pending", "paid", "shipped"] },
#   { "attribute" => "total_cents", "kind" => "numericality", "greater_than" => 0 }
# ]

unit["metadata"]["inlined_concerns"]
# => ["Auditable"]
```

---

## Listing Routes and Controller Actions

```ruby
# All routes
routes = reader.list_units(type: "route")
routes.each do |entry|
  unit = reader.find_unit(entry["identifier"])
  meta = unit["metadata"]
  puts "#{entry['identifier']}  =>  #{meta['controller']}##{meta['action']}"
end
# Output:
#   GET /orders       =>  orders#index
#   POST /orders      =>  orders#create
#   GET /orders/:id   =>  orders#show
#   PATCH /orders/:id =>  orders#update

# Controller with full action metadata
ctrl = reader.find_unit("OrdersController")
ctrl["metadata"]["actions"]     # => ["index", "show", "create", "update"]
ctrl["metadata"]["routes"]
# => [
#   { "verb" => "GET", "path" => "/orders", "action" => "index" },
#   { "verb" => "POST", "path" => "/orders", "action" => "create" },
#   ...
# ]
ctrl["metadata"]["filters"]
# => {
#   "before" => ["authenticate_user!", "set_order"],
#   "after" => ["track_event"]
# }
```

---

## Querying the Dependency Graph

The `DependencyGraph` tracks bidirectional relationships between all units and computes PageRank importance scores.

### Using IndexReader (from extraction output)

```ruby
# BFS traversal of forward dependencies
tree = reader.traverse_dependencies("Order", depth: 2)
# => {
#   root: "Order",
#   found: true,
#   nodes: {
#     "Order" => { type: "model", depth: 0, deps: ["User", "LineItem"] },
#     "User" => { type: "model", depth: 1, deps: ["Account"] },
#     "LineItem" => { type: "model", depth: 1, deps: ["Product"] }
#   }
# }

# BFS traversal of reverse dependencies (what depends on Order?)
dependents = reader.traverse_dependents("Order", depth: 2, types: ["controller", "service"])
# => {
#   root: "Order",
#   found: true,
#   nodes: {
#     "Order" => { type: "model", depth: 0, deps: ["OrdersController", "CheckoutService"] },
#     "OrdersController" => { type: "controller", depth: 1, deps: [] },
#     "CheckoutService" => { type: "service", depth: 1, deps: ["OrderMailer"] }
#   }
# }
```

### Using DependencyGraph Directly (in-process, requires Rails)

```ruby
graph = CodebaseIndex::DependencyGraph.new

# Register units (normally done by the Extractor)
graph.register(user_unit)
graph.register(order_unit)

# Direct queries
graph.dependencies_of("Order")   # => ["User", "LineItem"]
graph.dependents_of("User")      # => ["Order", "Comment", "UsersController"]
graph.units_of_type(:model)      # => ["User", "Order", "LineItem", "Comment", ...]

# Blast radius: what's affected by a file change?
graph.affected_by(["app/models/user.rb"])
# => ["User", "Order", "UsersController", "ProfileService", ...]

# PageRank importance scores
scores = graph.pagerank
scores.sort_by { |_, v| -v }.first(5).each do |id, score|
  puts "#{id}: #{score.round(4)}"
end
# Output:
#   User: 0.0842
#   Order: 0.0631
#   Product: 0.0523
#   Account: 0.0412
#   LineItem: 0.0389
```

---

## Accessing Framework and Gem Source

`RailsSourceExtractor` indexes high-value Rails framework source and gem source files, pinned to the exact versions in your `Gemfile.lock`.

```ruby
# Search indexed framework source by keyword
results = reader.framework_sources("has_many", limit: 5)
# => [
#   {
#     identifier: "ActiveRecord::Associations::ClassMethods",
#     type: "rails_source",
#     file_path: "/path/to/gems/activerecord-7.2.0/lib/active_record/associations.rb",
#     metadata: { "gem" => "activerecord", "version" => "7.2.0" }
#   },
#   ...
# ]

# Get the full source of a framework unit
unit = reader.find_unit("ActiveRecord::Associations::ClassMethods")
puts unit["source_code"]  # => actual Rails source for has_many, belongs_to, etc.
```

### Configuring Additional Gems

```ruby
# config/initializers/codebase_index.rb
CodebaseIndex.configure do |config|
  config.add_gem "devise", paths: ["lib/devise/models"], priority: :high
  config.add_gem "pundit", paths: ["lib/pundit"], priority: :medium
end
```

After extraction, these gems appear as `rails_source` type units searchable via `framework_sources`.

---

## Git Enrichment Data

Every unit with a file path gets git metadata after extraction. The `metadata.git` hash contains:

```ruby
unit = reader.find_unit("Order")
git = unit.dig("metadata", "git")
# => {
#   "last_modified" => "2025-02-15T10:22:00Z",
#   "last_author" => "Alice",
#   "commit_count" => 47,
#   "change_frequency" => "hot",
#   "contributors" => [
#     { "name" => "Alice", "commits" => 22 },
#     { "name" => "Bob", "commits" => 15 },
#     { "name" => "Carol", "commits" => 10 }
#   ],
#   "recent_commits" => [
#     { "sha" => "abc1234", "message" => "Add status validation", "date" => "2025-02-15", "author" => "Alice" },
#     { "sha" => "def5678", "message" => "Fix total calculation", "date" => "2025-02-10", "author" => "Bob" },
#     ...
#   ]
# }
```

### Finding Recently Changed Code

```ruby
# Most recently modified units (useful for code review or onboarding)
changes = reader.recent_changes(limit: 10, types: ["model", "service"])
changes.each do |c|
  puts "#{c[:identifier]} (#{c[:type]}) — last modified #{c[:last_modified]}"
end
# Output:
#   Order (model) — last modified 2025-02-15T10:22:00Z
#   CheckoutService (service) — last modified 2025-02-14T09:15:00Z
#   User (model) — last modified 2025-02-10T16:45:00Z
#   ...
```

### Change Frequency Categories

| Frequency | Meaning |
|-----------|---------|
| `new` | Created in the last 30 days |
| `hot` | 10+ commits in the last 90 days |
| `active` | 3-9 commits in the last 90 days |
| `stable` | 1-2 commits in the last 90 days |
| `dormant` | No commits in the last 90 days |

---

## Controller Action Context

Combine unit lookup with dependency traversal to build full context for a controller action:

```ruby
# 1. Get the controller
ctrl = reader.find_unit("OrdersController")

# 2. Get its dependencies (services, models it touches)
deps = reader.traverse_dependencies("OrdersController", depth: 2)

# 3. Collect all related units
context_units = deps[:nodes].keys.map { |id| reader.find_unit(id) }.compact

# 4. Now you have: controller source + all models/services/jobs it touches
context_units.each do |u|
  puts "#{u['identifier']} (#{u['type']}): #{u['source_code']&.lines&.count} lines"
end
# Output:
#   OrdersController (controller): 85 lines
#   Order (model): 120 lines
#   User (model): 95 lines
#   CheckoutService (service): 60 lines
#   OrderConfirmationJob (job): 25 lines
```

---

## Runtime Introspection Output

CodebaseIndex uses runtime introspection to capture data that static analysis cannot. Here's what that looks like in practice.

### Callbacks with Side Effects

```ruby
unit = reader.find_unit("Order")
unit["metadata"]["callbacks"]
# => [
#   {
#     "type" => "before_save",
#     "method" => "normalize_status",
#     "side_effects" => { "columns_written" => ["status", "normalized_at"], "jobs_enqueued" => [], "services_called" => [] }
#   },
#   {
#     "type" => "after_commit",
#     "method" => "send_confirmation_email",
#     "on" => ["create"],
#     "side_effects" => { "columns_written" => [], "jobs_enqueued" => ["OrderConfirmationJob"], "services_called" => [] }
#   },
#   {
#     "type" => "after_commit",
#     "method" => "sync_to_warehouse",
#     "on" => ["update"],
#     "side_effects" => { "columns_written" => [], "jobs_enqueued" => [], "services_called" => ["WarehouseSync"] }
#   }
# ]
```

### Associations with Reflection Data

```ruby
unit["metadata"]["associations"]
# => [
#   { "type" => "belongs_to", "name" => "user", "model" => "User", "foreign_key" => "user_id", "optional" => false },
#   { "type" => "has_many", "name" => "line_items", "model" => "LineItem", "foreign_key" => "order_id", "dependent" => "destroy" },
#   { "type" => "has_one", "name" => "invoice", "model" => "Invoice", "foreign_key" => "order_id" }
# ]
```

### Validations

```ruby
unit["metadata"]["validations"]
# => [
#   { "attribute" => "status", "kind" => "inclusion", "in" => ["pending", "paid", "shipped", "cancelled"] },
#   { "attribute" => "total_cents", "kind" => "numericality", "greater_than" => 0 },
#   { "attribute" => "user", "kind" => "presence" }
# ]
```

---

## Retrieval Pipeline

The retrieval pipeline provides semantic search over extracted units. It requires an embedding provider to be configured.

### Configuration

```ruby
CodebaseIndex.configure do |config|
  config.embedding_provider = :openai
  config.embedding_options = { api_key: ENV["OPENAI_API_KEY"] }
  config.vector_store = :pgvector   # or :qdrant, :sqlite
  config.metadata_store = :postgresql  # or :mysql, :sqlite
end
```

### Querying

```ruby
result = CodebaseIndex.retrieve("How does order checkout work?")

result.context       # => formatted context string with relevant source code
result.sources       # => [{ identifier: "CheckoutService", type: "service", score: 0.92 }, ...]
result.strategy      # => :hybrid (or :vector, :keyword, :graph)
result.tokens_used   # => 4200
result.budget        # => 8000
result.classification # => { intent: :explanation, scope: :specific, target_type: "service" }

# Custom token budget
result = CodebaseIndex.retrieve("user authentication flow", budget: 12000)
```

### Building a Retriever Directly

```ruby
retriever = CodebaseIndex.build_retriever

# Multiple queries with the same retriever instance
r1 = retriever.retrieve("payment processing")
r2 = retriever.retrieve("user permissions", budget: 4000)
```

---

## Search

```ruby
# Search by identifier (fast — index-only)
reader.search("Order", types: ["model", "service"], limit: 10)
# => [
#   { identifier: "Order", type: "model", match_field: "identifier" },
#   { identifier: "OrderService", type: "service", match_field: "identifier" }
# ]

# Search across source code (slower — loads unit files)
reader.search("perform_later", fields: ["source_code"], types: ["model"], limit: 5)
# => [
#   { identifier: "Order", type: "model", match_field: "source_code" },
#   { identifier: "User", type: "model", match_field: "source_code" }
# ]
```

---

## Graph Analysis

The extraction output includes `graph_analysis.json` with pre-computed structural insights:

```ruby
analysis = reader.graph_analysis
# => {
#   "orphans" => ["LegacyImporter", "UnusedHelper"],
#   "dead_ends" => ["EmailValidator", "CurrencyFormatter"],
#   "hubs" => [
#     { "identifier" => "User", "dependents_count" => 34 },
#     { "identifier" => "Order", "dependents_count" => 22 }
#   ],
#   "cycles" => [
#     ["Order", "LineItem", "Product", "Order"]
#   ],
#   "bridges" => ["AuthenticationService", "BaseController"]
# }
```
