# Agentic Strategy Guide

## Purpose

This document defines how AI agents should interact with CodebaseIndex. It serves as both a design specification for the tool-use interface and a reference guide that agents can consult when deciding how to retrieve codebase context.

The key insight: an agent's retrieval strategy should vary based on what it's trying to accomplish. A debugging task needs different context than an implementation task. This document maps task types to retrieval patterns.

---

## Core Principles

### 1. Retrieve, Don't Guess

When an agent has access to CodebaseIndex, it should retrieve before answering any codebase-specific question. Even if the agent has seen the code in a previous turn, the index may contain richer context (inlined concerns, dependency graph, framework source).

### 2. Start Narrow, Expand As Needed

Begin with the most specific retrieval possible. If that's insufficient, broaden. Don't start with comprehensive retrieval — it wastes token budget on potentially irrelevant context.

```
Step 1: Direct lookup ("Order model") → specific unit
Step 2: If insufficient, retrieve dependencies
Step 3: If still insufficient, semantic search for related concepts
Step 4: If framework behavior needed, retrieve framework source
```

### 3. Budget Awareness

Every retrieval consumes token budget. An agent should track how much context it's accumulated and make explicit decisions about what to include vs. summarize vs. drop.

### 4. Attribution

When the agent references information from retrieval, it should cite the source unit. This enables the human to verify and builds trust.

---

## Tool-Use Interface

### Available Tools

```yaml
tools:
  - name: codebase_retrieve
    description: >
      Semantic retrieval with automatic query classification.
      Returns token-budgeted context with source attribution.
      Best for natural language questions about the codebase.
    parameters:
      query: string (required)
      budget: integer (optional, default 8000)
      filters:
        type: string[] (optional, e.g. ["model", "service"])
        namespace: string[] (optional)
        recency: string (optional, "hot" | "active" | "stable" | "dormant")
      include_framework: boolean (optional, default auto-detect)

  - name: codebase_lookup
    description: >
      Direct unit fetch by identifier. Returns the full extracted unit
      with metadata, source, dependencies, and chunks.
      Best when you know exactly what you need.
    parameters:
      identifier: string (required, e.g. "Order", "CheckoutService")

  - name: codebase_dependencies
    description: >
      Forward dependency graph traversal. Returns everything
      this unit depends on, up to specified depth.
    parameters:
      identifier: string (required)
      depth: integer (optional, default 2)
      types: string[] (optional, filter dependency types)

  - name: codebase_dependents
    description: >
      Reverse dependency graph traversal. Returns everything
      that depends on this unit ("who uses this?").
    parameters:
      identifier: string (required)
      depth: integer (optional, default 2)
      types: string[] (optional)

  - name: codebase_search
    description: >
      Keyword/identifier search across indexed units.
      Best for finding units by name, method, column, or route.
    parameters:
      keywords: string[] (required)
      fields: string[] (optional, default all)
      filters: object (optional)

  - name: codebase_framework
    description: >
      Retrieve Rails/gem source for a specific concept.
      Returns version-pinned implementation details.
    parameters:
      concept: string (required, e.g. "has_many", "validates", "before_action")
      gem: string (optional, e.g. "activerecord", "devise")

  - name: codebase_structure
    description: >
      High-level codebase overview. Model counts, key services,
      architectural patterns, tech stack summary.
    parameters:
      detail: string (optional, "summary" | "full", default "summary")

  - name: codebase_recent_changes
    description: >
      Recently modified units. Useful for understanding what's
      actively being worked on.
    parameters:
      limit: integer (optional, default 20)
      type: string (optional, filter by unit type)
```

---

## Task-to-Strategy Mapping

### Task: Understanding a Feature

**Scenario:** "How does checkout work in this application?"

**Strategy: Broad semantic → dependency expansion → selective deep dive**

```
1. codebase_retrieve("checkout flow order processing")
   → Returns: CheckoutService, OrdersController#create, Cart, Order
   → Token cost: ~3000

2. Agent identifies CheckoutService as central.
   codebase_dependencies("CheckoutService", depth: 1)
   → Returns: PaymentGateway, ShippingCalculator, TaxService, Order
   → Token cost: ~2000

3. Agent needs to understand payment specifically.
   codebase_lookup("PaymentGateway")
   → Returns: Full unit with methods, dependencies, error handling
   → Token cost: ~800

Total budget used: ~5800 / 8000
Agent now has enough context to explain the checkout flow.
```

**Key decisions:**
- Don't retrieve everything at once — it fills the budget with potentially irrelevant units
- Use dependency graph to discover related units rather than guessing
- Stop retrieving when you have enough to answer the question

---

### Task: Debugging an Error

**Scenario:** "Getting a `NoMethodError` on `order.calculate_total` — why?"

