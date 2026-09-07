# Deferred items and issues

| Item | Reason | Opened |
|---|---|---|
| Operators GUARDCOLLAPSE, GUARDSPLIT | Need compound-statement end detection (nested `if` with dangling `else`). v1 detects simple statements and conditions only. | 2026-09-07 |
| Mutating `while` conditions | Requires body rewriting (`while true do begin … break`). v1 mutates `if` and `until` conditions only. | 2026-09-07 |
| Mutating `if` conditions in `else if`, `then if`, `do if`, or case-branch position | Requires wrapping the whole `if` statement in `begin…end`, which needs compound-statement end detection. | 2026-09-07 |
| Objects other than codeunits (table/page triggers) | Same tokenizer would work; cut for POC size. | 2026-09-07 |
| Phase 4 triage page, Phase 5 incremental runs, Suggest-Test | After Gate G0. | 2026-09-07 |
