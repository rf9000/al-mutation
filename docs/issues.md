# Deferred items and issues

| Item | Reason | Opened |
|---|---|---|
| Operators GUARDCOLLAPSE, GUARDSPLIT | Need compound-statement end detection (nested `if` with dangling `else`). v1 detects simple statements and conditions only. | 2026-09-07 |
| Mutating `while` conditions | Requires body rewriting (`while true do begin … break`). v1 mutates `if` and `until` conditions only. | 2026-09-07 |
| Mutating `if` conditions in `else if`, `then if`, `do if`, or case-branch position | Requires wrapping the whole `if` statement in `begin…end`, which needs compound-statement end detection. | 2026-09-07 |
| Objects other than codeunits (table/page triggers) | Same tokenizer would work; cut for POC size. | 2026-09-07 |
| Phase 4 triage page, Phase 5 incremental runs, Suggest-Test | After Gate G0. | 2026-09-07 |
| Pester 6.1.0 is what an unpinned Install-Module returns | Spec §9.3 pins Pester 5.x; all test runs import with -MaximumVersion 5.99. Pester 6 compatibility unverified. | 2026-09-07 |
| `node --test dist/test/` (§6.4 toolchain script, T15) fails on the installed Node v22.19.0 (Windows): `node --test <bare-directory-path>` throws `Error: Cannot find module 'C:\...\dist\test' ... code: 'MODULE_NOT_FOUND'` — it tries to `require()` the directory instead of recursively discovering test files in it (confirmed with both a trailing slash and without, on both Bash and native PowerShell, and reproduced in an isolated scratch directory unrelated to this repo). A glob (`node --test dist/test/*.test.js`) and no-path auto-discovery (`node --test`) both work correctly on this same Node install. `generator/package.json`'s `test` script was changed to `npm run build && node --test dist/test/*.test.js` instead of the spec's literal `dist/test/`. | 2026-09-07 |
| Register-ObjectEvent stream capture reorders lines | PowerShell event queue gives no ordering guarantee; Invoke-Continia now uses StandardOutput.ReadToEndAsync/StandardError.ReadToEndAsync with WaitForExit timeout. | 2026-09-07 |
