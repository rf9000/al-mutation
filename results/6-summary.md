# Mutation run 6 summary

## Run

| Metric | Value |
| --- | --- |
| Run no | 6 |
| Backend | DemoPortal |
| Environment | mut-spike-02 |
| AUT version | 29.0.0.0 |
| Started (UTC) | 2026-09-17T21:32:51.1680358Z |
| Finished (UTC) | 2026-09-17T22:28:09.5491343Z |
| Wall clock | 00:55:18.3810985 |

## Totals

| Total | Killed | Survived | Timeout | Compile error | Uncovered | Equivalent |
| --- | --- | --- | --- | --- | --- | --- |
| 157 | 62 | 95 | 0 | 0 | 0 | 0 |

## Score

Score: **0.3949**

## Survivors

| Id | Object | Procedure | Line | Operator | Original -> Mutated | Covering tests |
| --- | --- | --- | --- | --- | --- | --- |
| 140 | 72918635 | DetectInCompany | 69 | COND | not CoreMgt.IsAppActiveInCompany(TargetCompany) -> false | 95155 |
| 141 | 72918635 | DetectInCompany | 71 | DEL | exit ->  | 95155, 95179, 95191 |
| 145 | 72918635 | DetectInCompany | 76 | DEL | exit ->  | 95155, 95179, 95191 |
| 146 | 72918635 | DetectInCompany | 79 | REL | AuthenticationEntry."Originating Company" <> '' -> AuthenticationEntry."Originating Company" = '' | 95155 |
| 147 | 72918635 | DetectInCompany | 79 | COND | AuthenticationEntry."Originating Company" <> '' -> true | 95155 |
| 148 | 72918635 | DetectInCompany | 79 | COND | AuthenticationEntry."Originating Company" <> '' -> false | 95155 |
| 151 | 72918635 | DetectInCompany | 85 | COND | SourceBank.Code = '' -> false | 95155 |
| 152 | 72918635 | DetectInCompany | 86 | DEL | exit ->  | 95155, 95179, 95191 |
| 153 | 72918635 | DetectInCompany | 94 | COND | BankAccount.FindSet() -> true | 95155 |
| 157 | 72918635 | DetectInCompany | 113 | COND | MissingInfo -> true | 95155, 95179, 95191 |
| 158 | 72918635 | DetectInCompany | 113 | COND | MissingInfo -> false | 95155, 95179, 95191 |
| 159 | 72918635 | DetectInCompany | 120 | REL | MatchingAccounts.Count() > 0 -> MatchingAccounts.Count() >= 0 | 95155 |
| 160 | 72918635 | DetectInCompany | 120 | COND | MatchingAccounts.Count() > 0 -> true | 95155 |
| 161 | 72918635 | DetectInCompany | 120 | COND | MatchingAccounts.Count() > 0 -> false | 95155 |
| 162 | 72918635 | EmitShareDetectionRan | 153 | REL | AccountsAttempted = 0 -> AccountsAttempted <> 0 | 95155 |
| 163 | 72918635 | EmitShareDetectionRan | 153 | COND | AccountsAttempted = 0 -> true | 95155 |
| 164 | 72918635 | EmitShareDetectionRan | 153 | COND | AccountsAttempted = 0 -> false | 95155 |
| 165 | 72918635 | EmitShareDetectionRan | 154 | DEL | exit ->  | 95155, 95179, 95191 |
| 168 | 72918635 | AppendAccountForBank | 177 | COND | BankCode = '' -> false | 95155 |
| 169 | 72918635 | AppendAccountForBank | 178 | DEL | exit ->  | 95155, 95179, 95191 |
| 171 | 72918635 | AppendAccountForBank | 179 | COND | ResolvedOtherAccountsByBank.ContainsKey(BankCode) -> false | 95155 |
| 173 | 72918635 | ResolveBankCodeForAccount | 204 | REL | (BankAccount.IBAN = '') and (BankAccount."Bank Branch No." = '') -> (BankAccount.IBAN = '') and (BankAccount."Bank Branch No." <> '') | 95155 |
| 176 | 72918635 | ResolveBankCodeForAccount | 204 | COND | (BankAccount.IBAN = '') and (BankAccount."Bank Branch No." = '') -> false | 95155 |
| 177 | 72918635 | ResolveBankCodeForAccount | 206 | DEL | exit(false) ->  | 95155, 95179, 95191 |
| 181 | 72918635 | ResolveBankCodeForAccount | 210 | DEL | exit(false) ->  | 95155, 95179, 95191 |
| 183 | 72918635 | ResolveBankCodeForAccount | 212 | COND | TempBank.Code <> '' -> true | 95155, 95179 |
| 186 | 72918635 | IsSourceSystemMappedToBank | 232 | REL | (BankCode = '') or (SourceBankSystemCode = '') -> (BankCode <> '') or (SourceBankSystemCode = '') | 95155 |
| 187 | 72918635 | IsSourceSystemMappedToBank | 232 | REL | (BankCode = '') or (SourceBankSystemCode = '') -> (BankCode = '') or (SourceBankSystemCode <> '') | 95155 |
| 188 | 72918635 | IsSourceSystemMappedToBank | 232 | BOOL | (BankCode = '') or (SourceBankSystemCode = '') -> (BankCode = '') and (SourceBankSystemCode = '') | 95155 |
| 189 | 72918635 | IsSourceSystemMappedToBank | 232 | COND | (BankCode = '') or (SourceBankSystemCode = '') -> true | 95155 |
| 190 | 72918635 | IsSourceSystemMappedToBank | 232 | COND | (BankCode = '') or (SourceBankSystemCode = '') -> false | 95155 |
| 191 | 72918635 | IsSourceSystemMappedToBank | 233 | DEL | exit(false) ->  | 95155, 95179, 95191 |
| 192 | 72918635 | IsSourceSystemMappedToBank | 236 | DEL | exit(not BankSystemMapping2.IsEmpty()) ->  | 95155 |
| 193 | 72918635 | IsSourceCommTypeSupportedByBank | 249 | REL | (BankCode = '') or (SourceBankSystemCode = '') -> (BankCode <> '') or (SourceBankSystemCode = '') | 95155 |
| 194 | 72918635 | IsSourceCommTypeSupportedByBank | 249 | REL | (BankCode = '') or (SourceBankSystemCode = '') -> (BankCode = '') or (SourceBankSystemCode <> '') | 95155 |
| 195 | 72918635 | IsSourceCommTypeSupportedByBank | 249 | BOOL | (BankCode = '') or (SourceBankSystemCode = '') -> (BankCode = '') and (SourceBankSystemCode = '') | 95155 |
| 196 | 72918635 | IsSourceCommTypeSupportedByBank | 249 | COND | (BankCode = '') or (SourceBankSystemCode = '') -> true | 95155 |
| 197 | 72918635 | IsSourceCommTypeSupportedByBank | 249 | COND | (BankCode = '') or (SourceBankSystemCode = '') -> false | 95155 |
| 198 | 72918635 | IsSourceCommTypeSupportedByBank | 250 | DEL | exit(false) ->  | 95155, 95179, 95191 |
| 199 | 72918635 | IsSourceCommTypeSupportedByBank | 254 | DEL | exit(not BankSystemMapping2.IsEmpty()) ->  | 95155 |
| 201 | 72918635 | ResolveAccessibleSourceCompany | 271 | COND | TryGetSourceBank(PreferredCompany, SourceBankCode, SourceBank) -> false | 95155 |
| 202 | 72918635 | ResolveAccessibleSourceCompany | 272 | DEL | exit(PreferredCompany) ->  | 95155 |
| 203 | 72918635 | ResolveAccessibleSourceCompany | 275 | REL | (CurrentCompany <> PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank) -> (CurrentCompany = PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank) | 95155, 95179, 95191 |
| 204 | 72918635 | ResolveAccessibleSourceCompany | 275 | BOOL | (CurrentCompany <> PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank) -> (CurrentCompany <> PreferredCompany) or TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank) | 95155, 95179, 95191 |
| 205 | 72918635 | ResolveAccessibleSourceCompany | 275 | COND | (CurrentCompany <> PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank) -> true | 95155, 95179, 95191 |
| 206 | 72918635 | ResolveAccessibleSourceCompany | 275 | COND | (CurrentCompany <> PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank) -> false | 95155, 95179, 95191 |
| 207 | 72918635 | ResolveAccessibleSourceCompany | 276 | DEL | exit(CurrentCompany) ->  | 95155, 95179, 95191 |
| 208 | 72918635 | ResolveAccessibleSourceCompany | 278 | DEL | exit(PreferredCompany) ->  | 95155, 95179, 95191 |
| 209 | 72918635 | TryGetSourceBank | 295 | NOT | not SourceBank.Get(SourceBankCode) -> SourceBank.Get(SourceBankCode) | 95155 |
| 212 | 72918635 | TryGetSourceBank | 296 | DEL | Error(SourceBankUnreadableErr, SourceBankCode, SourceCompany) ->  | 95155, 95179, 95191 |
| 213 | 72918635 | EnsureTargetBankFromSource | 304 | NOT | not ToBank.WritePermission() -> ToBank.WritePermission() | 95155, 95179, 95191 |
| 214 | 72918635 | EnsureTargetBankFromSource | 304 | COND | not ToBank.WritePermission() -> true | 95155, 95179, 95191 |
| 215 | 72918635 | EnsureTargetBankFromSource | 304 | COND | not ToBank.WritePermission() -> false | 95155, 95179, 95191 |
| 216 | 72918635 | EnsureTargetBankFromSource | 305 | DEL | exit ->  | 95155, 95179, 95191 |
| 217 | 72918635 | EnsureTargetBankFromSource | 306 | COND | ToBank.Get(SourceBank.Code) -> true | 95155, 95179, 95191 |
| 218 | 72918635 | EnsureTargetBankFromSource | 306 | COND | ToBank.Get(SourceBank.Code) -> false | 95155, 95179, 95191 |
| 219 | 72918635 | EnsureTargetBankFromSource | 307 | DEL | exit ->  | 95155, 95179, 95191 |
| 220 | 72918635 | EnsureTargetBankFromSource | 309 | DEL | ToBank.Insert(true) ->  | 95155, 95179, 95191 |
| 221 | 72918635 | EnsureTargetBankFromSource | 309 | INSFLAG | ToBank.Insert(true) -> ToBank.Insert(false) | 95155, 95179, 95191 |
| 222 | 72918635 | AnnotatePlaceholderAsNotActivated | 319 | NOT | not TempAuthShareTarget.FindFirst() -> TempAuthShareTarget.FindFirst() | 95155, 95179, 95191 |
| 223 | 72918635 | AnnotatePlaceholderAsNotActivated | 319 | COND | not TempAuthShareTarget.FindFirst() -> true | 95155, 95179, 95191 |
| 224 | 72918635 | AnnotatePlaceholderAsNotActivated | 319 | COND | not TempAuthShareTarget.FindFirst() -> false | 95155, 95179, 95191 |
| 225 | 72918635 | AnnotatePlaceholderAsNotActivated | 321 | DEL | exit ->  | 95155, 95179, 95191 |
| 226 | 72918635 | AnnotatePlaceholderAsNotActivated | 327 | DEL | TempAuthShareTarget.Modify() ->  | 95155, 95179, 95191 |
| 227 | 72918635 | LinkBankAccountsToBank | 337 | NOT | not BankAccount.WritePermission() -> BankAccount.WritePermission() | 95155, 95179, 95191 |
| 228 | 72918635 | LinkBankAccountsToBank | 337 | COND | not BankAccount.WritePermission() -> true | 95155, 95179, 95191 |
| 229 | 72918635 | LinkBankAccountsToBank | 337 | COND | not BankAccount.WritePermission() -> false | 95155, 95179, 95191 |
| 230 | 72918635 | LinkBankAccountsToBank | 338 | DEL | exit ->  | 95155, 95179, 95191 |
| 231 | 72918635 | LinkBankAccountsToBank | 342 | DEL | BankAccount.Modify() ->  | 95155, 95179, 95191 |
| 232 | 72918635 | UpdatePlaceholderRows | 382 | COND | TempAuthShareTarget.FindLast() -> true | 95155 |
| 233 | 72918635 | UpdatePlaceholderRows | 382 | COND | TempAuthShareTarget.FindLast() -> false | 95155 |
| 249 | 72918635 | UpdatePlaceholderRows | 416 | COND | not TempAuthShareTarget.Get(PlaceholderLineNo) -> false | 95155 |
| 250 | 72918635 | UpdatePlaceholderRows | 418 | DEL | exit ->  | 95155, 95179, 95191 |
| 251 | 72918635 | UpdatePlaceholderRows | 424 | REL | TotalMatched > 0 -> TotalMatched >= 0 | 95155 |
| 252 | 72918635 | UpdatePlaceholderRows | 424 | COND | TotalMatched > 0 -> true | 95155 |
| 253 | 72918635 | UpdatePlaceholderRows | 424 | COND | TotalMatched > 0 -> false | 95155 |
| 256 | 72918635 | EmitDetectionFailedRow | 474 | REL | TotalAttempted > 0 -> TotalAttempted >= 0 | 95155 |
| 257 | 72918635 | EmitDetectionFailedRow | 474 | COND | TotalAttempted > 0 -> true | 95155 |
| 258 | 72918635 | EmitDetectionFailedRow | 474 | COND | TotalAttempted > 0 -> false | 95155 |
| 264 | 72918635 | EmitDetectionFailedRow | 480 | COND | not TempAuthShareTarget.Get(PlaceholderLineNo) -> false | 95155 |
| 265 | 72918635 | EmitDetectionFailedRow | 481 | DEL | exit ->  | 95155, 95179, 95191 |
| 270 | 72918635 | EmitSystemNotMappedRow | 538 | COND | SourceLocalBank.Get(ResolvedBankCode) -> true | 95155 |
| 271 | 72918635 | EmitSystemNotMappedRow | 538 | COND | SourceLocalBank.Get(ResolvedBankCode) -> false | 95155 |
| 277 | 72918635 | EmitSystemNotMappedRow | 547 | COND | not TempAuthShareTarget.Get(PlaceholderLineNo) -> false | 95155 |
| 278 | 72918635 | EmitSystemNotMappedRow | 548 | DEL | exit ->  | 95155, 95179, 95191 |
| 282 | 72918635 | NextLineNo | 583 | COND | TempAuthShareTarget.FindLast() -> true | 95155 |
| 285 | 72918635 | CountAccountsInDict | 598 | DEL | exit(Total) ->  | 95155 |
| 287 | 72918635 | DeleteStaleRegularRowForSameBank | 618 | REL | BankCode = '' -> BankCode <> '' | 95155 |
| 288 | 72918635 | DeleteStaleRegularRowForSameBank | 618 | COND | BankCode = '' -> true | 95155 |
| 289 | 72918635 | DeleteStaleRegularRowForSameBank | 618 | COND | BankCode = '' -> false | 95155 |
| 290 | 72918635 | DeleteStaleRegularRowForSameBank | 619 | DEL | exit ->  | 95155, 95179, 95191 |
| 291 | 72918635 | DeleteStaleRegularRowForSameBank | 624 | NOT | not TempAuthShareTarget.IsEmpty() -> TempAuthShareTarget.IsEmpty() | 95155 |
| 292 | 72918635 | DeleteStaleRegularRowForSameBank | 624 | COND | not TempAuthShareTarget.IsEmpty() -> true | 95155 |
| 293 | 72918635 | DeleteStaleRegularRowForSameBank | 624 | COND | not TempAuthShareTarget.IsEmpty() -> false | 95155 |
| 294 | 72918635 | DeleteStaleRegularRowForSameBank | 625 | DEL | TempAuthShareTarget.DeleteAll() ->  | 95155, 95179, 95191 |

## Timeouts

_None._

## Compile errors

_None._

## Uncovered

Uncovered: 0