**Strategy: Direct lookup → callback/concern inspection → framework check**

```
1. codebase_lookup("Order")
   → Returns: Full model with inlined concerns, callbacks, methods
   → Agent checks: is calculate_total defined? In a concern? In a module?
   → Token cost: ~1500

2. If method isn't visible, check if it's dynamically defined:
   codebase_framework("method_missing activerecord")
   → Returns: How AR handles dynamic methods, attribute methods, etc.
   → Token cost: ~500

3. If it's in a concern:
   Agent already has it (concerns are inlined in extraction).
   Check the concern's conditional inclusion logic.

4. Check recent changes:
   codebase_recent_changes(limit: 10, type: "model")
   → Was Order or any of its concerns recently modified?
   → Token cost: ~400

Total budget used: ~2400 / 8000
```

**Key decisions:**
- Start with the specific unit, not a semantic search
- Inlined concerns mean you don't need to separately fetch them
- Framework source is useful when the error might be Rails behavior, not app code
- Recent changes can identify regressions

---

### Task: Implementing a New Feature

**Scenario:** "Add a gift card payment method to checkout"

**Strategy: Understand existing patterns → find analogous implementations → identify integration points**

```
1. codebase_retrieve("payment methods checkout payment processing")
   → Returns: PaymentGateway, StripeService, PaypalService, etc.
   → Agent understands the payment abstraction pattern
   → Token cost: ~3000

2. codebase_lookup("StripeService")
   → Study how an existing payment method is implemented
   → Identify the interface: what methods it exposes, how it's called
   → Token cost: ~800

3. codebase_dependents("PaymentGateway", depth: 1)
   → Who calls into the payment system?
   → Identifies: CheckoutService, RefundService, AdminPaymentsController
   → These are the integration points for the new payment method
   → Token cost: ~1000

4. codebase_search(keywords: ["payment", "gateway"], fields: ["routes"])
   → Find the routes/controllers that handle payment selection
   → Token cost: ~300

Total budget used: ~5100 / 8000
Agent can now propose: "Based on the existing pattern (StripeService, PaypalService),
create a GiftCardService that implements the same interface..."
```

**Key decisions:**
- Find existing analogous code before proposing new code
- Use reverse dependencies to find integration points
- The agent should propose code that follows existing patterns

---

### Task: Performance Investigation

**Scenario:** "The orders page is slow — what might cause it?"

**Strategy: Trace the request path → identify heavy operations → check callback chains**

```
1. codebase_search(keywords: ["orders"], fields: ["routes"])
   → Find: GET /admin/orders → OrdersController#index
   → Token cost: ~200

2. codebase_lookup("OrdersController")
   → Full controller with filter chain, actions, params
   → Agent sees: before_actions, eager loading (or lack thereof), serialization
   → Token cost: ~1200

3. codebase_dependencies("OrdersController", depth: 1)
   → Models loaded: Order, Account, LineItem, Shipment...
   → Agent checks for N+1 patterns in the action code
   → Token cost: ~2000

4. codebase_lookup("Order")
   → Check: scopes used in index, callback chain on load, association counts
   → Token cost: ~1500

5. codebase_retrieve("order serializer decorator presenter")
   → Find how orders are rendered — heavy serialization?
   → Token cost: ~1000

Total budget used: ~5900 / 8000
```

**Key decisions:**
- Start from the HTTP entry point (route → controller)
- Follow the data loading path (controller → models)
- Check for known Rails performance antipatterns (N+1, missing eager loads, heavy callbacks on read)
- Check the rendering/serialization layer

---

### Task: Framework Reference

**Scenario:** "What options does has_many accept in our Rails version?"

**Strategy: Direct framework source retrieval**

```
1. codebase_framework("has_many", gem: "activerecord")
   → Returns: Exact source from the installed Rails version
   → Includes: all options, their defaults, and behavior
   → Token cost: ~2000

That's it. One call. No need for application code.
```

**Key decision:** Recognize when the question is about Rails behavior, not application behavior. Route directly to framework source.

---

### Task: Impact Analysis

**Scenario:** "What would break if I change the Order model's `total` column to `total_amount`?"

**Strategy: Reverse dependency traversal → keyword search for column references**

```
1. codebase_dependents("Order", depth: 2)
   → Everything that uses Order: controllers, services, jobs, mailers, components
   → Token cost: ~3000

2. codebase_search(keywords: ["total"], fields: ["method_names", "column_names"])
   → Find every unit that references a `total` method/column
   → Token cost: ~500

3. Agent cross-references: which of the dependents reference `total`?
   → These are the units that would need updating.

Total budget used: ~3500 / 8000
```

**Key decision:** Combine graph traversal (structural dependencies) with keyword search (textual references) for complete impact analysis.

