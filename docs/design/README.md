# Design Documents

Design-phase documents extracted from the `feat/simplification` branch (Feb 2026). These were written during the early architecture phase before all subsystems were built out. Some details are outdated (e.g., extractor count, cost figures), but the architectural analysis and optimization insights remain valuable.

## Key References

| Document | What's Useful |
|----------|--------------|
| **OPTIMIZATION_BACKLOG.md** | 29 items with severity ratings. Items 1-20 resolved. #21 (tiktoken accuracy) and #22 (concurrent extraction) still actionable. |
| **REVIEW_FINDINGS.md** | Code audit: 13 bugs (B-001 to B-013), doc accuracy, cross-doc contradictions. Most resolved. |
| **AGENTIC_STRATEGY.md** | How AI agents should use CodebaseIndex: task-type to retrieval-pattern mapping, budget awareness, tool-use interface. |
| **RETRIEVAL_ARCHITECTURE.md** | Full retrieval pipeline design: query classification, hybrid search, RRF ranking, context assembly. |
| **OPERATIONS.md** | Deployment, monitoring, error handling, pipeline management patterns. |
| **CONTEXT_AND_CHUNKING.md** | Semantic chunking strategy, token budget allocation, chunk boundary rules. |
| **FLOW_EXTRACTION.md** | Request flow tracing design, controller-through-model paths. |
| **CONSOLE_SERVER.md** | Console MCP server design: tiered tools, safe context, SQL validation. |
| **PROPOSAL.md** | Original project proposal and scope definition. |
| **MODEL_EXTRACTION_FIXES.md** | Model extractor correctness fixes from early development. |

## Plans

- `plans/2025-02-11-claude-toolkit-design.md` - Initial toolkit design concept
- `plans/2026-02-13-ruby-analyzer-design.md` - Prism-based AST layer design (implemented)
