# Mutation run 8 summary

## Run

| Metric | Value |
| --- | --- |
| Run no | 8 |
| Backend | DemoPortal |
| Environment | mut-spike-02 |
| AUT version | 29.0.0.0 |
| Started (UTC) | 2026-09-21T23:00:56.8011336Z |
| Finished (UTC) | 2026-09-22T00:38:17.5325579Z |
| Wall clock | 01:37:20.7314243 |

## Totals

| Total | Killed | Survived | Timeout | Compile error | Uncovered | Equivalent | Error | Pending |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 265 | 92 | 127 | 0 | 0 | 0 | 0 | 46 | 0 |

## Score

Score: **0.4201**

## Survivors

| Id | Object | Procedure | Line | Operator | Original -> Mutated | Covering tests |
| --- | --- | --- | --- | --- | --- | --- |
| 140 | 72918635 | DetectInCompany | 69 | COND | not CoreMgt.IsAppActiveInCompany(TargetCompany) -> false | 95155 |
| 141 | 72918635 | DetectInCompany | 71 | DEL | exit ->  | 95155 |
| 145 | 72918635 | DetectInCompany | 76 | DEL | exit ->  | 95155 |
| 146 | 72918635 | DetectInCompany | 79 | REL | AuthenticationEntry."Originating Company" <> '' -> AuthenticationEntry."Originating Company" = '' | 95155 |
| 147 | 72918635 | DetectInCompany | 79 | COND | AuthenticationEntry."Originating Company" <> '' -> true | 95155 |
| 148 | 72918635 | DetectInCompany | 79 | COND | AuthenticationEntry."Originating Company" <> '' -> false | 95155 |
| 151 | 72918635 | DetectInCompany | 85 | COND | SourceBank.Code = '' -> false | 95155 |
| 152 | 72918635 | DetectInCompany | 86 | DEL | exit ->  | 95155 |
| 153 | 72918635 | DetectInCompany | 94 | COND | BankAccount.FindSet() -> true | 95155 |
| 157 | 72918635 | DetectInCompany | 113 | COND | MissingInfo -> true | 95155 |
| 158 | 72918635 | DetectInCompany | 113 | COND | MissingInfo -> false | 95155 |
| 159 | 72918635 | DetectInCompany | 120 | REL | MatchingAccounts.Count() > 0 -> MatchingAccounts.Count() >= 0 | 95155 |
| 160 | 72918635 | DetectInCompany | 120 | COND | MatchingAccounts.Count() > 0 -> true | 95155 |
| 161 | 72918635 | DetectInCompany | 120 | COND | MatchingAccounts.Count() > 0 -> false | 95155 |
| 162 | 72918635 | EmitShareDetectionRan | 153 | REL | AccountsAttempted = 0 -> AccountsAttempted <> 0 | 95155 |
| 163 | 72918635 | EmitShareDetectionRan | 153 | COND | AccountsAttempted = 0 -> true | 95155 |
| 164 | 72918635 | EmitShareDetectionRan | 153 | COND | AccountsAttempted = 0 -> false | 95155 |
| 165 | 72918635 | EmitShareDetectionRan | 154 | DEL | exit ->  | 95155 |
| 168 | 72918635 | AppendAccountForBank | 177 | COND | BankCode = '' -> false | 95155 |
| 169 | 72918635 | AppendAccountForBank | 178 | DEL | exit ->  | 95155 |
| 171 | 72918635 | AppendAccountForBank | 179 | COND | ResolvedOtherAccountsByBank.ContainsKey(BankCode) -> false | 95155 |
| 173 | 72918635 | ResolveBankCodeForAccount | 204 | REL | (BankAccount.IBAN = '') and (BankAccount."Bank Branch No." = '') -> (BankAccount.IBAN = '') and (BankAccount."Bank Branch No." <> '') | 95155 |
| 176 | 72918635 | ResolveBankCodeForAccount | 204 | COND | (BankAccount.IBAN = '') and (BankAccount."Bank Branch No." = '') -> false | 95155 |
| 177 | 72918635 | ResolveBankCodeForAccount | 206 | DEL | exit(false) ->  | 95155 |
| 181 | 72918635 | ResolveBankCodeForAccount | 210 | DEL | exit(false) ->  | 95155 |
| 183 | 72918635 | ResolveBankCodeForAccount | 212 | COND | TempBank.Code <> '' -> true | 95155 |
| 186 | 72918635 | IsSourceSystemMappedToBank | 232 | REL | (BankCode = '') or (SourceBankSystemCode = '') -> (BankCode <> '') or (SourceBankSystemCode = '') | 95155 |
| 187 | 72918635 | IsSourceSystemMappedToBank | 232 | REL | (BankCode = '') or (SourceBankSystemCode = '') -> (BankCode = '') or (SourceBankSystemCode <> '') | 95155 |
| 188 | 72918635 | IsSourceSystemMappedToBank | 232 | BOOL | (BankCode = '') or (SourceBankSystemCode = '') -> (BankCode = '') and (SourceBankSystemCode = '') | 95155 |
| 189 | 72918635 | IsSourceSystemMappedToBank | 232 | COND | (BankCode = '') or (SourceBankSystemCode = '') -> true | 95155 |
| 190 | 72918635 | IsSourceSystemMappedToBank | 232 | COND | (BankCode = '') or (SourceBankSystemCode = '') -> false | 95155 |
| 191 | 72918635 | IsSourceSystemMappedToBank | 233 | DEL | exit(false) ->  | 95155 |
| 192 | 72918635 | IsSourceSystemMappedToBank | 236 | DEL | exit(not BankSystemMapping2.IsEmpty()) ->  | 95155 |
| 193 | 72918635 | IsSourceCommTypeSupportedByBank | 249 | REL | (BankCode = '') or (SourceBankSystemCode = '') -> (BankCode <> '') or (SourceBankSystemCode = '') | 95155 |
| 194 | 72918635 | IsSourceCommTypeSupportedByBank | 249 | REL | (BankCode = '') or (SourceBankSystemCode = '') -> (BankCode = '') or (SourceBankSystemCode <> '') | 95155 |
| 195 | 72918635 | IsSourceCommTypeSupportedByBank | 249 | BOOL | (BankCode = '') or (SourceBankSystemCode = '') -> (BankCode = '') and (SourceBankSystemCode = '') | 95155 |
| 196 | 72918635 | IsSourceCommTypeSupportedByBank | 249 | COND | (BankCode = '') or (SourceBankSystemCode = '') -> true | 95155 |
| 197 | 72918635 | IsSourceCommTypeSupportedByBank | 249 | COND | (BankCode = '') or (SourceBankSystemCode = '') -> false | 95155 |
| 198 | 72918635 | IsSourceCommTypeSupportedByBank | 250 | DEL | exit(false) ->  | 95155 |
| 199 | 72918635 | IsSourceCommTypeSupportedByBank | 254 | DEL | exit(not BankSystemMapping2.IsEmpty()) ->  | 95155 |
| 201 | 72918635 | ResolveAccessibleSourceCompany | 271 | COND | TryGetSourceBank(PreferredCompany, SourceBankCode, SourceBank) -> false | 95155 |
| 202 | 72918635 | ResolveAccessibleSourceCompany | 272 | DEL | exit(PreferredCompany) ->  | 95155 |
| 203 | 72918635 | ResolveAccessibleSourceCompany | 275 | REL | (CurrentCompany <> PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank) -> (CurrentCompany = PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank) | 95155 |
| 204 | 72918635 | ResolveAccessibleSourceCompany | 275 | BOOL | (CurrentCompany <> PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank) -> (CurrentCompany <> PreferredCompany) or TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank) | 95155 |
| 205 | 72918635 | ResolveAccessibleSourceCompany | 275 | COND | (CurrentCompany <> PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank) -> true | 95155 |
| 206 | 72918635 | ResolveAccessibleSourceCompany | 275 | COND | (CurrentCompany <> PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank) -> false | 95155 |
| 207 | 72918635 | ResolveAccessibleSourceCompany | 276 | DEL | exit(CurrentCompany) ->  | 95155 |
| 208 | 72918635 | ResolveAccessibleSourceCompany | 278 | DEL | exit(PreferredCompany) ->  | 95155 |
| 209 | 72918635 | TryGetSourceBank | 295 | NOT | not SourceBank.Get(SourceBankCode) -> SourceBank.Get(SourceBankCode) | 95155 |
| 212 | 72918635 | TryGetSourceBank | 296 | DEL | Error(SourceBankUnreadableErr, SourceBankCode, SourceCompany) ->  | 95155 |
| 213 | 72918635 | EnsureTargetBankFromSource | 304 | NOT | not ToBank.WritePermission() -> ToBank.WritePermission() | 95155 |
| 214 | 72918635 | EnsureTargetBankFromSource | 304 | COND | not ToBank.WritePermission() -> true | 95155 |
| 215 | 72918635 | EnsureTargetBankFromSource | 304 | COND | not ToBank.WritePermission() -> false | 95155 |
| 216 | 72918635 | EnsureTargetBankFromSource | 305 | DEL | exit ->  | 95155 |
| 217 | 72918635 | EnsureTargetBankFromSource | 306 | COND | ToBank.Get(SourceBank.Code) -> true | 95155 |
| 218 | 72918635 | EnsureTargetBankFromSource | 306 | COND | ToBank.Get(SourceBank.Code) -> false | 95155 |
| 219 | 72918635 | EnsureTargetBankFromSource | 307 | DEL | exit ->  | 95155 |
| 220 | 72918635 | EnsureTargetBankFromSource | 309 | DEL | ToBank.Insert(true) ->  | 95155 |
| 221 | 72918635 | EnsureTargetBankFromSource | 309 | INSFLAG | ToBank.Insert(true) -> ToBank.Insert(false) | 95155 |
| 222 | 72918635 | AnnotatePlaceholderAsNotActivated | 319 | NOT | not TempAuthShareTarget.FindFirst() -> TempAuthShareTarget.FindFirst() | 95155 |
| 223 | 72918635 | AnnotatePlaceholderAsNotActivated | 319 | COND | not TempAuthShareTarget.FindFirst() -> true | 95155 |
| 224 | 72918635 | AnnotatePlaceholderAsNotActivated | 319 | COND | not TempAuthShareTarget.FindFirst() -> false | 95155 |
| 225 | 72918635 | AnnotatePlaceholderAsNotActivated | 321 | DEL | exit ->  | 95155 |
| 226 | 72918635 | AnnotatePlaceholderAsNotActivated | 327 | DEL | TempAuthShareTarget.Modify() ->  | 95155 |
| 227 | 72918635 | LinkBankAccountsToBank | 337 | NOT | not BankAccount.WritePermission() -> BankAccount.WritePermission() | 95155 |
| 228 | 72918635 | LinkBankAccountsToBank | 337 | COND | not BankAccount.WritePermission() -> true | 95155 |
| 229 | 72918635 | LinkBankAccountsToBank | 337 | COND | not BankAccount.WritePermission() -> false | 95155 |
| 230 | 72918635 | LinkBankAccountsToBank | 338 | DEL | exit ->  | 95155 |
| 231 | 72918635 | LinkBankAccountsToBank | 342 | DEL | BankAccount.Modify() ->  | 95155 |
| 232 | 72918635 | UpdatePlaceholderRows | 382 | COND | TempAuthShareTarget.FindLast() -> true | 95155 |
| 233 | 72918635 | UpdatePlaceholderRows | 382 | COND | TempAuthShareTarget.FindLast() -> false | 95155 |
| 249 | 72918635 | UpdatePlaceholderRows | 416 | COND | not TempAuthShareTarget.Get(PlaceholderLineNo) -> false | 95155 |
| 250 | 72918635 | UpdatePlaceholderRows | 418 | DEL | exit ->  | 95155 |
| 251 | 72918635 | UpdatePlaceholderRows | 424 | REL | TotalMatched > 0 -> TotalMatched >= 0 | 95155 |
| 252 | 72918635 | UpdatePlaceholderRows | 424 | COND | TotalMatched > 0 -> true | 95155 |
| 253 | 72918635 | UpdatePlaceholderRows | 424 | COND | TotalMatched > 0 -> false | 95155 |
| 256 | 72918635 | EmitDetectionFailedRow | 474 | REL | TotalAttempted > 0 -> TotalAttempted >= 0 | 95155 |
| 257 | 72918635 | EmitDetectionFailedRow | 474 | COND | TotalAttempted > 0 -> true | 95155 |
| 258 | 72918635 | EmitDetectionFailedRow | 474 | COND | TotalAttempted > 0 -> false | 95155 |
| 264 | 72918635 | EmitDetectionFailedRow | 480 | COND | not TempAuthShareTarget.Get(PlaceholderLineNo) -> false | 95155 |
| 265 | 72918635 | EmitDetectionFailedRow | 481 | DEL | exit ->  | 95155 |
| 270 | 72918635 | EmitSystemNotMappedRow | 538 | COND | SourceLocalBank.Get(ResolvedBankCode) -> true | 95155 |
| 271 | 72918635 | EmitSystemNotMappedRow | 538 | COND | SourceLocalBank.Get(ResolvedBankCode) -> false | 95155 |
| 277 | 72918635 | EmitSystemNotMappedRow | 547 | COND | not TempAuthShareTarget.Get(PlaceholderLineNo) -> false | 95155 |
| 278 | 72918635 | EmitSystemNotMappedRow | 548 | DEL | exit ->  | 95155 |
| 282 | 72918635 | NextLineNo | 583 | COND | TempAuthShareTarget.FindLast() -> true | 95155 |
| 285 | 72918635 | CountAccountsInDict | 598 | DEL | exit(Total) ->  | 95155 |
| 287 | 72918635 | DeleteStaleRegularRowForSameBank | 618 | REL | BankCode = '' -> BankCode <> '' | 95155 |
| 288 | 72918635 | DeleteStaleRegularRowForSameBank | 618 | COND | BankCode = '' -> true | 95155 |
| 289 | 72918635 | DeleteStaleRegularRowForSameBank | 618 | COND | BankCode = '' -> false | 95155 |
| 290 | 72918635 | DeleteStaleRegularRowForSameBank | 619 | DEL | exit ->  | 95155 |
| 291 | 72918635 | DeleteStaleRegularRowForSameBank | 624 | NOT | not TempAuthShareTarget.IsEmpty() -> TempAuthShareTarget.IsEmpty() | 95155 |
| 292 | 72918635 | DeleteStaleRegularRowForSameBank | 624 | COND | not TempAuthShareTarget.IsEmpty() -> true | 95155 |
| 293 | 72918635 | DeleteStaleRegularRowForSameBank | 624 | COND | not TempAuthShareTarget.IsEmpty() -> false | 95155 |
| 294 | 72918635 | DeleteStaleRegularRowForSameBank | 625 | DEL | TempAuthShareTarget.DeleteAll() ->  | 95155 |
| 1865 | 72282417 | CopyPaymentMethodsFromBankSystem | 19 | COND | BankAccComSetup."System Type" <> BankAccComSetup."System Type"::BankSystem -> false | 95110 |
| 1866 | 72282417 | CopyPaymentMethodsFromBankSystem | 20 | DEL | exit ->  | 95110 |
| 1869 | 72282417 | CopyPaymentMethodsFromBankSystem | 22 | COND | not PaymentMthValidator.ShouldUsePaymentMethodMappings(BankAccComSetup."Transaction Type") -> false | 95110 |
| 1870 | 72282417 | CopyPaymentMethodsFromBankSystem | 23 | DEL | exit ->  | 95110 |
| 1871 | 72282417 | CopyPaymentMethodsFromBankSystem | 29 | COND | BankSystemPmtMth.FindSet() -> true | 95110 |
| 1875 | 72282417 | CopyPaymentMethodsFromBankSystem | 33 | COND | TransactionType = TransactionType::" " -> false | 95110 |
| 1877 | 72282417 | CopyPaymentMethodsFromBankSystem | 36 | COND | TransactionType = BankAccComSetup."Transaction Type" -> true | 95110 |
| 1881 | 72282417 | PropagatePaymentMethodToMappings | 51 | COND | TargetPaymentMethod."CTS-CB Payment Method Code" = '' -> false | 95110 |
| 1882 | 72282417 | PropagatePaymentMethodToMappings | 52 | DEL | exit ->  | 95110 |
| 1886 | 72282417 | PropagatePaymentMethodToMappings | 57 | DEL | exit ->  | 95110 |
| 1889 | 72282417 | PropagatePaymentMethodToMappings | 61 | COND | not ExistingBankSysPmtMthMap.FindSet() -> false | 95110 |
| 1890 | 72282417 | PropagatePaymentMethodToMappings | 62 | DEL | exit ->  | 95110 |
| 1891 | 72282417 | PopulatePaymentMethodsWithConflictCheck | 84 | NOT | not PaymentMthValidator.ShouldUsePaymentMethodMappings(BankAccComSetup."Transaction Type") -> PaymentMthValidator.ShouldUsePaymentMethodMappings(BankAccComSetup."Transaction Type") | 95110 |
| 1892 | 72282417 | PopulatePaymentMethodsWithConflictCheck | 84 | COND | not PaymentMthValidator.ShouldUsePaymentMethodMappings(BankAccComSetup."Transaction Type") -> true | 95110 |
| 1893 | 72282417 | PopulatePaymentMethodsWithConflictCheck | 84 | COND | not PaymentMthValidator.ShouldUsePaymentMethodMappings(BankAccComSetup."Transaction Type") -> false | 95110 |
| 1894 | 72282417 | PopulatePaymentMethodsWithConflictCheck | 85 | DEL | exit ->  | 95110 |
| 1895 | 72282417 | PopulatePaymentMethodsWithConflictCheck | 87 | NOT | not SkipConflictCheck -> SkipConflictCheck | 95110 |
| 1896 | 72282417 | PopulatePaymentMethodsWithConflictCheck | 87 | COND | not SkipConflictCheck -> true | 95110 |
| 1897 | 72282417 | PopulatePaymentMethodsWithConflictCheck | 87 | COND | not SkipConflictCheck -> false | 95110 |
| 1898 | 72282417 | PopulatePaymentMethodsWithConflictCheck | 88 | DEL | exit ->  | 95110 |
| 1900 | 72282417 | DeleteMappings | 103 | COND | not BankSysPmtMthMap.IsEmpty() -> true | 95110 |
| 1903 | 72282417 | CleanupExceptSystem | 117 | NOT | not BankSysPmtMthMap.IsEmpty() -> BankSysPmtMthMap.IsEmpty() | 95110 |
| 1904 | 72282417 | CleanupExceptSystem | 117 | COND | not BankSysPmtMthMap.IsEmpty() -> true | 95110 |
| 1905 | 72282417 | CleanupExceptSystem | 117 | COND | not BankSysPmtMthMap.IsEmpty() -> false | 95110 |
| 1906 | 72282417 | CleanupExceptSystem | 118 | DEL | BankSysPmtMthMap.DeleteAll() ->  | 95110 |
| 1909 | 72282417 | CreateMappingsForBankSystemPaymentMethod | 139 | COND | PaymentMethod.FindSet() -> true | 95110 |
| 1911 | 72282417 | CreateMappingsForBankSystemPaymentMethod | 145 | DEL | exit ->  | 95110 |
| 1913 | 72282417 | InsertMappingIfNotExists | 174 | COND | ShortPaymentMethodCode <> '' -> true | 95110 |
| 1920 | 72282417 | InsertMappingIfNotExists | 187 | INSFLAG | BankSysPmtMthMap.Insert(true) -> BankSysPmtMthMap.Insert(false) | 95110 |
| 4367 | 72918630 | BuildBatchDisplay | 31 | DEL | TempIntBatchDisplay.DeleteAll() ->  | 95121 |
| 4369 | 72918630 | BuildBatchDisplay | 33 | COND | TempPaymentEntry.IsEmpty() -> false | 95121 |
| 4370 | 72918630 | BuildBatchDisplay | 34 | DEL | exit ->  | 95121 |

