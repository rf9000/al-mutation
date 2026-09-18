# Mutation run 2 summary

## Run

| Metric | Value |
| --- | --- |
| Run no | 2 |
| Backend | DemoPortal |
| Environment | mut-spike-01 |
| AUT version | 1.0.0.0 |
| Started (UTC) | 2026-09-09T00:10:00.0817054Z |
| Finished (UTC) | 2026-09-09T00:26:48.8304198Z |
| Wall clock | 00:16:48.7487144 |

## Totals

| Total | Killed | Survived | Timeout | Compile error | Uncovered | Equivalent |
| --- | --- | --- | --- | --- | --- | --- |
| 41 | 13 | 2 | 2 | 24 | 0 | 0 |

## Score

Score: **0.8824**

## Survivors

| Id | Object | Procedure | Line | Operator | Original -> Mutated | Covering tests |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 50200 | IsLargeOrder | 7 | REL | Quantity >= 10 -> Quantity > 10 | 50300 |
| 8 | 50200 | RequiresApproval | 14 | REL | (Amount > 1000) and (not IsTrusted) -> (Amount >= 1000) and (not IsTrusted) | 50300 |

## Timeouts

| Id | Object | Procedure | Line | Operator | Original -> Mutated | Covering tests |
| --- | --- | --- | --- | --- | --- | --- |
| 32 | 50200 | CountBatches | 39 | COND | Remaining <= 0 -> false | 50300 |
| 39 | 50200 | FirstMultipleAbove | 50 | COND | Candidate > Threshold -> false | 50300 |

## Compile errors

| Id | Object | Procedure | Line | Operator | Original -> Mutated |
| --- | --- | --- | --- | --- | --- |
| 4 | 50200 | IsLargeOrder | 8 | DEL | exit(true) ->  |
| 5 | 50200 | IsLargeOrder | 8 | BREAK | exit(true) -> MutBreak_ThisDoesNotCompile() |
| 6 | 50200 | IsLargeOrder | 9 | DEL | exit(false) ->  |
| 7 | 50200 | IsLargeOrder | 9 | BREAK | exit(false) -> MutBreak_ThisDoesNotCompile() |
| 13 | 50200 | RequiresApproval | 15 | DEL | exit(true) ->  |
| 14 | 50200 | RequiresApproval | 15 | BREAK | exit(true) -> MutBreak_ThisDoesNotCompile() |
| 15 | 50200 | RequiresApproval | 16 | DEL | exit(false) ->  |
| 16 | 50200 | RequiresApproval | 16 | BREAK | exit(false) -> MutBreak_ThisDoesNotCompile() |
| 20 | 50200 | PostOrder | 24 | DEL | Error(QtyErr) ->  |
| 21 | 50200 | PostOrder | 24 | BREAK | Error(QtyErr) -> MutBreak_ThisDoesNotCompile() |
| 22 | 50200 | PostOrder | 25 | BREAK | FxOrder.Posted := true -> MutBreak_ThisDoesNotCompile() |
| 23 | 50200 | PostOrder | 26 | DEL | FxOrder.Modify(true) ->  |
| 24 | 50200 | PostOrder | 26 | INSFLAG | FxOrder.Modify(true) -> FxOrder.Modify(false) |
| 25 | 50200 | PostOrder | 26 | BREAK | FxOrder.Modify(true) -> MutBreak_ThisDoesNotCompile() |
| 26 | 50200 | CountBatches | 34 | BREAK | Remaining := Total -> MutBreak_ThisDoesNotCompile() |
| 27 | 50200 | CountBatches | 35 | BREAK | Batches := 0 -> MutBreak_ThisDoesNotCompile() |
| 28 | 50200 | CountBatches | 37 | BREAK | Remaining -= BatchSize -> MutBreak_ThisDoesNotCompile() |
| 29 | 50200 | CountBatches | 38 | BREAK | Batches += 1 -> MutBreak_ThisDoesNotCompile() |
| 33 | 50200 | CountBatches | 40 | DEL | exit(Batches) ->  |
| 34 | 50200 | CountBatches | 40 | BREAK | exit(Batches) -> MutBreak_ThisDoesNotCompile() |
| 35 | 50200 | FirstMultipleAbove | 47 | BREAK | Candidate := 0 -> MutBreak_ThisDoesNotCompile() |
| 36 | 50200 | FirstMultipleAbove | 49 | BREAK | Candidate += Base -> MutBreak_ThisDoesNotCompile() |
| 40 | 50200 | FirstMultipleAbove | 51 | DEL | exit(Candidate) ->  |
| 41 | 50200 | FirstMultipleAbove | 51 | BREAK | exit(Candidate) -> MutBreak_ThisDoesNotCompile() |

## Uncovered

Uncovered: 0

