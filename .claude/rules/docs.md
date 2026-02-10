---
paths:
  - "docs/**/*.md"
---
# Documentation Conventions

These docs are the planning source of truth for unbuilt layers. They serve as reference for both human developers and agentic coding tools.

Rules:
- All configuration examples must show both MySQL and PostgreSQL variants. Never default to one database over the other. MySQL examples should appear first or alongside PostgreSQL, never buried at the bottom.
- Code examples use Ruby with realistic class/method names from the project (`CodebaseIndex::`, `ExtractedUnit`, `Retriever`, etc.)
- SQL examples must be valid for the stated database. Mark adapter-specific syntax clearly.
- When adding a new backend option, update both `BACKEND_MATRIX.md` (detailed analysis) and `PROPOSAL.md` (presets/configuration section)
- Keep the `docs/README.md` index and status table current when adding or completing features
- Use tables for comparison data, prose for explanations. Avoid bullet-point-heavy sections.