---

### Task: Onboarding / Orientation

**Scenario:** New developer asks "Give me an overview of this codebase"

**Strategy: Structure overview → key models → architectural patterns**

```
1. codebase_structure(detail: "full")
   → Returns: Model counts, service patterns, tech stack, key conventions
   → Token cost: ~1000

2. codebase_retrieve("core domain models most important")
   → Returns: The models with highest importance scores
   → Token cost: ~2000

3. codebase_retrieve("architectural patterns service objects conventions")
   → Returns: Representative service objects showing patterns
   → Token cost: ~2000

Total budget used: ~5000 / 8000
Agent can synthesize a codebase orientation document.
```

---

## Multi-Turn Retrieval Patterns

### Conversation Context Management

Across multiple turns, the agent should:

1. **Track retrieved units** — Don't re-retrieve what you already have
2. **Accumulate understanding** — Build a mental model across turns
3. **Adjust budget** — Later turns can use remaining budget from earlier turns
4. **Reference previous retrievals** — "As seen in the Order model retrieved earlier..."

### Deduplication

The retrieval layer accepts a `previously_retrieved` parameter:

```yaml
codebase_retrieve:
  query: "order validation rules"
  previously_retrieved: ["Order", "CheckoutService", "OrdersController"]
  # These units will be excluded from results (already in context)
```

### Progressive Depth

```
Turn 1: "What does this codebase do?"
  → codebase_structure() → broad overview
  
Turn 2: "Tell me more about the order system"
  → codebase_retrieve("order system") → key order-related units
  
Turn 3: "How are payments handled?"
  → codebase_dependencies("Order") filtered to payment-related
  → codebase_lookup("PaymentGateway")
  
Turn 4: "What happens when a payment fails?"
  → codebase_retrieve("payment failure error handling retry")
  → codebase_framework("rescue_from") if error handling is framework-level
```

Each turn builds on the previous, and the agent's understanding compounds.

---

## Output Format for Agents

### Structured Response

Retrieval results should be structured for agent consumption, not just raw text:

```json
{
  "context": "... assembled context string ...",
  "tokens_used": 4521,
  "budget_remaining": 3479,
  "sources": [
    {
      "identifier": "Order",
      "type": "model",
      "file_path": "app/models/order.rb",
      "relevance_score": 0.94,
      "change_frequency": "hot",
      "truncated": false
    },
    {
      "identifier": "CheckoutService",
      "type": "service",
      "file_path": "app/services/checkout_service.rb",
      "relevance_score": 0.87,
      "change_frequency": "active",
      "truncated": false
    }
  ],
  "classification": {
    "intent": "understand",
    "scope": "focused",
    "target_type": "service",
    "framework_context": false
  },
  "suggestions": [
    "Consider retrieving dependencies of CheckoutService for more context",
    "Related units not included due to budget: RefundService, OrderMailer"
  ]
}
```

### Suggestions Field

The `suggestions` field helps agents decide what to retrieve next. It includes:
- Units that were relevant but didn't fit in the budget
- Dependency paths that might be useful
- Framework source that might clarify behavior
- Related units in the same namespace

### Confidence Signals

Each source includes a `relevance_score` so the agent can assess confidence:
- 0.90+ → Highly relevant, almost certainly what was asked about
- 0.75-0.90 → Likely relevant, worth including
- 0.60-0.75 → Possibly relevant, include if budget allows
- < 0.60 → Marginal, probably noise

---

## MCP Server Design

For agent frameworks that support MCP (Model Context Protocol), CodebaseIndex exposes itself as an MCP server:

```json
{
  "name": "codebase-index",
  "version": "1.0.0",
  "description": "Rails codebase extraction and retrieval",
  "tools": [
    {
      "name": "retrieve",
      "description": "Semantic retrieval with auto-classification",
      "inputSchema": {
        "type": "object",
        "properties": {
          "query": { "type": "string" },
          "budget": { "type": "integer", "default": 8000 },
          "filters": { "type": "object" }
        },
        "required": ["query"]
      }
    },
    {
      "name": "lookup",
      "description": "Direct unit fetch by identifier",
      "inputSchema": {
        "type": "object",
        "properties": {
          "identifier": { "type": "string" }
        },
        "required": ["identifier"]
      }
    },
    {
      "name": "dependencies",
      "description": "Forward dependency traversal",
      "inputSchema": {
        "type": "object",
        "properties": {
          "identifier": { "type": "string" },
          "depth": { "type": "integer", "default": 2 }
        },
        "required": ["identifier"]
      }
    },
    {
      "name": "dependents",
      "description": "Reverse dependency traversal (who uses this?)",
      "inputSchema": {
        "type": "object",
        "properties": {
          "identifier": { "type": "string" },
          "depth": { "type": "integer", "default": 2 }
        },
        "required": ["identifier"]
      }
    },
    {
      "name": "framework_source",
      "description": "Version-pinned Rails/gem source",
      "inputSchema": {
        "type": "object",
        "properties": {
          "concept": { "type": "string" },
          "gem": { "type": "string" }
        },
        "required": ["concept"]
      }
    },
    {
      "name": "structure",
      "description": "Codebase overview and architecture summary",
      "inputSchema": {
        "type": "object",
        "properties": {
          "detail": { "type": "string", "enum": ["summary", "full"] }
        }
      }
    }
  ],
  "resources": [
    {
      "uri": "codebase://manifest",
      "name": "Index Manifest",
      "description": "Extraction metadata, git SHA, unit counts"
    },
    {
      "uri": "codebase://graph",
      "name": "Dependency Graph",
      "description": "Full dependency graph as adjacency list"
    }
  ]
}
```

