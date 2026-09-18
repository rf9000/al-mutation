# Mutation run 1 summary

## Run

| Metric | Value |
| --- | --- |
| Run no | 1 |
| Backend | DemoPortal |
| Environment | mut-spike-01 |
| AUT version | 1.0.0.0 |
| Started (UTC) | 2026-09-08T23:22:01.3408802Z |
| Finished (UTC) | 2026-09-08T23:46:23.5628922Z |
| Wall clock | 00:24:22.2220120 |

## Totals

| Total | Killed | Survived | Timeout | Compile error | Uncovered | Equivalent |
| --- | --- | --- | --- | --- | --- | --- |
| 26 | 18 | 5 | 3 | 0 | 0 | 0 |

## Score

Score: **0.8077**

## Survivors

| Id | Object | Procedure | Line | Operator | Original -> Mutated | Covering tests |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 50200 | IsLargeOrder | 7 | REL | Quantity >= 10 -> Quantity > 10 | 50300 |
| 5 | 50200 | IsLargeOrder | 9 | DEL | exit(false) ->  | 50300 |
| 6 | 50200 | RequiresApproval | 14 | REL | (Amount > 1000) and (not IsTrusted) -> (Amount >= 1000) and (not IsTrusted) | 50300 |
| 12 | 50200 | RequiresApproval | 16 | DEL | exit(false) ->  | 50300 |
| 18 | 50200 | PostOrder | 26 | INSFLAG | FxOrder.Modify(true) -> FxOrder.Modify(false) | 50300 |

## Timeouts

| Id | Object | Procedure | Line | Operator | Original -> Mutated | Covering tests |
| --- | --- | --- | --- | --- | --- | --- |
| 21 | 50200 | CountBatches | 39 | COND | Remaining <= 0 -> false | 50300 |
| 25 | 50200 | FirstMultipleAbove | 50 | COND | Candidate > Threshold -> false | 50300 |
| 26 | 50200 | FirstMultipleAbove | 51 | DEL | exit(Candidate) ->  | 50300 |

## Compile errors

_None._

## Uncovered

Uncovered: 0