## Timeouts

_None._

## Compile errors

_None._

## Errors

| Id | Object | Procedure | Line | Operator | Reason |
| --- | --- | --- | --- | --- | --- |
| 4371 | 72918630 | BuildBatchDisplay | 40 | DEL | no tests discovered |
| 4372 | 72918630 | BuildBatchDisplay | 44 | COND | no tests discovered |
| 4373 | 72918630 | BuildBatchDisplay | 44 | COND | no tests discovered |
| 4374 | 72918630 | BuildBatchDisplay | 45 | DEL | no tests discovered |
| 4375 | 72918630 | GetPaymentEntriesForBatch | 68 | DEL | no tests discovered |
| 4376 | 72918630 | GetPaymentEntriesForBatch | 72 | REL | no tests discovered |
| 4377 | 72918630 | GetPaymentEntriesForBatch | 72 | COND | no tests discovered |
| 4378 | 72918630 | GetPaymentEntriesForBatch | 72 | COND | no tests discovered |
| 4379 | 72918630 | GetPaymentEntriesForBatch | 73 | DEL | no tests discovered |
| 4380 | 72918630 | GetPaymentEntriesForBatch | 80 | NOT | no tests discovered |
| 4381 | 72918630 | GetPaymentEntriesForBatch | 80 | COND | no tests discovered |
| 4382 | 72918630 | GetPaymentEntriesForBatch | 80 | COND | no tests discovered |
| 4383 | 72918630 | GetPaymentEntriesForBatch | 81 | DEL | no tests discovered |
| 4384 | 72918630 | GetPaymentEntriesForBatch | 85 | COND | no tests discovered |
| 4385 | 72918630 | GetPaymentEntriesForBatch | 85 | COND | no tests discovered |
| 4386 | 72918630 | GetPaymentEntriesForBatch | 87 | DEL | no tests discovered |
| 4387 | 72918630 | CreateDisplayRecordsForBatch | 111 | COND | no tests discovered |
| 4388 | 72918630 | CreateDisplayRecordsForBatch | 111 | COND | no tests discovered |
| 4389 | 72918630 | CreateHeaderRecord | 129 | REL | no tests discovered |
| 4390 | 72918630 | CreateHeaderRecord | 129 | COND | no tests discovered |
| 4391 | 72918630 | CreateHeaderRecord | 129 | COND | no tests discovered |
| 4392 | 72918630 | CreateHeaderRecord | 136 | COND | Cannot convert value "127851265729564" to type "System.Int32". Error: "Værdien var enten for stor eller for lille til en Int32." |
| 4393 | 72918630 | CreateHeaderRecord | 136 | COND | no tests discovered |
| 4394 | 72918630 | CreateHeaderRecord | 145 | REL | no tests discovered |
| 4395 | 72918630 | CreateHeaderRecord | 145 | COND | no tests discovered |
| 4396 | 72918630 | CreateHeaderRecord | 145 | COND | no tests discovered |
| 4397 | 72918630 | CreateHeaderRecord | 150 | DEL | no tests discovered |
| 4398 | 72918630 | CreateHeaderRecord | 151 | DEL | no tests discovered |
| 4399 | 72918630 | CreateLineRecord | 175 | DEL | no tests discovered |
| 4400 | 72918630 | GetSinglePaymentDescription | 180 | COND | no tests discovered |
| 4401 | 72918630 | GetSinglePaymentDescription | 180 | COND | Cannot convert value "191776901137493" to type "System.Int32". Error: "Værdien var enten for stor eller for lille til en Int32." |
| 4402 | 72918630 | GetSinglePaymentDescription | 181 | DEL | no tests discovered |
| 4403 | 72918630 | GetBulkPaymentDescription | 188 | DEL | Fjernserveren returnerede en fejl: (502) Forkert gateway. |
| 15013 | 71553757 | GetValidationLevel | 9 | DEL | Fjernserveren returnerede en fejl: (502) Forkert gateway. |
| 15014 | 71553757 | GetValidationLevel | 11 | DEL | Fjernserveren returnerede en fejl: (502) Forkert gateway. |
| 15015 | 71553757 | GetValidationLevel | 13 | DEL | Fjernserveren returnerede en fejl: (502) Forkert gateway. |
| 15016 | 71553757 | GetValidationLevel | 15 | DEL | Fjernserveren returnerede en fejl: (502) Forkert gateway. |
| 15017 | 71553757 | GetValidationLevel | 24 | DEL | Fjernserveren returnerede en fejl: (502) Forkert gateway. |
| 15018 | 71553757 | GetBankSystemCodeByLevel | 29 | COND | Fjernserveren returnerede en fejl: (502) Forkert gateway. |
| 15019 | 71553757 | GetBankSystemCodeByLevel | 29 | COND | Fjernserveren returnerede en fejl: (502) Forkert gateway. |
| 15020 | 71553757 | GetBankSystemCodeByLevel | 30 | DEL | Fjernserveren returnerede en fejl: (502) Forkert gateway. |
| 15021 | 71553757 | GetBankSystemCodeByLevel | 39 | DEL | Fjernserveren returnerede en fejl: (502) Forkert gateway. |
| 15022 | 71553757 | GetPaymentMethodCodeByLevel | 44 | COND | Fjernserveren returnerede en fejl: (502) Forkert gateway. |
| 15023 | 71553757 | GetPaymentMethodCodeByLevel | 44 | COND | Fjernserveren returnerede en fejl: (502) Forkert gateway. |
| 15024 | 71553757 | GetPaymentMethodCodeByLevel | 45 | DEL | Fjernserveren returnerede en fejl: (502) Forkert gateway. |
| 15025 | 71553757 | GetPaymentMethodCodeByLevel | 54 | DEL | Fjernserveren returnerede en fejl: (502) Forkert gateway. |

## Uncovered

Uncovered: 0