### MCP Server Implementation Strategy

The MCP server wraps the Ruby retrieval core:

```
Agent (Claude Code, Cursor, etc.)
  │
  │ MCP protocol (stdio or HTTP)
  │
  ▼
┌──────────────────┐
│ MCP Server       │  Ruby process, thin protocol wrapper
│ (mcp-server-rb)  │
└──────────────────┘
  │
  │ Direct Ruby calls
  │
  ▼
┌──────────────────┐
│ CodebaseIndex    │  Retriever, stores, embedding provider
│ Retrieval Core   │
└──────────────────┘
```

The server can run:
- **Standalone:** `bundle exec codebase-mcp-server` (stdio mode)
- **In-process:** Loaded within a Rails console or development server
- **HTTP:** As a Rack app for network-accessible retrieval

---

## Anti-Patterns

### Don't: Retrieve Everything First

```
# BAD: Burns entire budget on one massive retrieval
codebase_retrieve("tell me everything about orders", budget: 16000)
```

```
# GOOD: Incremental, focused retrieval
codebase_lookup("Order")
# ... assess what's needed ...
codebase_dependencies("Order", depth: 1)
```

### Don't: Ignore Classification

```
# BAD: Treat every question the same way
codebase_retrieve("what column type is users.email")  # Wastes budget on semantic search
```

```
# GOOD: Use the right tool
codebase_lookup("User")  # Direct lookup, check schema metadata
```

### Don't: Re-Retrieve Known Context

```
# BAD: Retrieve Order again in a follow-up turn
Turn 1: codebase_lookup("Order")
Turn 2: codebase_retrieve("order validations")  # Will re-fetch Order
```

```
# GOOD: Use previously_retrieved
Turn 2: codebase_retrieve("order validations", previously_retrieved: ["Order"])
```

### Don't: Skip Framework Source for Framework Questions

```
# BAD: Answer "what options does validates support" from memory
# LLM training data mixes Rails versions
```

```
# GOOD: 
codebase_framework("validates", gem: "activerecord")
# Returns exact options for the installed Rails version
```

### Don't: Ignore the Dependency Graph

```
# BAD: Semantic search for "what services use Order"
codebase_retrieve("services that use Order")  # May miss some
```

```
# GOOD: Graph traversal is exhaustive
codebase_dependents("Order", types: ["service"])
# Returns ALL services that depend on Order
```

---

## Evaluation Queries

These queries can be used to evaluate retrieval quality across different task types:

### Understanding Queries
1. "How does the checkout process work end-to-end?"
2. "Explain the relationship between accounts and subscriptions"
3. "What happens when a product is published?"
4. "How are prices calculated for an order?"

### Debugging Queries
5. "What callbacks fire when an order is saved?"
6. "What could cause a payment to silently fail?"
7. "Why might a user's session not persist?"
8. "What validations prevent order creation?"

### Implementation Queries
9. "How should I add a new discount type?"
10. "What's the pattern for adding a new background job?"
11. "How do existing services handle external API failures?"
12. "What's the convention for adding a new admin controller?"

### Framework Queries
13. "What options does has_many support?"
14. "How does Rails handle strong parameters?"
15. "What lifecycle callbacks exist for ActiveRecord?"
16. "How does Devise handle authentication?"

### Impact Queries
17. "What would break if I rename the orders table?"
18. "What depends on the Account model?"
19. "What services would be affected by changing the payment API?"
20. "Which controllers use the authentication concern?"

### Performance Queries
21. "What models have the most callbacks?"
22. "Which controllers load the most associations?"
23. "What are the most frequently changed files?"
24. "Which services have the most dependencies?"

### Orientation Queries
25. "Give me an overview of this codebase"
26. "What are the key domain models?"
27. "What external services does this app integrate with?"
28. "What's the testing strategy?"
