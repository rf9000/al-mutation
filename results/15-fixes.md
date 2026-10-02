# Fix suggestions for run 15

- Run: 15
- Survivors: 146
- Fix entries: 65
- Verdicts: fix 4, new-test 42, equivalent 19
- Confidence: high 32, medium 25, low 8

## Test codeunit 95058 CTS-CB Val. Level Mgt. UT

File: Export/Payment Validation/ValLevelMgtUT.Codeunit.al

### F063

- Mutants:
  - 16474: `FieldContent.Level in [1, 2]` -> `true` (Validation/Codeunits/ValidationLevelMgt.Codeunit.al:29)
- Verdict: new-test
- Change: new-test
- Target procedure: TestGetBankSystemCodeByLevel_Level3_ReturnsEmpty
- Confidence: high
- Rationale: Line 29 (Level in [1, 2]) is only tested with Level 1, where the original and a constant-true condition both return the code. There is no test for GetBankSystemCodeByLevel with a level outside [1, 2] (the payment-method counterpart has a Level 2 test).
- Expected effect: Fails on mutant 16474 because the condition is always true and the bank system code is returned for level 3; passes on the original because level 3 is outside [1, 2] and the function returns the empty default.

```al
    [Test]
    procedure TestGetBankSystemCodeByLevel_Level3_ReturnsEmpty()
    var
        TempFieldContent: Record "CTS-CB Field Content" temporary;
        BankSystemCode: Code[30];
    begin
        // [GIVEN] Field content with level 3 and a bank system code
        TempFieldContent.Level := 3;
        BankSystemCode := CopyStr(LibraryRandom.RandText(10), 1, MaxStrLen(BankSystemCode));
        TempFieldContent."Bank System Code" := BankSystemCode;

        // [WHEN] Get bank system code by level
        // [THEN] Should return empty
        LibraryAssert.AreEqual('', ValidationLevelMgt.GetBankSystemCodeByLevel(TempFieldContent), 'Bank system code should be empty for level 3');
    end;
```

### F064

- Mutants:
  - 16477: `exit(GetBankSystemCodeByLevel(TempFieldContent))` -> `` (Validation/Codeunits/ValidationLevelMgt.Codeunit.al:39)
- Verdict: new-test
- Change: new-test
- Target procedure: TestGetBankSystemCodeByLevel_LevelAndCodeOverload_Level1_ReturnsCode
- Confidence: high
- Rationale: Line 39 (exit(GetBankSystemCodeByLevel(TempFieldContent)) in the (Level, BankSystemCode) overload). The test codeunit only calls the record-based overload, so this overload is never executed.
- Expected effect: Fails on mutant 16477 because the overload no longer returns the delegated result and yields the empty default; passes on the original, which returns the bank system code for level 1.

```al
    [Test]
    procedure TestGetBankSystemCodeByLevel_LevelAndCodeOverload_Level1_ReturnsCode()
    var
        BankSystemCode: Code[30];
    begin
        // [GIVEN] A bank system code
        BankSystemCode := CopyStr(LibraryRandom.RandText(10), 1, MaxStrLen(BankSystemCode));

        // [WHEN] Get bank system code by level using the (Level, BankSystemCode) overload
        // [THEN] Should return the code for level 1
        LibraryAssert.AreEqual(BankSystemCode, ValidationLevelMgt.GetBankSystemCodeByLevel(1, BankSystemCode), 'Bank system code should be returned for level 1');
    end;
```

### F065

- Mutants:
  - 16481: `exit(GetPaymentMethodCodeByLevel(TempFieldContent))` -> `` (Validation/Codeunits/ValidationLevelMgt.Codeunit.al:54)
- Verdict: new-test
- Change: new-test
- Target procedure: TestGetPaymentMethodCodeByLevel_LevelAndCodeOverload_Level1_ReturnsCode
- Confidence: high
- Rationale: Line 54 (exit(GetPaymentMethodCodeByLevel(TempFieldContent)) in the (Level, PaymentMethod) overload). The test codeunit only calls the record-based overload, so this overload is never executed.
- Expected effect: Fails on mutant 16481 because the overload no longer returns the delegated result and yields the empty default; passes on the original, which returns the payment method code for level 1.

```al
    [Test]
    procedure TestGetPaymentMethodCodeByLevel_LevelAndCodeOverload_Level1_ReturnsCode()
    var
        PaymentMethodCode: Code[20];
    begin
        // [GIVEN] A payment method code
        PaymentMethodCode := CopyStr(LibraryRandom.RandText(10), 1, MaxStrLen(PaymentMethodCode));

        // [WHEN] Get payment method code by level using the (Level, PaymentMethod) overload
        // [THEN] Should return the code for level 1
        LibraryAssert.AreEqual(PaymentMethodCode, ValidationLevelMgt.GetPaymentMethodCodeByLevel(1, PaymentMethodCode), 'Payment method code should be returned for level 1');
    end;
```

## Test codeunit 95110 CTS-CB Bank Sys Pmt Map Tests

File: Bank Account/BankSysPmtMapTests.Codeunit.al

### F038

- Mutants:
  - 1873: `BankAccComSetup."System Type" <> BankAccComSetup."System Type"::BankSystem` -> `false` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:19)
  - 1874: `exit` -> `` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:20)
- Verdict: new-test
- Change: new-test
- Target procedure: TestCopyPaymentMethodsFromBankSystem_NonBankSystemType_CreatesNoMappings
- Confidence: high
- Rationale: Line 19 (`System Type <> BankSystem`, then `exit` on line 20) is never true in 95110: every test copies for a BankSystem setup, so forcing the condition false or deleting the exit changes nothing the tests can see.
- Expected effect: Fails on mutants 1873/1874 because the early exit is skipped for the CSV Port setup, the bank system's payment method is found and a mapping row is inserted for the bank account, so the IsEmpty assertion fails; passes on the original because the procedure exits at line 20 and no mapping is created.

```al
    [Test]
    procedure TestCopyPaymentMethodsFromBankSystem_NonBankSystemType_CreatesNoMappings()
    var
        BankAccount: Record "Bank Account";
        BankAccComSetup: Record "CTS-CB Bank Acc. Com. Setup";
        BankSysPmtMthMap: Record "CTS-CB Bank Sys. Pmt. Mth. Map";
        BankSystem: Record "CTS-CB Bank System";
        BankSystemPmtMth: Record "CTS-CB Bank System Pmt. Mth.";
        PaymentMethod: Record "Payment Method";
        PaymentMethodMapper: Codeunit "CTS-CB Payment Method Mapper";
    begin
        DeleteTables();
        // [SCENARIO] Payment methods are only copied for setups whose System Type is BankSystem

        // [GIVEN] A bank system with a payment method, and a CSV Port setup that uses the same code
        CreateBankAccount(BankAccount);
        CreateBankSystem(BankSystem);
        CreatePaymentMethod(PaymentMethod);
        CreateBankSystemPaymentMethod(BankSystemPmtMth, BankSystem.Code, PaymentMethod.Code);
        BankAccComSetup.Init();
        BankAccComSetup.Code := BankAccount."No.";
        BankAccComSetup."System Type" := BankAccComSetup."System Type"::"CSV Port";
        BankAccComSetup."System Type Code" := BankSystem.Code;
        BankAccComSetup."Transaction Type" := BankAccComSetup."Transaction Type"::Payment;
        BankAccComSetup."File Type" := BankAccComSetup."File Type"::BankFormat;

        // [WHEN] Copying payment methods from bank system
        PaymentMethodMapper.CopyPaymentMethodsFromBankSystem(BankAccComSetup);

        // [THEN] No mapping is created because the setup is not a BankSystem setup
        BankSysPmtMthMap.SetRange("Bank Account No.", BankAccount."No.");
        Assert.IsTrue(BankSysPmtMthMap.IsEmpty(), 'No mappings should be created for a setup whose System Type is not BankSystem');

        // Cleanup
        CleanupTestData(BankAccount, BankSystem, PaymentMethod);
    end;
```

### F039

- Mutants:
  - 1877: `not PaymentMthValidator.ShouldUsePaymentMethodMappings(BankAccComSetup."Transaction Type")` -> `false` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:22)
  - 1878: `exit` -> `` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:23)
- Verdict: new-test
- Change: new-test
- Target procedure: TestCopyPaymentMethodsFromBankSystem_NonPaymentTransactionType_CreatesNoMappings
- Confidence: high
- Rationale: Line 22 (`not ShouldUsePaymentMethodMappings(...)`, then `exit` on line 23) is never true in 95110: every Copy call uses a Payment or Direct Debit setup. The payment method here has no CTS-CB record, so without the guard the loop falls back to the setup's transaction type and would create a mapping.
- Expected effect: Fails on mutants 1877/1878 because without the guard the unknown payment method takes the setup's Account Statement type, passes the line 36 check and a mapping is inserted; passes on the original because the procedure exits at line 23 before touching the payment methods.

```al
    [Test]
    procedure TestCopyPaymentMethodsFromBankSystem_NonPaymentTransactionType_CreatesNoMappings()
    var
        BankAccount: Record "Bank Account";
        BankAccComSetup: Record "CTS-CB Bank Acc. Com. Setup";
        BankSysPmtMthMap: Record "CTS-CB Bank Sys. Pmt. Mth. Map";
        BankSystem: Record "CTS-CB Bank System";
        BankSystemPmtMth: Record "CTS-CB Bank System Pmt. Mth.";
        PaymentMethod: Record "Payment Method";
        PaymentMethodMapper: Codeunit "CTS-CB Payment Method Mapper";
    begin
        DeleteTables();
        // [SCENARIO] Payment methods are only copied for Payment and Direct Debit transaction types

        // [GIVEN] A bank system payment method that has no CTS-CB Payment Method, and an Account Statement setup
        CreateBankAccount(BankAccount);
        CreateBankSystem(BankSystem);
        CreatePaymentMethod(PaymentMethod);
        CreateBankSystemPaymentMethod(BankSystemPmtMth, BankSystem.Code, PaymentMethod.Code);
        BankAccComSetup.Init();
        BankAccComSetup.Code := BankAccount."No.";
        BankAccComSetup."System Type" := BankAccComSetup."System Type"::BankSystem;
        BankAccComSetup."System Type Code" := BankSystem.Code;
        BankAccComSetup."Transaction Type" := BankAccComSetup."Transaction Type"::"Account Statement";
        BankAccComSetup."File Type" := BankAccComSetup."File Type"::BankFormat;

        // [WHEN] Copying payment methods from bank system
        PaymentMethodMapper.CopyPaymentMethodsFromBankSystem(BankAccComSetup);

        // [THEN] No mapping is created because Account Statement does not use payment method mappings
        BankSysPmtMthMap.SetRange("Bank Account No.", BankAccount."No.");
        Assert.IsTrue(BankSysPmtMthMap.IsEmpty(), 'No mappings should be created for an Account Statement setup');

        // Cleanup
        CleanupTestData(BankAccount, BankSystem, PaymentMethod);
    end;
```

### F040

- Mutants:
  - 1879: `BankSystemPmtMth.FindSet()` -> `true` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:29)
- Verdict: new-test
- Change: new-test
- Target procedure: TestCopyPaymentMethodsFromBankSystem_NoBankSystemPaymentMethods_CreatesNoMappings
- Confidence: medium
- Rationale: Line 29 (`BankSystemPmtMth.FindSet()`) is always true in 95110 because every Copy test gives the bank system at least one payment method; the empty case is never exercised.
- Expected effect: Fails on mutant 1879 because the loop body runs once on a blank record and inserts a mapping row with a blank Payment Method Code for the bank account; passes on the original because FindSet returns false and nothing is inserted. CleanupTestData is called with the never-inserted PaymentMethod variable, which is harmless (Get fails).

```al
    [Test]
    procedure TestCopyPaymentMethodsFromBankSystem_NoBankSystemPaymentMethods_CreatesNoMappings()
    var
        BankAccount: Record "Bank Account";
        BankAccComSetup: Record "CTS-CB Bank Acc. Com. Setup";
        BankSysPmtMthMap: Record "CTS-CB Bank Sys. Pmt. Mth. Map";
        BankSystem: Record "CTS-CB Bank System";
        PaymentMethod: Record "Payment Method";
        PaymentMethodMapper: Codeunit "CTS-CB Payment Method Mapper";
    begin
        DeleteTables();
        // [SCENARIO] Nothing is mapped when the bank system has no payment methods

        // [GIVEN] A bank system without any payment methods and a Payment setup for it
        CreateBankAccount(BankAccount);
        CreateBankSystem(BankSystem);
        BankAccComSetup.Init();
        BankAccComSetup.Code := BankAccount."No.";
        BankAccComSetup."System Type" := BankAccComSetup."System Type"::BankSystem;
        BankAccComSetup."System Type Code" := BankSystem.Code;
        BankAccComSetup."Transaction Type" := BankAccComSetup."Transaction Type"::Payment;
        BankAccComSetup."File Type" := BankAccComSetup."File Type"::BankFormat;

        // [WHEN] Copying payment methods from bank system
        PaymentMethodMapper.CopyPaymentMethodsFromBankSystem(BankAccComSetup);

        // [THEN] No mapping is created
        BankSysPmtMthMap.SetRange("Bank Account No.", BankAccount."No.");
        Assert.IsTrue(BankSysPmtMthMap.IsEmpty(), 'No mappings should be created when the bank system has no payment methods');

        // Cleanup
        CleanupTestData(BankAccount, BankSystem, PaymentMethod);
    end;
```

### F041

- Mutants:
  - 1883: `TransactionType = TransactionType::" "` -> `false` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:33)
- Verdict: new-test
- Change: new-test
- Target procedure: TestCopyPaymentMethodsFromBankSystem_UnknownPaymentMethod_UsesSetupTransactionType
- Confidence: high
- Rationale: Line 33 (`TransactionType = " "`) is true in TestDuplicatePaymentMethodValidation (payment method without a CTS-CB record), but that test only compares the mapping count before and after a second copy, so 0 = 0 passes on the mutant. No test asserts that a mapping exists for such a payment method.
- Expected effect: Fails on mutant 1883 because the transaction type stays blank, line 36 compares blank with Payment and no mapping is created (count 0 instead of 1); passes on the original because the blank type is replaced by Payment and one mapping is inserted.

```al
    [Test]
    procedure TestCopyPaymentMethodsFromBankSystem_UnknownPaymentMethod_UsesSetupTransactionType()
    var
        BankAccount: Record "Bank Account";
        BankAccComSetup: Record "CTS-CB Bank Acc. Com. Setup";
        BankSysPmtMthMap: Record "CTS-CB Bank Sys. Pmt. Mth. Map";
        BankSystem: Record "CTS-CB Bank System";
        BankSystemPmtMth: Record "CTS-CB Bank System Pmt. Mth.";
        PaymentMethod: Record "Payment Method";
        PaymentMethodMapper: Codeunit "CTS-CB Payment Method Mapper";
    begin
        DeleteTables();
        // [SCENARIO] A bank system payment method without a CTS-CB Payment Method is mapped with the setup's transaction type

        // [GIVEN] A bank system payment method that is not a CTS-CB Payment Method, and a Payment setup
        CreateBankAccount(BankAccount);
        CreateBankSystem(BankSystem);
        CreatePaymentMethod(PaymentMethod);
        CreateBankSystemPaymentMethod(BankSystemPmtMth, BankSystem.Code, PaymentMethod.Code);
        BankAccComSetup.Init();
        BankAccComSetup.Code := BankAccount."No.";
        BankAccComSetup."System Type" := BankAccComSetup."System Type"::BankSystem;
        BankAccComSetup."System Type Code" := BankSystem.Code;
        BankAccComSetup."Transaction Type" := BankAccComSetup."Transaction Type"::Payment;
        BankAccComSetup."File Type" := BankAccComSetup."File Type"::BankFormat;

        // [WHEN] Copying payment methods from bank system
        PaymentMethodMapper.CopyPaymentMethodsFromBankSystem(BankAccComSetup);

        // [THEN] One mapping with the setup's transaction type is created
        BankSysPmtMthMap.SetRange("Bank Account No.", BankAccount."No.");
        BankSysPmtMthMap.SetRange("Payment Method Code", PaymentMethod.Code);
        BankSysPmtMthMap.SetRange("Transaction Type", BankSysPmtMthMap."Transaction Type"::Payment);
        Assert.AreEqual(1, BankSysPmtMthMap.Count, 'An unknown payment method should be mapped with the setup transaction type');

        // Cleanup
        CleanupTestData(BankAccount, BankSystem, PaymentMethod);
    end;
```

### F042

- Mutants:
  - 1885: `TransactionType = BankAccComSetup."Transaction Type"` -> `true` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:36)
- Verdict: new-test
- Change: new-test
- Target procedure: TestCopyPaymentMethodsFromBankSystem_MismatchedTransactionType_IsSkipped
- Confidence: high
- Rationale: Line 36 (`TransactionType = BankAccComSetup."Transaction Type"`) is forced true by the mutant. TestMixedPaymentMethodMapping copies a Payment setup first, but afterwards only looks up each payment method with FindFirst and the later Direct Debit copy creates the same Direct Debit mapping, so the wrong mapping added during the Payment copy is hidden.
- Expected effect: Fails on mutant 1885 because the Direct Debit payment method is mapped from the Payment setup, so a row appears for the bank account; passes on the original because the type mismatch skips the payment method and the mapping table stays empty.

```al
    [Test]
    procedure TestCopyPaymentMethodsFromBankSystem_MismatchedTransactionType_IsSkipped()
    var
        BankAccount: Record "Bank Account";
        BankAccComSetup: Record "CTS-CB Bank Acc. Com. Setup";
        BankSysPmtMthMap: Record "CTS-CB Bank Sys. Pmt. Mth. Map";
        BankSystem: Record "CTS-CB Bank System";
        BankSystemPmtMth: Record "CTS-CB Bank System Pmt. Mth.";
        CTSCBPaymentMethod: Record "CTS-CB Payment Method";
        PaymentMethod: Record "Payment Method";
        PaymentMethodMapper: Codeunit "CTS-CB Payment Method Mapper";
    begin
        DeleteTables();
        // [SCENARIO] A Direct Debit payment method is not mapped for a Payment setup

        // [GIVEN] A payment method with Credit Transaction = true (Direct Debit) and a Payment setup
        CreateBankAccount(BankAccount);
        CreateBankSystem(BankSystem);
        CreatePaymentMethodWithCreditTransaction(PaymentMethod, CTSCBPaymentMethod, true);
        CreateBankSystemPaymentMethod(BankSystemPmtMth, BankSystem.Code, CTSCBPaymentMethod."Payment Method Code");
        BankAccComSetup.Init();
        BankAccComSetup.Code := BankAccount."No.";
        BankAccComSetup."System Type" := BankAccComSetup."System Type"::BankSystem;
        BankAccComSetup."System Type Code" := BankSystem.Code;
        BankAccComSetup."Transaction Type" := BankAccComSetup."Transaction Type"::Payment;
        BankAccComSetup."File Type" := BankAccComSetup."File Type"::BankFormat;

        // [WHEN] Copying payment methods from bank system
        PaymentMethodMapper.CopyPaymentMethodsFromBankSystem(BankAccComSetup);

        // [THEN] No mapping is created, because the payment method belongs to Direct Debit
        BankSysPmtMthMap.SetRange("Bank Account No.", BankAccount."No.");
        Assert.IsTrue(BankSysPmtMthMap.IsEmpty(), 'A Direct Debit payment method should not be mapped for a Payment setup');

        // Cleanup
        CleanupTestDataWithCTSCB(BankAccount, BankSystem, PaymentMethod, CTSCBPaymentMethod);
    end;
```

### F043

- Mutants:
  - 1889: `TargetPaymentMethod."CTS-CB Payment Method Code" = ''` -> `false` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:51)
  - 1890: `exit` -> `` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:52)
- Verdict: new-test
- Change: new-test
- Target procedure: TestPropagatePaymentMethodToMappings_BlankCTSCBCode_CreatesNoMappings
- Confidence: low
- Rationale: Line 51 (`CTS-CB Payment Method Code = ''`, exit on line 52): TestPropagateSkipsWhenNoCTSCBCode reaches it, but without the guard the code filters CTS-CB Payment Method on Code = '', finds nothing and exits one step later at line 57, so the visible outcome is the same. Only a CTS-CB Payment Method row with a blank Code makes the guard observable.
- Expected effect: Fails on mutants 1889/1890 because the filter Code = '' finds the blank-Code CTS-CB PM, its Payment Method Code finds the existing mapping and a second mapping is inserted for the new PM (count 2); passes on the original because the blank CTS-CB code exits at line 52 (count stays 1). Relies on a CTS-CB Payment Method row with a blank Code being insertable without triggers.

```al
    [Test]
    procedure TestPropagatePaymentMethodToMappings_BlankCTSCBCode_CreatesNoMappings()
    var
        BankAccount: Record "Bank Account";
        BankSysPmtMthMap: Record "CTS-CB Bank Sys. Pmt. Mth. Map";
        BankSystem: Record "CTS-CB Bank System";
        BankSystemPmtMth: Record "CTS-CB Bank System Pmt. Mth.";
        BlankCodeCTSCBPaymentMethod: Record "CTS-CB Payment Method";
        PaymentMethod: Record "Payment Method";
        PaymentMethodMapper: Codeunit "CTS-CB Payment Method Mapper";
        MappingCount: Integer;
    begin
        DeleteTables();
        // [SCENARIO] Propagation stops at once when the target PM has a blank CTS-CB Payment Method Code, even if a CTS-CB PM with a blank Code exists

        // [GIVEN] A CTS-CB Payment Method with a blank Code and an existing mapping on its Payment Method Code
        CreateBankAccount(BankAccount);
        CreateBankSystem(BankSystem);
        BlankCodeCTSCBPaymentMethod.Init();
        BlankCodeCTSCBPaymentMethod.Code := '';
        BlankCodeCTSCBPaymentMethod."Sender Country" := '00';
        BlankCodeCTSCBPaymentMethod."Recipient Country" := '00';
        BlankCodeCTSCBPaymentMethod."Payment Method Code" := 'BLANKCODEPM';
        BlankCodeCTSCBPaymentMethod.Insert();
        CreateBankSystemPaymentMethod(BankSystemPmtMth, BankSystem.Code, 'BLANKCODEPM');
        BankSysPmtMthMap.Init();
        BankSysPmtMthMap."Bank Account No." := BankAccount."No.";
        BankSysPmtMthMap."System Type" := BankSysPmtMthMap."System Type"::BankSystem;
        BankSysPmtMthMap."System Type Code" := BankSystem.Code;
        BankSysPmtMthMap."Transaction Type" := BankSysPmtMthMap."Transaction Type"::Payment;
        BankSysPmtMthMap."Payment Method Code" := 'BLANKCODEPM';
        BankSysPmtMthMap."Short Payment Method Code" := 'OTHER';
        BankSysPmtMthMap.Insert(true);

        // [GIVEN] A BC Payment Method without CTS-CB Payment Method Code
        CreatePaymentMethod(PaymentMethod);

        // [WHEN] Propagating the payment method
        PaymentMethodMapper.PropagatePaymentMethodToMappings(PaymentMethod);

        // [THEN] No new mapping is created
        BankSysPmtMthMap.Reset();
        BankSysPmtMthMap.SetRange("Bank Account No.", BankAccount."No.");
        MappingCount := BankSysPmtMthMap.Count;

        // Cleanup
        BlankCodeCTSCBPaymentMethod.Delete();
        CleanupTestData(BankAccount, BankSystem, PaymentMethod);

        Assert.AreEqual(1, MappingCount, 'No mapping should be propagated for a PM without CTS-CB Payment Method Code');
    end;
```

### F044

- Mutants:
  - 1894: `exit` -> `` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:57)
- Verdict: new-test
- Change: new-test
- Target procedure: TestPropagatePaymentMethodToMappings_UnknownCTSCBCode_CreatesNoMappings
- Confidence: medium
- Rationale: Line 57 (`exit` when the CTS-CB Payment Method is not found): no test in 95110 propagates a PM whose CTS-CB code has no CTS-CB record. Without the exit the code carries on with a blank Payment Method Code, which only has an effect if a mapping with a blank Payment Method Code exists, so the test creates one.
- Expected effect: Fails on mutant 1894 because the missing CTS-CB record leaves Payment Method Code blank, the blank-code mapping is found and a second mapping is inserted for the PM (count 2); passes on the original because the procedure exits at line 57 (count stays 1).

```al
    [Test]
    procedure TestPropagatePaymentMethodToMappings_UnknownCTSCBCode_CreatesNoMappings()
    var
        BankAccount: Record "Bank Account";
        BankSysPmtMthMap: Record "CTS-CB Bank Sys. Pmt. Mth. Map";
        BankSystem: Record "CTS-CB Bank System";
        PaymentMethod: Record "Payment Method";
        PaymentMethodMapper: Codeunit "CTS-CB Payment Method Mapper";
        MappingCount: Integer;
    begin
        DeleteTables();
        // [SCENARIO] Propagation does nothing when the target PM points to a CTS-CB Payment Method that does not exist

        // [GIVEN] An existing mapping with a blank Payment Method Code
        CreateBankAccount(BankAccount);
        CreateBankSystem(BankSystem);
        BankSysPmtMthMap.Init();
        BankSysPmtMthMap."Bank Account No." := BankAccount."No.";
        BankSysPmtMthMap."System Type" := BankSysPmtMthMap."System Type"::BankSystem;
        BankSysPmtMthMap."System Type Code" := BankSystem.Code;
        BankSysPmtMthMap."Transaction Type" := BankSysPmtMthMap."Transaction Type"::Payment;
        BankSysPmtMthMap."Payment Method Code" := '';
        BankSysPmtMthMap."Short Payment Method Code" := 'OTHER';
        BankSysPmtMthMap.Insert(true);

        // [GIVEN] A BC Payment Method whose CTS-CB Payment Method Code does not exist
        CreatePaymentMethod(PaymentMethod);
        PaymentMethod."CTS-CB Payment Method Code" := 'NOSUCH';
        PaymentMethod.Modify(true);

        // [WHEN] Propagating the payment method
        PaymentMethodMapper.PropagatePaymentMethodToMappings(PaymentMethod);

        // [THEN] No new mapping is created
        BankSysPmtMthMap.Reset();
        BankSysPmtMthMap.SetRange("Bank Account No.", BankAccount."No.");
        MappingCount := BankSysPmtMthMap.Count;

        // Cleanup
        CleanupTestData(BankAccount, BankSystem, PaymentMethod);

        Assert.AreEqual(1, MappingCount, 'No mapping should be propagated when the CTS-CB Payment Method does not exist');
    end;
```

### F045

- Mutants:
  - 1897: `not ExistingBankSysPmtMthMap.FindSet()` -> `false` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:61)
  - 1898: `exit` -> `` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:62)
- Verdict: new-test
- Change: new-test
- Target procedure: TestPropagatePaymentMethodToMappings_NoExistingMappings_CreatesNoMappings
- Confidence: high
- Rationale: Lines 61/62 (`not ExistingBankSysPmtMthMap.FindSet()`, then `exit`) are only reached in TestPropagateNewBCPMToExistingMappings with an existing mapping present, so the no-mapping branch is never taken.
- Expected effect: Fails on mutants 1897/1898 because the loop body runs on an empty record and inserts a junk mapping row (blank bank account, Short Payment Method Code = the new PM), so the count is 1 instead of 0; passes on the original because the procedure exits at line 62 and the table stays empty.

```al
    [Test]
    procedure TestPropagatePaymentMethodToMappings_NoExistingMappings_CreatesNoMappings()
    var
        BankSysPmtMthMap: Record "CTS-CB Bank Sys. Pmt. Mth. Map";
        CTSCBPaymentMethod: Record "CTS-CB Payment Method";
        PaymentMethod: Record "Payment Method";
        PaymentMethodMapper: Codeunit "CTS-CB Payment Method Mapper";
        MappingCount: Integer;
    begin
        DeleteTables();
        // [SCENARIO] Propagation does nothing when no mapping uses the CTS-CB Payment Method

        // [GIVEN] A CTS-CB Payment Method with a linked BC Payment Method but no mappings
        CreateCTSCBPaymentMethod(CTSCBPaymentMethod, false);
        CreateBCPaymentMethodWithCTSCB(PaymentMethod, CTSCBPaymentMethod.Code);

        // [WHEN] Propagating the payment method
        PaymentMethodMapper.PropagatePaymentMethodToMappings(PaymentMethod);

        // [THEN] No mapping is created
        MappingCount := BankSysPmtMthMap.Count;

        // Cleanup
        BankSysPmtMthMap.DeleteAll();
        if PaymentMethod.Get(PaymentMethod.Code) then
            PaymentMethod.Delete(true);
        if CTSCBPaymentMethod.Get(CTSCBPaymentMethod.Code, CTSCBPaymentMethod."Sender Country", CTSCBPaymentMethod."Recipient Country") then
            CTSCBPaymentMethod.Delete(true);

        Assert.AreEqual(0, MappingCount, 'No mapping should be created when there are no existing mappings to propagate to');
    end;
```

### F046

- Mutants:
  - 1899: `not PaymentMthValidator.ShouldUsePaymentMethodMappings(BankAccComSetup."Transaction Type")` -> `PaymentMthValidator.ShouldUsePaymentMethodMappings(BankAccComSetup."Transaction Type")` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:84)
  - 1900: `not PaymentMthValidator.ShouldUsePaymentMethodMappings(BankAccComSetup."Transaction Type")` -> `true` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:84)
  - 1903: `not SkipConflictCheck` -> `SkipConflictCheck` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:87)
  - 1904: `not SkipConflictCheck` -> `true` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:87)
  - 1905: `not SkipConflictCheck` -> `false` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:87)
  - 1906: `exit` -> `` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:88)
- Verdict: new-test
- Change: new-test
- Target procedure: TestPopulatePaymentMethodsWithConflictCheck_ConflictAndSkipFlag_ControlPopulation
- Confidence: medium
- Rationale: PopulatePaymentMethodsWithConflictCheck (lines 84-88) is not called by any test in 95110; the setup wizard page is its only caller and it always passes SkipConflictCheck = true. So neither the Payment/Direct Debit guard nor the conflict check with its early exit is exercised with a distinguishing input.
- Expected effect: Fails on mutants 1899/1900 (the guard exits for Payment, so the second call maps nothing), 1904 (the conflict check runs although it is skipped, so the second call exits) and 1903/1905/1906 (the conflict is ignored or not acted on, so the first call already maps the payment method); passes on the original because the first call stops on the conflict and the second call, with the check skipped, inserts the mapping for the second system.

```al
    [Test]
    procedure TestPopulatePaymentMethodsWithConflictCheck_ConflictAndSkipFlag_ControlPopulation()
    var
        BankAccount: Record "Bank Account";
        BankAccComSetupExisting: Record "CTS-CB Bank Acc. Com. Setup";
        BankAccComSetupNew: Record "CTS-CB Bank Acc. Com. Setup";
        BankSysPmtMthMap: Record "CTS-CB Bank Sys. Pmt. Mth. Map";
        BankSystemExisting: Record "CTS-CB Bank System";
        BankSystemNew: Record "CTS-CB Bank System";
        BankSystemPmtMth: Record "CTS-CB Bank System Pmt. Mth.";
        CTSCBPaymentMethod: Record "CTS-CB Payment Method";
        PaymentMethod: Record "Payment Method";
        PaymentMethodMapper: Codeunit "CTS-CB Payment Method Mapper";
    begin
        DeleteTables();
        // [SCENARIO] A payment method conflict stops population unless the conflict check is skipped

        // [GIVEN] Two bank systems that support the same Payment payment method
        CreateBankAccount(BankAccount);
        CreateBankSystem(BankSystemExisting);
        CreateBankSystem(BankSystemNew);
        CreatePaymentMethodWithCreditTransaction(PaymentMethod, CTSCBPaymentMethod, false);
        CreateBankSystemPaymentMethod(BankSystemPmtMth, BankSystemExisting.Code, CTSCBPaymentMethod."Payment Method Code");
        CreateBankSystemPaymentMethod(BankSystemPmtMth, BankSystemNew.Code, CTSCBPaymentMethod."Payment Method Code");

        // [GIVEN] An enabled setup for the first system that already owns a mapping for the payment method
        BankAccComSetupExisting.Init();
        BankAccComSetupExisting.Code := BankAccount."No.";
        BankAccComSetupExisting."System Type" := BankAccComSetupExisting."System Type"::BankSystem;
        BankAccComSetupExisting."System Type Code" := BankSystemExisting.Code;
        BankAccComSetupExisting."Transaction Type" := BankAccComSetupExisting."Transaction Type"::Payment;
        BankAccComSetupExisting."File Type" := BankAccComSetupExisting."File Type"::BankFormat;
        BankAccComSetupExisting.Enabled := true;
        BankAccComSetupExisting."Auto Populate Pmt Methods" := false;
        BankAccComSetupExisting.Insert(true);

        BankSysPmtMthMap.Init();
        BankSysPmtMthMap."Bank Account No." := BankAccount."No.";
        BankSysPmtMthMap."System Type" := BankSysPmtMthMap."System Type"::BankSystem;
        BankSysPmtMthMap."System Type Code" := BankSystemExisting.Code;
        BankSysPmtMthMap."Transaction Type" := BankSysPmtMthMap."Transaction Type"::Payment;
        BankSysPmtMthMap."Payment Method Code" := CTSCBPaymentMethod."Payment Method Code";
        BankSysPmtMthMap."Short Payment Method Code" := 'OTHER';
        BankSysPmtMthMap.Insert(true);

        // [GIVEN] A not yet saved setup for the second system
        BankAccComSetupNew.Init();
        BankAccComSetupNew.Code := BankAccount."No.";
        BankAccComSetupNew."System Type" := BankAccComSetupNew."System Type"::BankSystem;
        BankAccComSetupNew."System Type Code" := BankSystemNew.Code;
        BankAccComSetupNew."Transaction Type" := BankAccComSetupNew."Transaction Type"::Payment;
        BankAccComSetupNew."File Type" := BankAccComSetupNew."File Type"::BankFormat;

        // [WHEN] Populating with the conflict check enabled
        PaymentMethodMapper.PopulatePaymentMethodsWithConflictCheck(BankAccComSetupNew, false);

        // [THEN] The conflict stops the population
        BankSysPmtMthMap.Reset();
        BankSysPmtMthMap.SetRange("Bank Account No.", BankAccount."No.");
        BankSysPmtMthMap.SetRange("System Type Code", BankSystemNew.Code);
        Assert.IsTrue(BankSysPmtMthMap.IsEmpty(), 'A detected conflict should stop the population of payment methods');

        // [WHEN] Populating with the conflict check skipped
        PaymentMethodMapper.PopulatePaymentMethodsWithConflictCheck(BankAccComSetupNew, true);

        // [THEN] The payment method is mapped for the second system
        Assert.IsFalse(BankSysPmtMthMap.IsEmpty(), 'Skipping the conflict check should populate the payment methods');

        // Cleanup
        CleanupTestDataWithCTSCB(BankAccount, BankSystemExisting, PaymentMethod, CTSCBPaymentMethod);
        if BankSystemNew.Get(BankSystemNew.Code) then
            BankSystemNew.Delete(true);
    end;
```

### F047

- Mutants:
  - 1911: `not BankSysPmtMthMap.IsEmpty()` -> `BankSysPmtMthMap.IsEmpty()` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:117)
  - 1913: `not BankSysPmtMthMap.IsEmpty()` -> `false` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:117)
  - 1914: `BankSysPmtMthMap.DeleteAll()` -> `` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:118)
- Verdict: new-test
- Change: new-test
- Target procedure: TestCleanupExceptSystem_RemovesOnlyOtherSystemMappings
- Confidence: high
- Rationale: CleanupExceptSystem (lines 117-118) is not called by any test in 95110; its only caller is the setup wizard page. Neither the IsEmpty guard nor the DeleteAll is exercised with existing mappings. Test bug fixed: 'Entry No.' is AutoIncrement and Init() keeps primary-key fields, so the second Insert(true) on the same record variable would reuse the first Entry No. and raise a duplicate-key error (failing the original too). The Entry No. is reset to 0 before the second Init(), the same idiom the AUT uses in InsertMappingIfNotExists.
- Expected effect: Fails on mutants 1911 (delete only when empty), 1913 (never delete) and 1914 (DeleteAll removed) because the other system's mapping is still there, so the first assertion fails; passes on the original because the other system's mapping is deleted and the kept system's mapping survives.

```al
    [Test]
    procedure TestCleanupExceptSystem_RemovesOnlyOtherSystemMappings()
    var
        BankAccount: Record "Bank Account";
        BankSysPmtMthMap: Record "CTS-CB Bank Sys. Pmt. Mth. Map";
        BankSystemKeep: Record "CTS-CB Bank System";
        BankSystemOther: Record "CTS-CB Bank System";
        BankSystemPmtMth: Record "CTS-CB Bank System Pmt. Mth.";
        PaymentMethod: Record "Payment Method";
        PaymentMethodMapper: Codeunit "CTS-CB Payment Method Mapper";
    begin
        DeleteTables();
        // [SCENARIO] Cleaning up an incomplete setup removes the mappings of all systems except the one to keep

        // [GIVEN] Payment method mappings for two bank systems on the same bank account
        CreateBankAccount(BankAccount);
        CreateBankSystem(BankSystemKeep);
        CreateBankSystem(BankSystemOther);
        CreatePaymentMethod(PaymentMethod);
        CreateBankSystemPaymentMethod(BankSystemPmtMth, BankSystemKeep.Code, PaymentMethod.Code);
        CreateBankSystemPaymentMethod(BankSystemPmtMth, BankSystemOther.Code, PaymentMethod.Code);

        BankSysPmtMthMap.Init();
        BankSysPmtMthMap."Bank Account No." := BankAccount."No.";
        BankSysPmtMthMap."System Type" := BankSysPmtMthMap."System Type"::BankSystem;
        BankSysPmtMthMap."System Type Code" := BankSystemKeep.Code;
        BankSysPmtMthMap."Transaction Type" := BankSysPmtMthMap."Transaction Type"::Payment;
        BankSysPmtMthMap."Payment Method Code" := PaymentMethod.Code;
        BankSysPmtMthMap.Insert(true);

        BankSysPmtMthMap."Entry No." := 0;
        BankSysPmtMthMap.Init();
        BankSysPmtMthMap."Bank Account No." := BankAccount."No.";
        BankSysPmtMthMap."System Type" := BankSysPmtMthMap."System Type"::BankSystem;
        BankSysPmtMthMap."System Type Code" := BankSystemOther.Code;
        BankSysPmtMthMap."Transaction Type" := BankSysPmtMthMap."Transaction Type"::Payment;
        BankSysPmtMthMap."Payment Method Code" := PaymentMethod.Code;
        BankSysPmtMthMap.Insert(true);

        // [WHEN] Cleaning up except the first system
        PaymentMethodMapper.CleanupExceptSystem(BankAccount."No.", "CTS-CB Transaction Type"::Payment, BankSystemKeep.Code);

        // [THEN] The mappings of the other system are deleted
        BankSysPmtMthMap.Reset();
        BankSysPmtMthMap.SetRange("Bank Account No.", BankAccount."No.");
        BankSysPmtMthMap.SetRange("System Type Code", BankSystemOther.Code);
        Assert.IsTrue(BankSysPmtMthMap.IsEmpty(), 'Mappings of the other system should be deleted');

        // [THEN] The mappings of the kept system are preserved
        BankSysPmtMthMap.SetRange("System Type Code", BankSystemKeep.Code);
        Assert.IsFalse(BankSysPmtMthMap.IsEmpty(), 'Mappings of the kept system should be preserved');

        // Cleanup
        BankSystemPmtMth.SetRange("Bank System Code", BankSystemOther.Code);
        BankSystemPmtMth.DeleteAll(true);
        CleanupTestData(BankAccount, BankSystemKeep, PaymentMethod);
        if BankSystemOther.Get(BankSystemOther.Code) then
            BankSystemOther.Delete(true);
    end;
```

### F048

- Mutants:
  - 1921: `ShortPaymentMethodCode <> ''` -> `true` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:174)
- Verdict: new-test
- Change: new-test
- Target procedure: TestCopyPaymentMethodsFromBankSystem_ExistingMappingWithShortCode_IsNotDuplicated
- Confidence: high
- Rationale: Line 174 (`ShortPaymentMethodCode <> ''`) is forced true. With a blank Short PM Code the original does not filter on Short PM Code, whereas the mutant filters on a blank one. TestDuplicatePaymentMethodValidation cannot tell the difference because the mapping it creates also has a blank Short PM Code.
- Expected effect: Fails on mutant 1921 because the duplicate check only looks for a mapping with a blank Short PM Code, misses the existing 'OTHER' mapping and inserts a second one (count 2); passes on the original because the check ignores the Short PM Code, finds the existing mapping and skips the insert (count 1).

```al
    [Test]
    procedure TestCopyPaymentMethodsFromBankSystem_ExistingMappingWithShortCode_IsNotDuplicated()
    var
        BankAccount: Record "Bank Account";
        BankAccComSetup: Record "CTS-CB Bank Acc. Com. Setup";
        BankSysPmtMthMap: Record "CTS-CB Bank Sys. Pmt. Mth. Map";
        BankSystem: Record "CTS-CB Bank System";
        BankSystemPmtMth: Record "CTS-CB Bank System Pmt. Mth.";
        PaymentMethod: Record "Payment Method";
        PaymentMethodMapper: Codeunit "CTS-CB Payment Method Mapper";
    begin
        DeleteTables();
        // [SCENARIO] A mapping without Short PM Code is not added when a mapping for the same payment method already exists with a Short PM Code

        // [GIVEN] An existing mapping with a Short Payment Method Code for a bank system payment method without CTS-CB Payment Method
        CreateBankAccount(BankAccount);
        CreateBankSystem(BankSystem);
        CreatePaymentMethod(PaymentMethod);
        CreateBankSystemPaymentMethod(BankSystemPmtMth, BankSystem.Code, PaymentMethod.Code);
        BankSysPmtMthMap.Init();
        BankSysPmtMthMap."Bank Account No." := BankAccount."No.";
        BankSysPmtMthMap."System Type" := BankSysPmtMthMap."System Type"::BankSystem;
        BankSysPmtMthMap."System Type Code" := BankSystem.Code;
        BankSysPmtMthMap."Transaction Type" := BankSysPmtMthMap."Transaction Type"::Payment;
        BankSysPmtMthMap."Payment Method Code" := PaymentMethod.Code;
        BankSysPmtMthMap."Short Payment Method Code" := 'OTHER';
        BankSysPmtMthMap.Insert(true);
        BankAccComSetup.Init();
        BankAccComSetup.Code := BankAccount."No.";
        BankAccComSetup."System Type" := BankAccComSetup."System Type"::BankSystem;
        BankAccComSetup."System Type Code" := BankSystem.Code;
        BankAccComSetup."Transaction Type" := BankAccComSetup."Transaction Type"::Payment;
        BankAccComSetup."File Type" := BankAccComSetup."File Type"::BankFormat;

        // [WHEN] Copying payment methods from bank system (the fallback path inserts with a blank Short PM Code)
        PaymentMethodMapper.CopyPaymentMethodsFromBankSystem(BankAccComSetup);

        // [THEN] No second mapping is created for the payment method
        BankSysPmtMthMap.Reset();
        BankSysPmtMthMap.SetRange("Bank Account No.", BankAccount."No.");
        BankSysPmtMthMap.SetRange("Payment Method Code", PaymentMethod.Code);
        Assert.AreEqual(1, BankSysPmtMthMap.Count, 'An existing mapping should prevent a duplicate when the Short PM Code is blank');

        // Cleanup
        CleanupTestData(BankAccount, BankSystem, PaymentMethod);
    end;
```

### F049

- Mutants:
  - 1928: `BankSysPmtMthMap.Insert(true)` -> `BankSysPmtMthMap.Insert(false)` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:187)
- Verdict: new-test
- Change: new-test
- Target procedure: TestPropagatePaymentMethodToMappings_UnsupportedExistingMapping_RaisesInsertValidation
- Confidence: low
- Rationale: Line 187 (`Insert(true)` becomes `Insert(false)`): every Copy and Propagate call in 95110 inserts mappings whose bank system payment method exists, and the Short PM Code is either preset or derived to the same value as without the trigger, so skipping OnInsert changes nothing. The only observable effect is the trigger's ValidateBankSystemPaymentMethodExists check, which needs an orphaned mapping to fire.
- Expected effect: Fails on mutant 1928 because without the insert trigger no validation error is raised, so asserterror reports that no error occurred; passes on the original because Insert(true) runs OnInsert and raises 'Payment method ... is not supported by bank system ...'.

```al
    [Test]
    procedure TestPropagatePaymentMethodToMappings_UnsupportedExistingMapping_RaisesInsertValidation()
    var
        BankAccount: Record "Bank Account";
        BankSysPmtMthMap: Record "CTS-CB Bank Sys. Pmt. Mth. Map";
        BankSystem: Record "CTS-CB Bank System";
        BankSystemPmtMth: Record "CTS-CB Bank System Pmt. Mth.";
        CTSCBPaymentMethod: Record "CTS-CB Payment Method";
        ExistingPaymentMethod: Record "Payment Method";
        NewPaymentMethod: Record "Payment Method";
        PaymentMethodMapper: Codeunit "CTS-CB Payment Method Mapper";
    begin
        DeleteTables();
        // [SCENARIO] Mappings are inserted with their insert trigger, so a payment method the bank system no longer supports is rejected

        // [GIVEN] An existing mapping whose bank system payment method has since been removed
        CreateBankAccount(BankAccount);
        CreateBankSystem(BankSystem);
        CreateCTSCBPaymentMethod(CTSCBPaymentMethod, false);
        CreateBCPaymentMethodWithCTSCB(ExistingPaymentMethod, CTSCBPaymentMethod.Code);
        CreateBankSystemPaymentMethod(BankSystemPmtMth, BankSystem.Code, CTSCBPaymentMethod."Payment Method Code");
        BankSysPmtMthMap.Init();
        BankSysPmtMthMap."Bank Account No." := BankAccount."No.";
        BankSysPmtMthMap."System Type" := BankSysPmtMthMap."System Type"::BankSystem;
        BankSysPmtMthMap."System Type Code" := BankSystem.Code;
        BankSysPmtMthMap."Transaction Type" := BankSysPmtMthMap."Transaction Type"::Payment;
        BankSysPmtMthMap."Payment Method Code" := CTSCBPaymentMethod."Payment Method Code";
        BankSysPmtMthMap."Short Payment Method Code" := ExistingPaymentMethod.Code;
        BankSysPmtMthMap.Insert(true);
        BankSystemPmtMth.Delete();

        // [GIVEN] A new BC Payment Method with the same CTS-CB Payment Method Code
        CreateBCPaymentMethodWithCTSCB(NewPaymentMethod, CTSCBPaymentMethod.Code);

        // [WHEN] Propagating the new BC Payment Method to the existing mappings
        asserterror PaymentMethodMapper.PropagatePaymentMethodToMappings(NewPaymentMethod);

        // [THEN] The insert validation rejects the unsupported payment method
        Assert.ExpectedError('not supported');

        // Cleanup
        CleanupMultipleBCPMTestData(BankAccount, BankSystem, CTSCBPaymentMethod, ExistingPaymentMethod, NewPaymentMethod);
    end;
```

## Test codeunit 95121 CTS-CB Int. Batch Disp Tests

File: Yapily/IntBatchDispTests.Codeunit.al

### F054

- Mutants:
  - 4508: `TempIntBatchDisplay.DeleteAll()` -> `` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:31)
- Verdict: fix
- Change: add-assert
- Target procedure: TestBuildBatchDisplay_EmptyInput_ReturnsEmpty
- Anchor: after line 166
- Confidence: high
- Rationale: Line 31 (TempIntBatchDisplay.DeleteAll() in BuildBatchDisplay) is executed by every test, but the output table is always empty on entry, so removing the DeleteAll changes nothing. The existing IsEmpty assertion in the empty-input test only becomes meaningful if the output table holds a stale row beforehand.
- Expected effect: Fails on mutant 4508 because the stale header row inserted before the call is not cleared, so the existing Assert.IsTrue(TempIntBatchDisplay.IsEmpty()) fails; passes on the original because DeleteAll clears the output table before the empty-input exit.

```al
        TempIntBatchDisplay.Init();
        TempIntBatchDisplay.ID := 1;
        TempIntBatchDisplay."Entry Type" := "CTS-CB Batch Entry Type"::Header;
        TempIntBatchDisplay.Insert();
```

### F055

- Mutants:
  - 4510: `TempPaymentEntry.IsEmpty()` -> `false` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:33)
  - 4511: `exit` -> `` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:34)
- Verdict: new-test
- Change: new-test
- Target procedure: TestBuildBatchDisplay_EmptyInput_StrategyOffersBatch_StaysEmpty
- Confidence: medium
- Rationale: Line 33-34: 'if TempPaymentEntry.IsEmpty() then exit;' in BuildBatchDisplay (mutants 4510: condition forced false, 4511: exit removed). IExport Batch Strategy is a public interface, so the 'equivalent' claim that both shipped implementations return an empty batch for empty input does not hold for every implementation: a strategy that returns an entry on its first call even though TempPaymentEntry is empty makes the mutants build a header and a line. No test uses such a strategy. Add a new fake codeunit (NEW OBJECT, not part of alCode) and the test in alCode. Fake codeunit id 95312 was chosen because it is inside the app's idRange 94999-95999 and is free: a recursive search of out/test-app (*.al and *.json) for object declarations and for the literal 95312 found no use (highest used codeunit ids are 95311, then 95900-95903, 95910-95913). Full AL source of the fake, to be saved as e.g. Yapily/Fakes/FakeBatchStrategy.Codeunit.al (re-check the id is still free before applying):

codeunit 95312 "CTS-CB Fake Batch Strategy" implements "CTS-CB IExport Batch Strategy"
{
    Access = Internal;

    var
        CallCount: Integer;

    procedure ShouldSplitIntoBatches(var TempPaymentEntry: Record "CTS-CB Payment Entry" temporary; Bank: Record "CTS-CB Bank"; BankAccComSetup: Record "CTS-CB Bank Acc. Com. Setup"): Boolean
    begin
        exit(true);
    end;

    procedure GetNextBatch(var TempPaymentEntry: Record "CTS-CB Payment Entry" temporary; var TempBatchPaymentEntry: Record "CTS-CB Payment Entry" temporary; Bank: Record "CTS-CB Bank"; var BatchNo: Integer; BankAccComSetup: Record "CTS-CB Bank Acc. Com. Setup"): Enum "CTS-CB Int. Token Type"
    begin
        CallCount += 1;
        if CallCount > 1 then
            exit("CTS-CB Int. Token Type"::" ");
        BatchNo := 1;
        TempBatchPaymentEntry.Init();
        TempBatchPaymentEntry."Entry No." := 1;
        TempBatchPaymentEntry.Insert();
        exit("CTS-CB Int. Token Type"::SinglePayment);
    end;

    procedure RequiresUserInteraction(): Boolean
    begin
        exit(false);
    end;
}
- Expected effect: Fails on mutants 4510 and 4511 because the loop is entered with empty input, the fake returns one entry on its first call and CreateDisplayRecordsForBatch inserts a header and a line, so TempIntBatchDisplay is not empty; passes on the original because IsEmpty() exits before the strategy is called. Medium confidence: it needs the new fake codeunit and the interface signature must match the current IExport Batch Strategy (ShouldSplitIntoBatches, GetNextBatch, RequiresUserInteraction).

```al
    [Test]
    procedure TestBuildBatchDisplay_EmptyInput_StrategyOffersBatch_StaysEmpty()
    var
        Bank: Record "CTS-CB Bank";
        BankAccComSetup: Record "CTS-CB Bank Acc. Com. Setup";
        TempIntBatchDisplay: Record "CTS-CB Int. Batch Display" temporary;
        TempPaymentEntry: Record "CTS-CB Payment Entry" temporary;
        IntBatchDispBldr: Codeunit "CTS-CB Int. Batch Disp Bldr";
        FakeBatchStrategy: Codeunit "CTS-CB Fake Batch Strategy";
    begin
        // [SCENARIO] BuildBatchDisplay does not consult the strategy when the input is empty,
        // even if the strategy would return a batch on its first call.

        // [GIVEN] Empty payment entries and a strategy whose first GetNextBatch call returns one entry
        Initialize();
        CreateTestBank(Bank);
        CreateTestBankAccComSetup(BankAccComSetup);

        // [WHEN] BuildBatchDisplay is called with empty entries
        IntBatchDispBldr.BuildBatchDisplay(TempPaymentEntry, Bank, FakeBatchStrategy, TempIntBatchDisplay, BankAccComSetup);

        // [THEN] Output stays empty: the early exit on empty input must prevent the strategy from being called
        Assert.IsTrue(TempIntBatchDisplay.IsEmpty(), 'Output should be empty for empty input, even if the strategy offers a batch');
    end;
```

### F056

- Mutants:
  - 4516: `TempPaymentEntry.DeleteAll()` -> `` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:68)
- Verdict: fix
- Change: add-assert
- Target procedure: TestGetPaymentEntriesForBatch_OnlyReturnsForHeader
- Anchor: after line 289
- Confidence: high
- Rationale: Line 68 (TempPaymentEntry.DeleteAll() in GetPaymentEntriesForBatch) is reached by both GetPaymentEntriesForBatch tests, but the output buffer is always empty before the call, so a missing DeleteAll is invisible. Pre-filling the output buffer makes the existing IsEmpty assertion detect it. The inserted lines are setup, not a new assertion: they pre-fill the output buffer so that the existing IsEmpty assert becomes meaningful (add-assert is used because it only inserts lines into the existing procedure).
- Expected effect: Fails on mutant 4516 because the pre-inserted stale row stays in TempRetrievedPaymentEntry (the line-record exit does not clear it), so Assert.IsTrue(TempRetrievedPaymentEntry.IsEmpty()) fails; passes on the original because DeleteAll empties the output buffer first.

```al
        TempRetrievedPaymentEntry := TempSourcePaymentEntry;
        TempRetrievedPaymentEntry.Insert();
```

### F057

- Mutants:
  - 4519: `TempIntBatchDisplay."Entry Type" <> BatchEntryType::Header` -> `false` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:72)
  - 4520: `exit` -> `` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:73)
- Verdict: new-test
- Change: new-test
- Target procedure: TestGetPaymentEntriesForBatch_NonHeaderRecordWithHeaderId_ReturnsEmpty
- Confidence: high
- Rationale: Line 72-73 (the Entry Type <> Header guard) is only exercised by OnlyReturnsForHeader, which passes a real line record. A line's ID is never the Batch Header ID of any line, so without the guard the later lookup also finds no lines and the result is empty either way. No existing test passes a non-header record whose ID matches existing lines' Batch Header ID.
- Expected effect: Fails on mutants 4519/4520 because without the guard the lookup finds the header's line (Batch Header ID = that ID), reads it from the source table and returns 1 payment entry, so IsEmpty is false; passes on the original because the Entry Type <> Header guard exits before any lookup.

```al
    [Test]
    procedure TestGetPaymentEntriesForBatch_NonHeaderRecordWithHeaderId_ReturnsEmpty()
    var
        Bank: Record "CTS-CB Bank";
        BankAccComSetup: Record "CTS-CB Bank Acc. Com. Setup";
        BulkPaymentRule: Record "CTS-CB Bulk Payment Rule";
        TempIntBatchDisplay: Record "CTS-CB Int. Batch Display" temporary;
        TempNonHeaderIntBatchDisplay: Record "CTS-CB Int. Batch Display" temporary;
        TempPaymentEntry: Record "CTS-CB Payment Entry" temporary;
        TempRetrievedPaymentEntry: Record "CTS-CB Payment Entry" temporary;
        TempSourcePaymentEntry: Record "CTS-CB Payment Entry" temporary;
        IntBatchDispBldr: Codeunit "CTS-CB Int. Batch Disp Bldr";
        IntBatchStrategy: Codeunit "CTS-CB Int. Batch Strategy";
    begin
        // [SCENARIO] GetPaymentEntriesForBatch returns nothing for a non-header record, even when its ID is the Batch Header ID of existing lines

        // [GIVEN] A built display with one header and one line
        Initialize();
        CreateTestBank(Bank);
        CreateTestBankAccComSetup(BankAccComSetup);
        CreateBulkPaymentRule(BulkPaymentRule, Bank.Code, 1, 100, 1000000);
        CreateTempPaymentEntry(TempPaymentEntry, CopyStr(Bank.Code, 1, 20), 100);
        TempSourcePaymentEntry := TempPaymentEntry;
        TempSourcePaymentEntry.Insert();
        IntBatchDispBldr.BuildBatchDisplay(TempPaymentEntry, Bank, IntBatchStrategy, TempIntBatchDisplay, BankAccComSetup);

        // [GIVEN] A non-header record that carries the header's ID (so the line lookup would find the header's lines)
#pragma warning disable AA0210 // Key not necessary due to table size.
        TempIntBatchDisplay.SetRange("Entry Type", "CTS-CB Batch Entry Type"::Header);
#pragma warning restore AA0210
        TempIntBatchDisplay.FindFirst();
        TempNonHeaderIntBatchDisplay := TempIntBatchDisplay;
        TempNonHeaderIntBatchDisplay."Entry Type" := "CTS-CB Batch Entry Type"::Line;
        TempIntBatchDisplay.Reset();

        // [WHEN] GetPaymentEntriesForBatch is called with the non-header record
        IntBatchDispBldr.GetPaymentEntriesForBatch(TempNonHeaderIntBatchDisplay, TempRetrievedPaymentEntry, TempIntBatchDisplay, TempSourcePaymentEntry);

        // [THEN] Nothing is returned
        Assert.IsTrue(TempRetrievedPaymentEntry.IsEmpty(), 'Should return empty for a non-header record even if lines exist for its ID');
    end;
```

### F058

- Mutants:
  - 4523: `not TempLineIntBatchDisplay.FindSet()` -> `false` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:80)
  - 4524: `exit` -> `` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:81)
- Verdict: new-test
- Change: new-test
- Target procedure: TestGetPaymentEntriesForBatch_HeaderWithoutLines_ReturnsEmpty
- Confidence: medium
- Rationale: Line 80-81 (if not TempLineIntBatchDisplay.FindSet() then exit). Existing tests only call it for headers that have lines, or for a line record that exits earlier at line 72, so the 'no lines found' branch is never taken. Without the exit the repeat loop would run on the unchanged record buffer copied from the display table, which only matters if that buffer is positioned on a line whose Source Line Entry No. exists in the source table.
- Expected effect: Fails on mutants 4523/4524 because the failed FindSet leaves the copied buffer on the line record (Source Line Entry No. 1), the loop finds source entry 1 and inserts it, so the result is not empty; passes on the original because the empty FindSet exits before the loop.

```al
    [Test]
    procedure TestGetPaymentEntriesForBatch_HeaderWithoutLines_ReturnsEmpty()
    var
        Bank: Record "CTS-CB Bank";
        BankAccComSetup: Record "CTS-CB Bank Acc. Com. Setup";
        BulkPaymentRule: Record "CTS-CB Bulk Payment Rule";
        TempHeaderWithoutLines: Record "CTS-CB Int. Batch Display" temporary;
        TempIntBatchDisplay: Record "CTS-CB Int. Batch Display" temporary;
        TempPaymentEntry: Record "CTS-CB Payment Entry" temporary;
        TempRetrievedPaymentEntry: Record "CTS-CB Payment Entry" temporary;
        TempSourcePaymentEntry: Record "CTS-CB Payment Entry" temporary;
        IntBatchDispBldr: Codeunit "CTS-CB Int. Batch Disp Bldr";
        IntBatchStrategy: Codeunit "CTS-CB Int. Batch Strategy";
    begin
        // [SCENARIO] GetPaymentEntriesForBatch returns nothing for a header that has no lines, even when the display buffer is positioned on a line

        // [GIVEN] A built display with one header and one line, and the display buffer positioned on the line
        Initialize();
        CreateTestBank(Bank);
        CreateTestBankAccComSetup(BankAccComSetup);
        CreateBulkPaymentRule(BulkPaymentRule, Bank.Code, 1, 100, 1000000);
        CreateTempPaymentEntry(TempPaymentEntry, CopyStr(Bank.Code, 1, 20), 100);
        TempSourcePaymentEntry := TempPaymentEntry;
        TempSourcePaymentEntry.Insert();
        IntBatchDispBldr.BuildBatchDisplay(TempPaymentEntry, Bank, IntBatchStrategy, TempIntBatchDisplay, BankAccComSetup);
        TempIntBatchDisplay.Reset();
        TempIntBatchDisplay.FindLast();

        // [GIVEN] A header record whose ID no line refers to
        TempHeaderWithoutLines.Init();
        TempHeaderWithoutLines.ID := 99999;
        TempHeaderWithoutLines."Entry Type" := "CTS-CB Batch Entry Type"::Header;

        // [WHEN] GetPaymentEntriesForBatch is called for the header without lines
        IntBatchDispBldr.GetPaymentEntriesForBatch(TempHeaderWithoutLines, TempRetrievedPaymentEntry, TempIntBatchDisplay, TempSourcePaymentEntry);

        // [THEN] Nothing is returned
        Assert.IsTrue(TempRetrievedPaymentEntry.IsEmpty(), 'Should return empty for a header without lines');
    end;
```

### F060

- Mutants:
  - 4532: `LineCount = 1` -> `false` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:129)
  - 4537: `LineCount = 1` -> `false` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:145)
  - 4542: `TempBatchPaymentEntry.FindFirst()` -> `false` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:180)
  - 4543: `exit(TempBatchPaymentEntry."Creditor Name")` -> `` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:181)
- Verdict: new-test
- Change: new-test
- Target procedure: TestBuildBatchDisplay_SingleLineBatch_HeaderIsSinglePaymentWithCreditorName
- Confidence: high
- Rationale: Line 129 (LineCount = 1 selects SinglePayment as header token type) and lines 145-148/180-181 (single-payment description = creditor name). Existing tests use batches of 3 or more lines for token type, and the only single-line tests (OnlyReturnsForHeader) never inspect the header's Token Type or Account Name.
- Expected effect: Fails on mutant 4532 because the header keeps the strategy's BulkPayment token type (Min Number of Lines = 1); fails on 4537 because the single-line header is named '1 payments'; fails on 4542/4543 because GetSinglePaymentDescription returns '' instead of the creditor name; passes on the original (SinglePayment, 'Test Creditor 1').

```al
    [Test]
    procedure TestBuildBatchDisplay_SingleLineBatch_HeaderIsSinglePaymentWithCreditorName()
    var
        Bank: Record "CTS-CB Bank";
        BankAccComSetup: Record "CTS-CB Bank Acc. Com. Setup";
        BulkPaymentRule: Record "CTS-CB Bulk Payment Rule";
        TempIntBatchDisplay: Record "CTS-CB Int. Batch Display" temporary;
        TempPaymentEntry: Record "CTS-CB Payment Entry" temporary;
        IntBatchDispBldr: Codeunit "CTS-CB Int. Batch Disp Bldr";
        IntBatchStrategy: Codeunit "CTS-CB Int. Batch Strategy";
    begin
        // [SCENARIO] A batch with exactly one line gets a SinglePayment header named after the creditor

        // [GIVEN] One payment entry and a rule with minimum 1 line (the strategy itself reports BulkPayment for it)
        Initialize();
        CreateTestBank(Bank);
        CreateTestBankAccComSetup(BankAccComSetup);
        CreateBulkPaymentRule(BulkPaymentRule, Bank.Code, 1, 100, 1000000);
        CreateTempPaymentEntry(TempPaymentEntry, CopyStr(Bank.Code, 1, 20), 100);

        // [WHEN] BuildBatchDisplay is called
        IntBatchDispBldr.BuildBatchDisplay(TempPaymentEntry, Bank, IntBatchStrategy, TempIntBatchDisplay, BankAccComSetup);

        // [THEN] The header is a SinglePayment named after the creditor
#pragma warning disable AA0210 // Key not necessary due to table size.
        TempIntBatchDisplay.SetRange("Entry Type", "CTS-CB Batch Entry Type"::Header);
#pragma warning restore AA0210
        TempIntBatchDisplay.FindFirst();
        Assert.AreEqual("CTS-CB Int. Token Type"::SinglePayment, TempIntBatchDisplay."Token Type", 'A one-line batch should have SinglePayment token type');
        Assert.AreEqual('Test Creditor 1', Format(TempIntBatchDisplay."Account Name"), 'A one-line batch header should show the creditor name');
    end;
```

### F061

- Mutants:
  - 4533: `TempBatchPaymentEntry.FindFirst()` -> `true` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:136)
  - 4534: `TempBatchPaymentEntry.FindFirst()` -> `false` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:136)
  - 4535: `LineCount = 1` -> `LineCount <> 1` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:145)
  - 4536: `LineCount = 1` -> `true` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:145)
  - 4544: `exit(StrSubstNo(BulkPaymentLbl, LineCount))` -> `` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:188)
- Verdict: new-test
- Change: new-test
- Target procedure: TestBuildBatchDisplay_BulkBatch_HeaderUsesFirstEntryAndPaymentCount
- Confidence: medium
- Rationale: Line 136 (FindFirst copies the first entry's Bank Account No./Currency/Posting Date to the header), line 145 (LineCount = 1 chooses the single description), line 188 (bulk description '%1 payments'). Existing multi-line tests check only entry type, token type, amount and linkage, never the header's Account Name, Currency Code or Bal. Account No.; all entries there share one currency so first and last entry cannot be told apart.
- Expected effect: Fails on mutant 4534 because the header Currency Code / Bal. Account No. stay blank; fails on 4533 because the header takes the currency of the last-inserted entry (USD) instead of the first (EUR); fails on 4535/4536 because the 3-line header is named after the creditor instead of '3 payments'; fails on 4544 because the bulk description is ''; passes on the original.

```al
    [Test]
    procedure TestBuildBatchDisplay_BulkBatch_HeaderUsesFirstEntryAndPaymentCount()
    var
        Bank: Record "CTS-CB Bank";
        BankAccComSetup: Record "CTS-CB Bank Acc. Com. Setup";
        BulkPaymentRule: Record "CTS-CB Bulk Payment Rule";
        TempIntBatchDisplay: Record "CTS-CB Int. Batch Display" temporary;
        TempPaymentEntry: Record "CTS-CB Payment Entry" temporary;
        IntBatchDispBldr: Codeunit "CTS-CB Int. Batch Disp Bldr";
        IntBatchStrategy: Codeunit "CTS-CB Int. Batch Strategy";
    begin
        // [SCENARIO] The header of a multi-line batch takes common fields from the first entry and is named after the payment count

        // [GIVEN] 3 payment entries in one batch; the first has currency EUR, the others USD
        Initialize();
        CreateTestBank(Bank);
        CreateTestBankAccComSetup(BankAccComSetup);
        CreateBulkPaymentRule(BulkPaymentRule, Bank.Code, 1, 100, 1000000);
        CreateTempPaymentEntry(TempPaymentEntry, CopyStr(Bank.Code, 1, 20), 100);
        CreateTempPaymentEntry(TempPaymentEntry, CopyStr(Bank.Code, 1, 20), 200);
        CreateTempPaymentEntry(TempPaymentEntry, CopyStr(Bank.Code, 1, 20), 300);
        TempPaymentEntry.SetFilter("Entry No.", '>1');
        TempPaymentEntry.ModifyAll(Currency, 'USD');
        TempPaymentEntry.Reset();

        // [WHEN] BuildBatchDisplay is called
        IntBatchDispBldr.BuildBatchDisplay(TempPaymentEntry, Bank, IntBatchStrategy, TempIntBatchDisplay, BankAccComSetup);

        // [THEN] The header shows the first entry's common fields and the payment count
#pragma warning disable AA0210 // Key not necessary due to table size.
        TempIntBatchDisplay.SetRange("Entry Type", "CTS-CB Batch Entry Type"::Header);
#pragma warning restore AA0210
        TempIntBatchDisplay.FindFirst();
        Assert.AreEqual("CTS-CB Int. Token Type"::BulkPayment, TempIntBatchDisplay."Token Type", 'A three-line batch should have BulkPayment token type');
        Assert.AreEqual('3 payments', Format(TempIntBatchDisplay."Account Name"), 'A multi-line batch header should show the payment count');
        Assert.AreEqual('EUR', Format(TempIntBatchDisplay."Currency Code"), 'Header currency should come from the first entry');
        Assert.AreEqual(Format(CopyStr(Bank.Code, 1, 20)), Format(TempIntBatchDisplay."Bal. Account No."), 'Header bal. account should come from the first entry');
    end;
```

## Test codeunit 95155 CTS-CB Test Auth Share Detect

File: Authentication/TestAuthShareDetect.Codeunit.al

### F001

- Mutants:
  - 140: `not CoreMgt.IsAppActiveInCompany(TargetCompany)` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:69)
  - 141: `exit` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:71)
- Verdict: new-test
- Change: new-test
- Target procedure: MutA_DetectInCompany_TargetNotActivated_AnnotatesNotActivatedAndStops
- Confidence: medium
- Rationale: Line 69 (`if not CoreMgt.IsAppActiveInCompany(TargetCompany)`) and its `exit` on line 71 are only ever exercised with an activated company: the sole DetectInCompany test calls the fixture Setup, which activates the company, so the NotActivated branch is never taken and AnnotatePlaceholderAsNotActivated is never asserted.
- Expected effect: Fails on mutant 140 (condition forced false) because detection then proceeds, the fake HTTP client is called and the placeholder becomes SystemNotMapped instead of NotActivated; fails on mutant 141 (exit deleted) because the source entry, bank and account exist, so detection continues after the annotation and overwrites it; passes on the original, which annotates NotActivated and exits before any lookup.

```al
    [Test]
    procedure MutA_DetectInCompany_TargetNotActivated_AnnotatesNotActivatedAndStops()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        LibraryActivationMgt: Codeunit "CTS-CB Library Activation Mgt.";
        SourceEntryNo: Integer;
        CurrentCo: Text[30];
    begin
        // [Scenario] The target company is not activated: detection must only annotate the placeholder
        // and stop. It must not probe bank accounts (no HTTP) or overwrite the annotation.

        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();
        CurrentCo := CopyStr(CompanyName(), 1, 30);
        SourceEntryNo := SeedDetectionPocFixture();
        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, '{"name":"DetectPocBank","country-code":"DK"}');
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, CurrentCo);

        // [Given] The target company is deactivated after the seed (source entry, bank and an unbound account exist).
        LibraryActivationMgt.DeactivateCompany();

        // [When] DetectInCompany runs against the deactivated company.
        AuthShareDetection.DetectInCompany(SourceEntryNo, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // Restore the activation so later tests are unaffected, even if an assertion below fails.
        LibraryActivationMgt.ActivateCompany();

        // [Then] The placeholder is annotated NotActivated, nothing else is written and no lookup ran.
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'Expected exactly one row');
        AssertRow(TempAuthShareTarget, '', Enum::"CTS-CB Share Target Annotation"::NotActivated, 0, '');
        Assert.IsFalse(FakeHTTPClient.WasCalled(), 'No bank lookup may run for a company where the app is not activated.');
    end;
```

### F002

- Mutants:
  - 151: `SourceBank.Code = ''` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:85)
  - 152: `exit` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:86)
- Verdict: new-test
- Change: new-test
- Target procedure: MutA_DetectInCompany_SourceBankCodeBlank_LeavesPlaceholderUntouched
- Confidence: high
- Rationale: Lines 85-86 (`if SourceBank.Code = '' then exit`) are never reached with an empty source bank: the only DetectInCompany test seeds a valid source bank, so the early exit is never taken. [rev 1: reordered var declarations for AA0021]
- Expected effect: Fails on mutant 151 (condition forced false) and mutant 152 (exit deleted) because detection continues with an empty source bank, calls the fake HTTP client and turns the placeholder into a SystemNotMapped row; passes on the original, which exits at line 86 leaving the NeedsDetection placeholder and making no HTTP call.

```al
    [Test]
    procedure MutA_DetectInCompany_SourceBankCodeBlank_LeavesPlaceholderUntouched()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        AuthenticationEntry: Record "CTS-CB Authentication Entry";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        SourceEntryNo: Integer;
        CurrentCo: Text[30];
    begin
        // [Scenario] The source authentication entry has no bank code, so no source bank can be
        // resolved. Detection must abort (the guard after ResolveAccessibleSourceCompany) without
        // probing accounts or touching the placeholder.

        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();
        CurrentCo := CopyStr(CompanyName(), 1, 30);
        SourceEntryNo := SeedDetectionPocFixture();
        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, '{"name":"DetectPocBank","country-code":"DK"}');
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, CurrentCo);

        // [Given] The source entry loses its bank code.
        AuthenticationEntry.Get(SourceEntryNo);
        AuthenticationEntry."Bank Code" := '';
        AuthenticationEntry.Modify();

        // [When]
        AuthShareDetection.DetectInCompany(SourceEntryNo, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // [Then] The placeholder is unchanged and no lookup ran.
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'Expected exactly one row');
        AssertRow(TempAuthShareTarget, '', Enum::"CTS-CB Share Target Annotation"::NeedsDetection, 0, '');
        Assert.IsFalse(FakeHTTPClient.WasCalled(), 'No bank lookup may run when the source bank cannot be resolved.');
    end;
```

### F003

- Mutants:
  - 153: `BankAccount.FindSet()` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:94)
- Verdict: new-test
- Change: new-test
- Target procedure: MutA_DetectInCompany_NoUnboundAccounts_BecomesNoMatchingAccounts
- Confidence: high
- Rationale: Line 94 (`if BankAccount.FindSet() then`) is only ever true in the existing test, which always seeds one unbound account, so the no-accounts path is not covered. [rev 1: reordered var declarations for AA0021]
- Expected effect: Fails on mutant 153 (FindSet forced true) because the loop body then runs once on an empty Bank Account record (blank IBAN and branch), counts it as a missing-info failure and the placeholder becomes DetectionFailed; passes on the original, where the placeholder becomes NoMatchingAccounts with Account Count 0.

```al
    [Test]
    procedure MutA_DetectInCompany_NoUnboundAccounts_BecomesNoMatchingAccounts()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        BankAccount: Record "Bank Account";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        SourceEntryNo: Integer;
        CurrentCo: Text[30];
    begin
        // [Scenario] The target company has no unbound bank accounts. FindSet must be false, no
        // account is probed and the placeholder becomes NoMatchingAccounts.

        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();
        CurrentCo := CopyStr(CompanyName(), 1, 30);
        SourceEntryNo := SeedDetectionPocFixture();
        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, '{"name":"DetectPocBank","country-code":"DK"}');
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, CurrentCo);

        // [Given] Every bank account is removed again.
        BankAccount.DeleteAll();

        // [When]
        AuthShareDetection.DetectInCompany(SourceEntryNo, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // [Then] NoMatchingAccounts (not DetectionFailed) and no lookup.
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'Expected exactly one row');
        AssertRow(TempAuthShareTarget, '', Enum::"CTS-CB Share Target Annotation"::NoMatchingAccounts, 0, '');
        Assert.IsFalse(FakeHTTPClient.WasCalled(), 'No bank lookup may run when there are no unbound accounts.');
    end;
```

### F004

- Mutants:
  - 157: `MissingInfo` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:113)
  - 158: `MissingInfo` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:113)
  - 173: `(BankAccount.IBAN = '') and (BankAccount."Bank Branch No." = '')` -> `(BankAccount.IBAN = '') and (BankAccount."Bank Branch No." <> '')` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:204)
  - 176: `(BankAccount.IBAN = '') and (BankAccount."Bank Branch No." = '')` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:204)
- Verdict: new-test
- Change: new-test
- Target procedure: MutA_DetectInCompany_FailedAccounts_SplitHttpAndMissingInfoCounts
- Confidence: medium
- Rationale: Line 113 (`if MissingInfo then`) and line 204 (the blank IBAN and blank branch test in ResolveBankCodeForAccount) are never exercised with a failing account: the existing test only has one account that resolves, so neither failure counter is ever incremented and no DetectionFailed message is checked. [rev 1: reordered var declarations for AA0021] [rev 2: answers "Account Count mismatch. Expected 2, Actual 1" on the original. Root cause: FakeHTTPClient.SetShouldFail is a no-op on this path, because BankInformation.TryGetBankInfoFromIBAN ignores the GetUtility return value and parses the canned (success) response, and the DK IBAN can also be served from the Bank Information cache or the DK branch fallback; so BA-DETECT-POC resolved and only the missing-info account failed. Fix: the canned response is now unparseable ('not-json', so TryReadSuccessResponse fails), the seeded account gets a non-DK IBAN (DE89370400440532013000, country DE) that is never cached and has no branch fallback, and SetShouldFail was removed. Original now yields 1 lookup failure + 1 missing-info = 2; mutants 157/158/173/176 still change the split in the message.]
- Expected effect: Passes on the original: BA-DETECT-POC (DE IBAN, unparseable response) fails the lookup with MissingInfo false and BA-DETECT-MISS (no IBAN, no branch) sets MissingInfo, giving 2 of 2 failed, 1 lookup / 1 missing. Fails on mutant 157 (MissingInfo forced true: 0 lookup / 2 missing); on mutant 158 (forced false: 2 lookup / 0 missing); on mutants 173 and 176 because the blank account no longer sets MissingInfo, goes to GetBankAccInfo, fails LookupInfoPresent and counts as a lookup failure (2 lookup / 0 missing). Account Count stays 2 in every case; the Outcome Message assertion kills.

```al
    [Test]
    procedure MutA_DetectInCompany_FailedAccounts_SplitHttpAndMissingInfoCounts()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        BankAccount: Record "Bank Account";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        MissingInfoAccountNoTok: Label 'BA-DETECT-MISS', Locked = true;
        LookupFailAccountNoTok: Label 'BA-DETECT-POC', Locked = true;
        LookupFailIbanTok: Label 'DE89370400440532013000', Locked = true;
        UnparseableBodyTok: Label 'not-json', Locked = true;
        ExpectedMessage: Text;
        SourceEntryNo: Integer;
        CurrentCo: Text[30];
    begin
        // [Scenario] One unbound account has no IBAN/branch (missing info) and one fails on the
        // lookup (unparseable response). The DetectionFailed message reports the two counts separately.

        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();
        CurrentCo := CopyStr(CompanyName(), 1, 30);
        SourceEntryNo := SeedDetectionPocFixture();
        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, UnparseableBodyTok);
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, CurrentCo);

        // [Given] The seeded account gets a non-DK IBAN that is in no Bank Information cache, so the IBAN
        // lookup has to parse the unparseable response and fails, and no DK branch fallback applies.
        BankAccount.Get(LookupFailAccountNoTok);
        BankAccount.IBAN := LookupFailIbanTok;
        BankAccount."Country/Region Code" := 'DE';
        BankAccount.Modify();

        // [Given] A second unbound account without IBAN and branch.
        BankAccount.Init();
        BankAccount."No." := MissingInfoAccountNoTok;
        BankAccount.Insert();

        // [When]
        AuthShareDetection.DetectInCompany(SourceEntryNo, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // [Then] One DetectionFailed row: 2 failed of 2, 1 lookup failure and 1 missing-info account.
        TempAuthShareTarget.Reset();
        TempAuthShareTarget.SetRange(Annotation, Enum::"CTS-CB Share Target Annotation"::DetectionFailed);
        Assert.IsTrue(TempAuthShareTarget.FindFirst(), 'Expected a DetectionFailed row');
        Assert.AreEqual(2, TempAuthShareTarget."Account Count", 'Account Count mismatch');
        ExpectedMessage := 'Bank detection failed for 2 of 2 bank accounts in this company. 1 accounts had lookup or connection errors, and 1 accounts had missing IBAN or branch information.';
        Assert.AreEqual(ExpectedMessage, TempAuthShareTarget."Outcome Message", 'The failure counts must split into 1 lookup failure and 1 missing-info account.');
    end;
```

### F005

- Mutants:
  - 171: `ResolvedOtherAccountsByBank.ContainsKey(BankCode)` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:179)
- Verdict: new-test
- Change: new-test
- Target procedure: MutA_DetectInCompany_TwoAccountsSameOtherBank_AccountsAccumulate
- Confidence: high
- Rationale: Line 179 (`if ResolvedOtherAccountsByBank.ContainsKey(BankCode)`) is only ever false: the existing DetectInCompany test resolves exactly one account, so the append-to-existing-list branch is never taken. [rev 1: reordered var declarations for AA0021]
- Expected effect: Fails on mutant 171 (ContainsKey forced false) because the second account starts a fresh list and overwrites the first, giving Account Count 1 and only the last account in Resolved Account Nos; passes on the original, which appends and yields Account Count 2 with both accounts.

```al
    [Test]
    procedure MutA_DetectInCompany_TwoAccountsSameOtherBank_AccountsAccumulate()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        BankAccount: Record "Bank Account";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        FirstAccountNoTok: Label 'BA-DETECT-POC', Locked = true;
        SecondAccountNoTok: Label 'BA-DETECT-ALT', Locked = true;
        SourceEntryNo: Integer;
        CurrentCo: Text[30];
    begin
        // [Scenario] Two unbound accounts resolve to the same bank, which does not support the source
        // bank system. Both accounts accumulate under that bank in a single SystemNotMapped row.

        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();
        CurrentCo := CopyStr(CompanyName(), 1, 30);
        SourceEntryNo := SeedDetectionPocFixture();
        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, '{"name":"DetectPocBank","country-code":"DK"}');
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, CurrentCo);

        // [Given] A second unbound account with an IBAN, resolving to the same canned bank.
        BankAccount.Init();
        BankAccount."No." := SecondAccountNoTok;
        BankAccount.IBAN := 'DK1234567890123457';
        BankAccount."Country/Region Code" := 'DK';
        BankAccount.Insert();

        // [When]
        AuthShareDetection.DetectInCompany(SourceEntryNo, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // [Then] One SystemNotMapped row that lists both accounts.
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'Expected exactly one row');
        TempAuthShareTarget.Reset();
        TempAuthShareTarget.SetRange(Annotation, Enum::"CTS-CB Share Target Annotation"::SystemNotMapped);
        Assert.IsTrue(TempAuthShareTarget.FindFirst(), 'Expected a SystemNotMapped row');
        Assert.AreEqual(2, TempAuthShareTarget."Account Count", 'Both accounts must be counted for the bank');
        Assert.IsTrue(StrPos(TempAuthShareTarget."Resolved Account Nos", FirstAccountNoTok) > 0, 'The first account must be listed');
        Assert.IsTrue(StrPos(TempAuthShareTarget."Resolved Account Nos", SecondAccountNoTok) > 0, 'The second account must be listed');
    end;
```

### F006

- Mutants:
  - 161: `MatchingAccounts.Count() > 0` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:120)
  - 193: `(BankCode = '') or (SourceBankSystemCode = '')` -> `(BankCode <> '') or (SourceBankSystemCode = '')` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:249)
  - 194: `(BankCode = '') or (SourceBankSystemCode = '')` -> `(BankCode = '') or (SourceBankSystemCode <> '')` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:249)
  - 196: `(BankCode = '') or (SourceBankSystemCode = '')` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:249)
  - 199: `exit(not BankSystemMapping2.IsEmpty())` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:254)
- Verdict: new-test
- Change: new-test
- Target procedure: MutA_DetectInCompany_ExactCommTypeMapping_BecomesReadyAndLinksAccount
- Confidence: medium
- Rationale: The existing DetectInCompany test never has a Bank System Mapping2 row for the resolved bank, so IsSourceCommTypeSupportedByBank (lines 249-254) always returns false, the exact-match branch (MatchingAccounts.Add, then the line 120 block with EnsureTargetBankFromSource/LinkBankAccountsToBank) is never run and nothing asserts the Ready outcome or the account link. [rev 1: reordered var declarations for AA0021]
- Expected effect: Fails on mutants 193, 194 and 196 because the guard on line 249 now exits false for a non-blank bank and system, so the account is no longer an exact match (CommTypeMismatch instead of Ready); fails on mutant 199 (final exit deleted, function returns false) for the same reason; fails on mutant 161 (Count() > 0 forced false) because LinkBankAccountsToBank is skipped and the Bank Account keeps a blank CTS-CB Bank Code; passes on the original (Ready, account linked to DETECT-SRC).

```al
    [Test]
    procedure MutA_DetectInCompany_ExactCommTypeMapping_BecomesReadyAndLinksAccount()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        BankAccount: Record "Bank Account";
        BankSystemMapping2: Record "CTS-CB Bank System Mapping2";
        TempBank: Record "CTS-CB Bank" temporary;
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        SourceBankTok: Label 'DETECT-SRC', Locked = true;
        SourceSystemTok: Label 'DETECT-SYS', Locked = true;
        AccountNoTok: Label 'BA-DETECT-POC', Locked = true;
        ResolvedBankNameTok: Label 'DetectPocBank', Locked = true;
        ResolvedBankCode: Code[30];
        SourceEntryNo: Integer;
        CurrentCo: Text[30];
    begin
        // [Scenario] The resolved bank has a Bank System Mapping2 row for the source bank system with
        // the source's communication type: the account is an exact match, the placeholder becomes
        // Ready and the account is linked to the source bank.

        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();
        CurrentCo := CopyStr(CompanyName(), 1, 30);
        SourceEntryNo := SeedDetectionPocFixture();
        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, '{"name":"DetectPocBank","country-code":"DK"}');
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, CurrentCo);

        TempBank.Init();
        TempBank.Validate(Name, ResolvedBankNameTok);
        ResolvedBankCode := TempBank.Code;

        // [Given] Mapping2 row (resolved bank, source system) with the source bank's Direct comm type.

        BankSystemMapping2.Init();
        BankSystemMapping2."Bank Code" := ResolvedBankCode;
        BankSystemMapping2."Bank System Code" := SourceSystemTok;
        BankSystemMapping2."Supported Communication" := Enum::"CTS-CB Communication Type"::Manual;
        BankSystemMapping2."Import/Export Comm Type" := Enum::"CTS-CB Import/Export Comm Type"::Direct;
        BankSystemMapping2.Insert();

        // [When]
        AuthShareDetection.DetectInCompany(SourceEntryNo, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // [Then] Ready against the source bank, and the account is linked to it.
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'Expected exactly one row');
        AssertRow(TempAuthShareTarget, SourceBankTok, Enum::"CTS-CB Share Target Annotation"::Ready, 1, '');
        BankAccount.Get(AccountNoTok);
        Assert.AreEqual(SourceBankTok, BankAccount."CTS-CB Bank Code", 'The matching account must be linked to the source bank.');
    end;
```

### F007

- Mutants:
  - 186: `(BankCode = '') or (SourceBankSystemCode = '')` -> `(BankCode <> '') or (SourceBankSystemCode = '')` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:232)
  - 187: `(BankCode = '') or (SourceBankSystemCode = '')` -> `(BankCode = '') or (SourceBankSystemCode <> '')` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:232)
  - 189: `(BankCode = '') or (SourceBankSystemCode = '')` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:232)
  - 192: `exit(not BankSystemMapping2.IsEmpty())` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:236)
- Verdict: new-test
- Change: new-test
- Target procedure: MutA_DetectInCompany_SystemMappedWithOtherCommType_BecomesCommTypeMismatch
- Confidence: medium
- Rationale: IsSourceSystemMappedToBank (lines 232-236) is never given a Mapping2 row for the resolved bank, so its guard always passes and its final `exit(not IsEmpty())` always returns false; the CommTypeMismatch outcome of DetectInCompany is not covered end to end. [rev 1: reordered var declarations for AA0021]
- Expected effect: Fails on mutants 186, 187 and 189 because the guard on line 232 wrongly exits false for a non-blank bank and system, so the account falls through to SystemNotMapped; fails on mutant 192 (final exit deleted, function returns false) for the same reason; passes on the original, which finds the Mapping2 row and reports CommTypeMismatch.

```al
    [Test]
    procedure MutA_DetectInCompany_SystemMappedWithOtherCommType_BecomesCommTypeMismatch()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        BankSystemMapping2: Record "CTS-CB Bank System Mapping2";
        TempBank: Record "CTS-CB Bank" temporary;
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        SourceBankTok: Label 'DETECT-SRC', Locked = true;
        SourceSystemTok: Label 'DETECT-SYS', Locked = true;
        ResolvedBankNameTok: Label 'DetectPocBank', Locked = true;
        ResolvedBankCode: Code[30];
        SourceEntryNo: Integer;
        CurrentCo: Text[30];
    begin
        // [Scenario] The resolved bank supports the source bank system but with another communication
        // type than the source's: soft mismatch, placeholder becomes CommTypeMismatch.

        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();
        CurrentCo := CopyStr(CompanyName(), 1, 30);
        SourceEntryNo := SeedDetectionPocFixture();
        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, '{"name":"DetectPocBank","country-code":"DK"}');
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, CurrentCo);

        TempBank.Init();
        TempBank.Validate(Name, ResolvedBankNameTok);
        ResolvedBankCode := TempBank.Code;

        // [Given] Mapping2 row (resolved bank, source system) with Manual while the source bank is Direct.

        BankSystemMapping2.Init();
        BankSystemMapping2."Bank Code" := ResolvedBankCode;
        BankSystemMapping2."Bank System Code" := SourceSystemTok;
        BankSystemMapping2."Supported Communication" := Enum::"CTS-CB Communication Type"::Manual;
        BankSystemMapping2."Import/Export Comm Type" := Enum::"CTS-CB Import/Export Comm Type"::Manual;
        BankSystemMapping2.Insert();

        // [When]
        AuthShareDetection.DetectInCompany(SourceEntryNo, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // [Then] CommTypeMismatch against the source bank.
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'Expected exactly one row');
        AssertRow(TempAuthShareTarget, SourceBankTok, Enum::"CTS-CB Share Target Annotation"::CommTypeMismatch, 1, '');
    end;
```

### F008

- Mutants:
  - 188: `(BankCode = '') or (SourceBankSystemCode = '')` -> `(BankCode = '') and (SourceBankSystemCode = '')` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:232)
  - 190: `(BankCode = '') or (SourceBankSystemCode = '')` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:232)
  - 191: `exit(false)` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:233)
  - 195: `(BankCode = '') or (SourceBankSystemCode = '')` -> `(BankCode = '') and (SourceBankSystemCode = '')` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:249)
  - 197: `(BankCode = '') or (SourceBankSystemCode = '')` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:249)
  - 198: `exit(false)` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:250)
- Verdict: new-test
- Change: new-test
- Target procedure: MutA_DetectInCompany_BlankSourceBankSystem_IgnoresMappingRows
- Confidence: medium
- Rationale: The blank-source-system guards on lines 232-233 and 249-250 never fire in the existing test, because the source entry always has a bank system code; the guard conditions and their `exit(false)` are therefore unobserved. [rev 1: reordered var declarations for AA0021]
- Expected effect: Fails on mutants 188, 190, 191 (system-mapped guard weakened or its exit deleted) and 195, 197, 198 (comm-type guard weakened or its exit deleted) because, without the guard, SetRange on a blank system code matches the blank Mapping2 row, so the account is classified CommTypeMismatch or Ready instead of SystemNotMapped; passes on the original, where both helpers return false for a blank system code.

```al
    [Test]
    procedure MutA_DetectInCompany_BlankSourceBankSystem_IgnoresMappingRows()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        AuthenticationEntry: Record "CTS-CB Authentication Entry";
        BankSystemMapping2: Record "CTS-CB Bank System Mapping2";
        TempBank: Record "CTS-CB Bank" temporary;
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        AccountNoTok: Label 'BA-DETECT-POC', Locked = true;
        ResolvedBankNameTok: Label 'DetectPocBank', Locked = true;
        ResolvedBankCode: Code[30];
        SourceEntryNo: Integer;
        CurrentCo: Text[30];
    begin
        // [Scenario] The source entry has no bank system code. Mapping checks must treat that as
        // "cannot match" even when a Mapping2 row with a blank system code exists for the resolved bank.

        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();
        CurrentCo := CopyStr(CompanyName(), 1, 30);
        SourceEntryNo := SeedDetectionPocFixture();
        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, '{"name":"DetectPocBank","country-code":"DK"}');
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, CurrentCo);

        TempBank.Init();
        TempBank.Validate(Name, ResolvedBankNameTok);
        ResolvedBankCode := TempBank.Code;

        // [Given] The source entry's bank system code is blank, and a Mapping2 row with a blank
        // system code and the source's Direct comm type exists for the resolved bank.
        AuthenticationEntry.Get(SourceEntryNo);
        AuthenticationEntry."Bank System Code" := '';
        AuthenticationEntry.Modify();

        BankSystemMapping2.Init();
        BankSystemMapping2."Bank Code" := ResolvedBankCode;
        BankSystemMapping2."Bank System Code" := '';
        BankSystemMapping2."Supported Communication" := Enum::"CTS-CB Communication Type"::Manual;
        BankSystemMapping2."Import/Export Comm Type" := Enum::"CTS-CB Import/Export Comm Type"::Direct;
        BankSystemMapping2.Insert();

        // [When]
        AuthShareDetection.DetectInCompany(SourceEntryNo, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // [Then] No mapping counts: the account lands in the unmapped-bank bucket (SystemNotMapped).
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'Expected exactly one row');
        AssertRow(TempAuthShareTarget, ResolvedBankCode, Enum::"CTS-CB Share Target Annotation"::SystemNotMapped, 1, AccountNoTok);
    end;
```

### F009

- Mutants:
  - 146: `AuthenticationEntry."Originating Company" <> ''` -> `AuthenticationEntry."Originating Company" = ''` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:79)
  - 148: `AuthenticationEntry."Originating Company" <> ''` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:79)
  - 201: `TryGetSourceBank(PreferredCompany, SourceBankCode, SourceBank)` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:271)
  - 202: `exit(PreferredCompany)` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:272)
- Verdict: new-test
- Change: new-test
- Target procedure: MutA_DetectInCompany_OriginatingCompanyBank_UsesOriginatingCompanyBank
- Confidence: low
- Rationale: The existing test never sets AuthenticationEntry."Originating Company", so line 79 always takes the else branch (current company) and the preferred-company read on lines 271-272 is the same company as the fallback; nothing distinguishes reading the bank from the originating company from reading it from the current one. Environment requirement: two or more companies and WritePermission() true. A silent exit on a missing precondition would pass on every mutant and kill nothing, so the precondition now fails the test. [rev 1: reordered var declarations for AA0021] [rev 2: answers "Test needs a second company" on the original (the environment has one company). The test no longer requires one: like F021 it creates company MUTA-ORIGIN itself (Company.Insert(true), reused if left over) and deletes it (Company.Delete(true)) right after DetectInCompany, before the asserts. No CSC Subscription copy is needed because the target company is the current one; only the source bank is read from MUTA-ORIGIN. A leftover MUTA-ORIG bank there is deleted instead of failing the test.]
- Expected effect: Passes on the original: Originating Company = MUTA-ORIGIN holds MUTA-ORIG with Manual, so SourceCommType = Manual and the Manual Mapping2 row of the resolved bank gives Ready (Account Count 1). Fails on mutants 146 and 148 (line 79 picks the current company), 201 (TryGetSourceBank on the originating company never runs, fallback to current company) and 202 (exit removed, falls through to the current-company read): in each the Direct copy in the current company is used, so the row becomes CommTypeMismatch instead of Ready.

```al
    [Test]
    procedure MutA_DetectInCompany_OriginatingCompanyBank_UsesOriginatingCompanyBank()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        TempBank: Record "CTS-CB Bank" temporary;
        AuthenticationEntry: Record "CTS-CB Authentication Entry";
        BankSystemMapping2: Record "CTS-CB Bank System Mapping2";
        Company: Record Company;
        OriginBank: Record "CTS-CB Bank";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        OriginBankTok: Label 'MUTA-ORIG', Locked = true;
        MutAOriginCompanyTok: Label 'MUTA-ORIGIN', Locked = true;
        SourceSystemTok: Label 'DETECT-SYS', Locked = true;
        ResolvedBankNameTok: Label 'DetectPocBank', Locked = true;
        ResolvedBankCode: Code[30];
        SourceEntryNo: Integer;
        CurrentCo: Text[30];
    begin
        // [Scenario] The source entry originates in another company that holds the source bank with a
        // different default comm type than the copy in the current company. Detection must read the
        // bank from the originating company first. The test creates and deletes that company itself.
        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();
        CurrentCo := CopyStr(CompanyName(), 1, 30);

        // [Given] a second company that is the originating company of the source entry.
        if not Company.Get(MutAOriginCompanyTok) then begin
            Company.Init();
            Company.Name := MutAOriginCompanyTok;
            Company."Display Name" := MutAOriginCompanyTok;
            Company.Insert(true);
        end;

        SourceEntryNo := SeedDetectionPocFixture();
        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, '{"name":"DetectPocBank","country-code":"DK"}');
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, CurrentCo);

        TempBank.Init();
        TempBank.Validate(Name, ResolvedBankNameTok);
        ResolvedBankCode := TempBank.Code;

        // [Given] Source bank copy in the current company is Direct, the originating company's copy is Manual.
        CreateBank(OriginBankTok, 'Originating Source Bank', "CTS-CB Import/Export Comm Type"::Direct);
        OriginBank.ChangeCompany(MutAOriginCompanyTok);
        if OriginBank.Get(OriginBankTok) then
            OriginBank.Delete();
        OriginBank.Init();
        OriginBank.Code := OriginBankTok;
        OriginBank.Name := 'Originating Source Bank';
        OriginBank."Default Import/Export" := "CTS-CB Import/Export Comm Type"::Manual;
        OriginBank.Insert();
        AuthenticationEntry.Get(SourceEntryNo);
        AuthenticationEntry."Bank Code" := OriginBankTok;
        AuthenticationEntry."Originating Company" := MutAOriginCompanyTok;
        AuthenticationEntry.Modify();

        BankSystemMapping2.Init();
        BankSystemMapping2."Bank Code" := ResolvedBankCode;
        BankSystemMapping2."Bank System Code" := SourceSystemTok;
        BankSystemMapping2."Supported Communication" := Enum::"CTS-CB Communication Type"::Manual;
        BankSystemMapping2."Import/Export Comm Type" := Enum::"CTS-CB Import/Export Comm Type"::Manual;
        BankSystemMapping2.Insert();

        // [When]
        AuthShareDetection.DetectInCompany(SourceEntryNo, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // Cleanup of the second company before asserting.
        if Company.Get(MutAOriginCompanyTok) then
            Company.Delete(true);

        // [Then] The Manual comm type of the originating company's bank is used, so the account is an exact match.
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'Expected exactly one row');
        AssertRow(TempAuthShareTarget, OriginBankTok, Enum::"CTS-CB Share Target Annotation"::Ready, 1, '');
    end;
```

### F010

- Mutants:
  - 159: `MatchingAccounts.Count() > 0` -> `MatchingAccounts.Count() >= 0` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:120)
  - 160: `MatchingAccounts.Count() > 0` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:120)
- Verdict: new-test
- Change: new-test
- Target procedure: MutA_DetectInCompany_NoMatchingAccounts_DoesNotCopySourceBankToTarget
- Confidence: low
- Rationale: Line 120 (`if MatchingAccounts.Count() > 0`) guards EnsureTargetBankFromSource, which is a no-op whenever the target company already holds the source bank. In the existing single-company test the source bank is always in the target company, so the guard being false, or `>= 0`, makes no observable difference. Environment requirement: two or more companies and WritePermission() true. A silent exit on a missing precondition would pass on every mutant and kill nothing, so the precondition now fails the test. [rev 1: reordered var declarations for AA0021] [rev 2: answers "Test needs a second company" on the original (the environment has one company). The test no longer requires one: like F021 it creates company MUTA-ORIGIN itself (Company.Insert(true), reused if left over) and deletes it (Company.Delete(true)) right after DetectInCompany, before the asserts. No CSC Subscription copy is needed because the target company is the current one. A leftover MUTA-ORIG bank there is deleted instead of failing the test.]
- Expected effect: Passes on the original: the source bank MUTA-ORIG exists only in MUTA-ORIGIN, the account resolves to DetectPocBank without a Mapping2 row (SystemNotMapped), MatchingAccounts is empty and EnsureTargetBankFromSource is skipped, so MUTA-ORIG is absent in the current company. Fails on mutants 159 (>= 0) and 160 (forced true) because EnsureTargetBankFromSource then inserts MUTA-ORIG into the current (target) company (or errors on the insert), so TargetBank.Get succeeds or the test errors.

```al
    [Test]
    procedure MutA_DetectInCompany_NoMatchingAccounts_DoesNotCopySourceBankToTarget()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        AuthenticationEntry: Record "CTS-CB Authentication Entry";
        Company: Record Company;
        OriginBank: Record "CTS-CB Bank";
        TargetBank: Record "CTS-CB Bank";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        OriginBankTok: Label 'MUTA-ORIG', Locked = true;
        MutAOriginCompanyTok: Label 'MUTA-ORIGIN', Locked = true;
        SourceEntryNo: Integer;
        CurrentCo: Text[30];
    begin
        // [Scenario] No account matches the source bank system, so the source bank must not be copied
        // into the target company. The source bank lives only in the originating company, so a copy into
        // the current (target) company would be visible. The test creates and deletes that company itself.
        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();
        CurrentCo := CopyStr(CompanyName(), 1, 30);

        // [Given] a second company that is the originating company of the source entry.
        if not Company.Get(MutAOriginCompanyTok) then begin
            Company.Init();
            Company.Name := MutAOriginCompanyTok;
            Company."Display Name" := MutAOriginCompanyTok;
            Company.Insert(true);
        end;

        SourceEntryNo := SeedDetectionPocFixture();
        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, '{"name":"DetectPocBank","country-code":"DK"}');
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, CurrentCo);

        // [Given] The source bank exists only in the originating company; no Mapping2 rows exist.
        OriginBank.ChangeCompany(MutAOriginCompanyTok);
        if OriginBank.Get(OriginBankTok) then
            OriginBank.Delete();
        OriginBank.Init();
        OriginBank.Code := OriginBankTok;
        OriginBank.Name := 'Originating Source Bank';
        OriginBank."Default Import/Export" := "CTS-CB Import/Export Comm Type"::Direct;
        OriginBank.Insert();
        AuthenticationEntry.Get(SourceEntryNo);
        AuthenticationEntry."Bank Code" := OriginBankTok;
        AuthenticationEntry."Originating Company" := MutAOriginCompanyTok;
        AuthenticationEntry.Modify();

        // [When]
        AuthShareDetection.DetectInCompany(SourceEntryNo, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // Cleanup of the second company before asserting.
        if Company.Get(MutAOriginCompanyTok) then
            Company.Delete(true);

        // [Then] The detection ran (SystemNotMapped) but the source bank was not copied into the target company.
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'Expected exactly one row');
        Assert.IsTrue(FakeHTTPClient.WasCalled(), 'Detection must have run');
        Assert.IsFalse(TargetBank.Get(OriginBankTok), 'The source bank must not be copied into the target company when no account matches.');
    end;
```

### F011

- Mutants:
  - 203: `(CurrentCompany <> PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank)` -> `(CurrentCompany = PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank)` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:275)
  - 205: `(CurrentCompany <> PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank)` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:275)
  - 206: `(CurrentCompany <> PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank)` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:275)
  - 207: `exit(CurrentCompany)` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:276)
- Verdict: new-test
- Change: new-test
- Target procedure: MutA_DetectInCompany_OriginatingCompanyUnavailable_FallsBackToCurrentCompany
- Confidence: low
- Rationale: The fallback in ResolveAccessibleSourceCompany (lines 274-278) is never reached: the existing test always finds the bank in the preferred company, which is also the current company, so `(CurrentCompany <> PreferredCompany) and TryGetSourceBank(...)` is never evaluated to true and the returned company is never checked. Mutant 204 (and -> or) is analysed separately in F066. [rev 1: reordered var declarations for AA0021]
- Expected effect: Fails on mutants 203, 205 and 206 because the fallback is skipped or taken without reading the bank, so the source bank is not loaded (detection aborts and the placeholder stays NeedsDetection, or the bank name is blank); fails on mutant 207 (exit(CurrentCompany) deleted) because the unreadable company name is returned and the active map is read there, losing the Manual active comm type (error, or CommTypeMismatch); passes on the original (Ready, bank read from the current company).

```al
    [Test]
    procedure MutA_DetectInCompany_OriginatingCompanyUnavailable_FallsBackToCurrentCompany()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        AuthenticationEntry: Record "CTS-CB Authentication Entry";
        BankSystemActiveMap: Record "CTS-CB Bank System Active Map";
        BankSystemMapping2: Record "CTS-CB Bank System Mapping2";
        TempBank: Record "CTS-CB Bank" temporary;
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        SourceBankTok: Label 'DETECT-SRC', Locked = true;
        SourceSystemTok: Label 'DETECT-SYS', Locked = true;
        UnreadableCompanyTok: Label 'MUTA NO SUCH CO', Locked = true;
        ResolvedBankNameTok: Label 'DetectPocBank', Locked = true;
        SourceBankNameTxt: Label 'Detect POC Source Bank', Locked = true;
        ResolvedBankCode: Code[30];
        SourceEntryNo: Integer;
        CurrentCo: Text[30];
    begin
        // [Scenario] The originating company cannot be read (it does not exist here). The source bank
        // is then read from the current company and its active comm type is taken from that company.

        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();
        CurrentCo := CopyStr(CompanyName(), 1, 30);
        SourceEntryNo := SeedDetectionPocFixture();
        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, '{"name":"DetectPocBank","country-code":"DK"}');
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, CurrentCo);

        TempBank.Init();
        TempBank.Validate(Name, ResolvedBankNameTok);
        ResolvedBankCode := TempBank.Code;

        // [Given] The source entry points at an unreadable company; the current company holds the
        // source bank (default Direct) with an active Manual comm type for the source system, and the
        // resolved bank has a Manual Mapping2 row.
        AuthenticationEntry.Get(SourceEntryNo);
        AuthenticationEntry."Originating Company" := UnreadableCompanyTok;
        AuthenticationEntry.Modify();
        BankSystemActiveMap.SetRange("Bank Code", SourceBankTok);
        BankSystemActiveMap.DeleteAll();
        BankSystemActiveMap.Reset();
        BankSystemActiveMap.Init();
        BankSystemActiveMap."Bank Code" := SourceBankTok;
        BankSystemActiveMap."Bank System Code" := SourceSystemTok;
        BankSystemActiveMap.ImportExportCommType := "CTS-CB Import/Export Comm Type"::Manual;
        BankSystemActiveMap.Active := true;
        BankSystemActiveMap.Insert();

        BankSystemMapping2.Init();
        BankSystemMapping2."Bank Code" := ResolvedBankCode;
        BankSystemMapping2."Bank System Code" := SourceSystemTok;
        BankSystemMapping2."Supported Communication" := Enum::"CTS-CB Communication Type"::Manual;
        BankSystemMapping2."Import/Export Comm Type" := Enum::"CTS-CB Import/Export Comm Type"::Manual;
        BankSystemMapping2.Insert();

        // [When]
        AuthShareDetection.DetectInCompany(SourceEntryNo, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // Clean up the active map row before asserting.
        BankSystemActiveMap.Reset();
        BankSystemActiveMap.SetRange("Bank Code", SourceBankTok);
        BankSystemActiveMap.DeleteAll();

        // [Then] Ready against the source bank, named from the bank record read in the current company.
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'Expected exactly one row');
        AssertRow(TempAuthShareTarget, SourceBankTok, Enum::"CTS-CB Share Target Annotation"::Ready, 1, '');
        TempAuthShareTarget.Reset();
        Assert.IsTrue(TempAuthShareTarget.FindFirst(), 'Expected a row');
        Assert.AreEqual(SourceBankNameTxt, TempAuthShareTarget."Target Bank Name", 'The source bank must have been read from the current company.');
    end;
```

### F020

- Mutants:
  - 218: `ToBank.Get(SourceBank.Code)` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:306)
  - 219: `exit` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:307)
  - 227: `not BankAccount.WritePermission()` -> `BankAccount.WritePermission()` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:337)
  - 228: `not BankAccount.WritePermission()` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:337)
  - 231: `BankAccount.Modify()` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:342)
- Verdict: new-test
- Change: new-test
- Target procedure: MutB_DetectInCompany_ExactMatchInSameCompany_LinksAccountAndKeepsSourceBank
- Confidence: medium
- Rationale: Lines 306-307 (ToBank.Get / exit), 337-338 (BankAccount.WritePermission guard) and 342 (BankAccount.Modify) are only reached when MatchingAccounts is non-empty, i.e. an exact or mismatch Mapping2 hit. The only DetectInCompany test (UnboundAccount_EmitsSystemNotMappedRow) has no Mapping2 row, so EnsureTargetBankFromSource and LinkBankAccountsToBank never run and nothing asserts the Bank Account link.
- Expected effect: Fails on mutants 218/219 because ToBank.Get no longer short-circuits and Insert(true) raises a duplicate-record error (target company = source company, so the bank already exists); fails on 227/228 because the guard exits before linking and Bank Account.'CTS-CB Bank Code' stays blank; fails on 231 because Modify is gone and the re-read Bank Account still has a blank bank code; passes on the original where the account is linked and the placeholder becomes Ready.

```al
    [Test]
    procedure MutB_DetectInCompany_ExactMatchInSameCompany_LinksAccountAndKeepsSourceBank()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        TempResolvedBank: Record "CTS-CB Bank" temporary;
        Bank: Record "CTS-CB Bank";
        BankAccount: Record "Bank Account";
        BankSystemMapping2: Record "CTS-CB Bank System Mapping2";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        SourceEntryNo: Integer;
        CurrentCo: Text[30];
        DetectPocSourceBankCodeTok: Label 'DETECT-SRC', Locked = true;
        DetectPocSourceSystemTok: Label 'DETECT-SYS', Locked = true;
        DetectPocBankAccountNoTok: Label 'BA-DETECT-POC', Locked = true;
    begin
        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();
        CurrentCo := CopyStr(CompanyName(), 1, 30);

        // [Given] source AuthEntry + Bank and one unbound BankAccount in the current company, which is also the target.
        SourceEntryNo := SeedDetectionPocFixture();

        // [Given] the bank the canned directory response resolves to supports the source system with the source comm type (Direct).
        TempResolvedBank.Validate(Name, 'DetectPocBank');
        BankSystemMapping2.Init();
        BankSystemMapping2."Bank Code" := TempResolvedBank.Code;
        BankSystemMapping2."Bank System Code" := DetectPocSourceSystemTok;
        BankSystemMapping2."Supported Communication" := Enum::"CTS-CB Communication Type"::Webservice;
        BankSystemMapping2."Import/Export Comm Type" := "CTS-CB Import/Export Comm Type"::Direct;
        BankSystemMapping2.Insert(false);

        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, '{"name":"DetectPocBank","country-code":"DK"}');
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, CurrentCo);

        // [When] DetectInCompany runs end-to-end through the fakes.
        AuthShareDetection.DetectInCompany(SourceEntryNo, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // [Then] the placeholder is Ready against the source bank with the one matched account.
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'Expected exactly one row');
        AssertRow(TempAuthShareTarget, DetectPocSourceBankCodeTok, Enum::"CTS-CB Share Target Annotation"::Ready, 1, '');

        // [Then] the matched account is linked to the source bank, and the existing bank is kept (not re-inserted).
        BankAccount.Get(DetectPocBankAccountNoTok);
        Assert.AreEqual('DETECT-SRC', BankAccount."CTS-CB Bank Code", 'The matched Bank Account must be linked to the source bank.');
        Bank.SetRange(Code, DetectPocSourceBankCodeTok);
        Assert.AreEqual(1, Bank.Count(), 'The source bank must still exist exactly once.');
    end;
```

### F021

- Mutants:
  - 209: `not SourceBank.Get(SourceBankCode)` -> `SourceBank.Get(SourceBankCode)` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:295)
  - 212: `Error(SourceBankUnreadableErr, SourceBankCode, SourceCompany)` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:296)
  - 213: `not ToBank.WritePermission()` -> `ToBank.WritePermission()` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:304)
  - 214: `not ToBank.WritePermission()` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:304)
  - 217: `ToBank.Get(SourceBank.Code)` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:306)
  - 220: `ToBank.Insert(true)` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:309)
- Verdict: new-test
- Change: new-test
- Target procedure: MutB_DetectInCompany_ExactMatchInOtherCompany_CopiesSourceBankAndLinksAccount
- Confidence: low
- Rationale: Lines 295-296 (TryGetSourceBank Get/Error) only matter when the bank is missing in the preferred company, and lines 304-309 (EnsureTargetBankFromSource WritePermission guard, ToBank.Get, ToBank.Insert) only matter when the target company lacks the bank. Every existing test runs with target = source = current company, so the preferred-company read always succeeds and ToBank.Get always finds the bank; the mutated branches are never distinguishable. Environment requirement: the test creates its own second company, so it needs WritePermission() true and an installed CSC Subscription for Continia Banking in the current company (FindFirst raises an error otherwise); it has no silent exit that could skip it. The reviewer's silent-exit remark does not apply to this procedure (only F009/F010 had one).
- Expected effect: Fails on mutants 209/212 because the originating (empty) company wrongly counts as a successful source read, the fallback to the current company is skipped and the source bank/comm type are not resolved (placeholder is not Ready, or detection exits); fails on 213/214/217/220 because the source bank is never inserted into the target company (TargetBank.Get fails, account not linked); passes on the original which falls back to the current company and copies the bank.

```al
    [Test]
    procedure MutB_DetectInCompany_ExactMatchInOtherCompany_CopiesSourceBankAndLinksAccount()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        TempResolvedBank: Record "CTS-CB Bank" temporary;
        AuthenticationEntry: Record "CTS-CB Authentication Entry";
        BankSystemMapping2: Record "CTS-CB Bank System Mapping2";
        Company: Record Company;
        CSCSubscription: Record "CSC Subscription";
        TargetCSCSubscription: Record "CSC Subscription";
        TargetBank: Record "CTS-CB Bank";
        TargetBankAccount: Record "Bank Account";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        CoreMgt: Codeunit "CTS-CB Core Mgt.";
        SourceEntryNo: Integer;
        MutBTargetCompanyTok: Label 'MUTB-TARGET', Locked = true;
        DetectPocSourceBankCodeTok: Label 'DETECT-SRC', Locked = true;
        DetectPocSourceSystemTok: Label 'DETECT-SYS', Locked = true;
        DetectPocBankAccountNoTok: Label 'BA-DETECT-POC', Locked = true;
        DetectPocIbanTok: Label 'DK1234567890123456', Locked = true;
    begin
        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();

        // [Given] a second, empty company that has Continia Banking activated and one unbound Bank Account.
        if not Company.Get(MutBTargetCompanyTok) then begin
            Company.Init();
            Company.Name := MutBTargetCompanyTok;
            Company."Display Name" := MutBTargetCompanyTok;
            Company.Insert(true);
        end;
        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, '{"name":"DetectPocBank","country-code":"DK"}');
        CSCSubscription.SetRange("App Code", CoreMgt.ProductCode());
        CSCSubscription.FindFirst();
        TargetCSCSubscription.ChangeCompany(MutBTargetCompanyTok);
        TargetCSCSubscription := CSCSubscription;
        if TargetCSCSubscription.Insert() then;
        TargetBankAccount.ChangeCompany(MutBTargetCompanyTok);
        TargetBankAccount.Init();
        TargetBankAccount."No." := DetectPocBankAccountNoTok;
        TargetBankAccount.IBAN := DetectPocIbanTok;
        TargetBankAccount."Country/Region Code" := 'DK';
        TargetBankAccount.Insert();

        // [Given] the source AuthEntry + Bank live only in the current company; the AuthEntry names the empty target company as its origin, so the source bank is found through the current-company fallback.
        SourceEntryNo := SeedDetectionPocFixture();
        AuthenticationEntry.Get(SourceEntryNo);
        AuthenticationEntry."Originating Company" := MutBTargetCompanyTok;
        AuthenticationEntry.Modify();

        // [Given] the resolved bank supports the source system with the source comm type (Direct).
        TempResolvedBank.Validate(Name, 'DetectPocBank');
        BankSystemMapping2.Init();
        BankSystemMapping2."Bank Code" := TempResolvedBank.Code;
        BankSystemMapping2."Bank System Code" := DetectPocSourceSystemTok;
        BankSystemMapping2."Supported Communication" := Enum::"CTS-CB Communication Type"::Webservice;
        BankSystemMapping2."Import/Export Comm Type" := "CTS-CB Import/Export Comm Type"::Direct;
        BankSystemMapping2.Insert(false);
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, MutBTargetCompanyTok);

        // [When] detection runs against the second company.
        AuthShareDetection.DetectInCompany(SourceEntryNo, MutBTargetCompanyTok, TempAuthShareTarget, IHttpFactory);

        // [Then] the placeholder is Ready against the source bank.
        AssertRow(TempAuthShareTarget, DetectPocSourceBankCodeTok, Enum::"CTS-CB Share Target Annotation"::Ready, 1, '');

        // [Then] the source bank was copied into the target company and the account there is linked to it.
        TargetBank.ChangeCompany(MutBTargetCompanyTok);
        Assert.IsTrue(TargetBank.Get(DetectPocSourceBankCodeTok), 'The source bank must be copied into the target company.');
        Assert.AreEqual('Detect POC Source Bank', TargetBank.Name, 'The copied bank must carry the source bank name.');
        TargetBankAccount.Get(DetectPocBankAccountNoTok);
        Assert.AreEqual('DETECT-SRC', TargetBankAccount."CTS-CB Bank Code", 'The target Bank Account must be linked to the copied bank.');

        // Cleanup of the second company.
        if Company.Get(MutBTargetCompanyTok) then
            Company.Delete(true);
    end;
```

### F022

- Mutants:
  - 215: `not ToBank.WritePermission()` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:304)
  - 216: `exit` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:305)
  - 229: `not BankAccount.WritePermission()` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:337)
  - 230: `exit` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:338)
- Verdict: new-test
- Change: new-test
- Target procedure: MutB_DetectInCompany_ExactMatchWithReadOnlyPermissions_DoesNotCopyBankOrLinkAccount
- Confidence: medium
- Rationale: Mutants 215/216 (EnsureTargetBankFromSource) and 229/230 (LinkBankAccountsToBank) remove or neutralise the WritePermission() guard. The earlier 'equivalent' verdict assumed every test session runs as SUPER. That premise is wrong: DemoPortal test sessions run in restricted permission mode, and the test app has a permission-lowering library (codeunit 95001 CTS-CB Library Permissions wraps 'Library - Lower Permissions'; that library has SetRead/AddPermissionSet). So the guards are testable by lowering permissions to read-only on CTS-CB Bank / Bank Account, running an exact-match detection against a target company that lacks the bank, and asserting no bank copy, no account link and no error. Caveat (hence low confidence): AuthShareDetection declares Permissions = tabledata "CTS-CB Bank" = RIM, "Bank Account" = RM, and effective permissions are the union, so WritePermission() may still be true. APPLIER: run F020 first; its outcome shows whether WritePermission() is true in these sessions. If it is true here even with lowered user permissions, this test fails on the original too, and 215/216/229/230 are equivalent in practice: drop this test and revert F022 to equivalent. [rev 1: answers fails-on-original 'Sorry, the current permissions prevented the action. (TableData 71553585 CTS-CB Bank Information ... Insert)'. Cause: AUT code, not a fake. DetectInCompany -> ResolveBankCodeForAccount -> BankInfoLookup.GetBankInfo -> UpdateAccountInfo.GetBankAccInfo -> BankInformation codeunit TryGetBankInfoFromIBAN caches every IBAN lookup with BankInformation.Insert(true) in the current company on a cache miss; that codeunit has no Permissions property and the lowered set ('CTS CB Base Read') grants Bank Information = R only. Fix: seed the cache row (IBAN, Name 'DetectPocBank', Country DK, Check Successful) under SUPER before lowering permissions, the same pattern as BankInfoLookupUT.SeedBankInformationCache; TryGetBankInfoFromIBAN then returns from BankInformation.FindFirst() with no write, RegisterUsage is skipped, ImportBank exits on the fake's empty ETag, and the rest of the path up to the guards is reads or temporary records. The target account gets its own IBAN (DK5000400440116243) so the seeded row cannot collide with other tests' cached IBAN DK1234567890123456; setup now deletes a leftover target bank/account first, and the test asserts the Ready row (proves the exact match reached the guards) and removes the cache row at the end. Guard observability: WritePermission() can be false here. Microsoft docs (Record.WritePermission) define write permission as Insert, Delete and Modify; the codeunit grants Bank RIM and Bank Account RM, never D. The Permissions-property docs ('Example - Indirect Permission' table) state that the property only lifts indirect user permissions to success: with no user permission it still gives a runtime error, so it does not add rights to a read-only user. With SetRead the user has R only on Bank and Bank Account, so both guards return false on the original, and under 215/216/229/230 the unguarded Insert/Modify raises a permission error (or links the account), failing the test. Residual risk (hence medium): another write on the lookup path that the first run did not reach because it stopped at the Bank Information insert.]
- Expected effect: Passes on the original: the cached IBAN lookup makes detection write nothing before the guards, the exact match makes the placeholder Ready against DETECT-SRC with 1 account, WritePermission() is false for the read-only session so both procedures exit, no bank is copied into MUTB-NOWRITE and the account stays unlinked. Fails on 215/216: the guard no longer exits, ToBank.Get misses in the target company and ToBank.Insert(true) raises a permission error (or, if it were allowed, TargetBank.Get succeeds and the IsFalse assert fails). Fails on 229/230: the guard no longer exits and BankAccount.Modify raises a permission error (or links the account, failing the AreEqual assert).

```al
    [Test]
    procedure MutB_DetectInCompany_ExactMatchWithReadOnlyPermissions_DoesNotCopyBankOrLinkAccount()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        TempResolvedBank: Record "CTS-CB Bank" temporary;
        AuthenticationEntry: Record "CTS-CB Authentication Entry";
        BankInformation: Record "CTS-CB Bank Information";
        BankSystemMapping2: Record "CTS-CB Bank System Mapping2";
        Company: Record Company;
        CSCSubscription: Record "CSC Subscription";
        TargetCSCSubscription: Record "CSC Subscription";
        TargetBank: Record "CTS-CB Bank";
        TargetBankAccount: Record "Bank Account";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        AuthShareHttpFixture: Codeunit "CTS-CB Auth Share Http Fixture";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        FakeHTTPClient: Codeunit "CTS-CB Fake HTTP Client";
        FakeIHttpResponse: Codeunit "CTS-CB FakeIHttpResponse";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        LibraryLowerPermissions: Codeunit "Library - Lower Permissions";
        CoreMgt: Codeunit "CTS-CB Core Mgt.";
        SourceEntryNo: Integer;
        MutBTargetCompanyTok: Label 'MUTB-NOWRITE', Locked = true;
        DetectPocSourceBankCodeTok: Label 'DETECT-SRC', Locked = true;
        DetectPocSourceSystemTok: Label 'DETECT-SYS', Locked = true;
        DetectPocBankAccountNoTok: Label 'BA-DETECT-POC', Locked = true;
        MutBNoWriteIbanTok: Label 'DK5000400440116243', Locked = true;
    begin
        // [Scenario] The session has only read permission on CTS-CB Bank and Bank Account. Detection must
        // skip the bank copy and the account link silently (WritePermission guards) instead of raising a
        // permission error.
        LibraryPermissions.SetSuperPermissions();
        CleanupDetectionTables();

        // [Given] a second company with Continia Banking activated and one unbound Bank Account (own IBAN).
        // Setup is idempotent: a failed earlier run may have left the company, account or a copied bank.
        if not Company.Get(MutBTargetCompanyTok) then begin
            Company.Init();
            Company.Name := MutBTargetCompanyTok;
            Company."Display Name" := MutBTargetCompanyTok;
            Company.Insert(true);
        end;
        AuthShareHttpFixture.Setup(IHttpFactory, FakeHTTPClient, FakeIHttpResponse, '{"name":"DetectPocBank","country-code":"DK"}');
        CSCSubscription.SetRange("App Code", CoreMgt.ProductCode());
        CSCSubscription.FindFirst();
        TargetCSCSubscription.ChangeCompany(MutBTargetCompanyTok);
        TargetCSCSubscription := CSCSubscription;
        if TargetCSCSubscription.Insert() then;
        TargetBank.ChangeCompany(MutBTargetCompanyTok);
        if TargetBank.Get(DetectPocSourceBankCodeTok) then
            TargetBank.Delete();
        TargetBankAccount.ChangeCompany(MutBTargetCompanyTok);
        if TargetBankAccount.Get(DetectPocBankAccountNoTok) then
            TargetBankAccount.Delete();
        TargetBankAccount.Init();
        TargetBankAccount."No." := DetectPocBankAccountNoTok;
        TargetBankAccount.IBAN := MutBNoWriteIbanTok;
        TargetBankAccount."Country/Region Code" := 'DK';
        TargetBankAccount.Insert();

        SourceEntryNo := SeedDetectionPocFixture();
        AuthenticationEntry.Get(SourceEntryNo);
        AuthenticationEntry."Originating Company" := MutBTargetCompanyTok;
        AuthenticationEntry.Modify();

        TempResolvedBank.Validate(Name, 'DetectPocBank');
        BankSystemMapping2.Init();
        BankSystemMapping2."Bank Code" := TempResolvedBank.Code;
        BankSystemMapping2."Bank System Code" := DetectPocSourceSystemTok;
        BankSystemMapping2."Supported Communication" := Enum::"CTS-CB Communication Type"::Webservice;
        BankSystemMapping2."Import/Export Comm Type" := "CTS-CB Import/Export Comm Type"::Direct;
        BankSystemMapping2.Insert(false);
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, MutBTargetCompanyTok);

        // [Given] the IBAN lookup is already cached in CTS-CB Bank Information, so detection makes no
        // database write before the WritePermission guards (a cache miss inserts into Bank Information,
        // which a read-only session may not do).
        BankInformation.SetRange(IBAN, MutBNoWriteIbanTok);
        if not BankInformation.IsEmpty() then
            BankInformation.DeleteAll();
        BankInformation.Reset();
        BankInformation.Init();
        BankInformation.IBAN := MutBNoWriteIbanTok;
        BankInformation.Name := 'DetectPocBank';
        BankInformation."Country/Region Code" := 'DK';
        BankInformation."Check Successful" := true;
        BankInformation.Insert(true);

        // [When] detection runs with read-only permissions (an exact match is found).
        LibraryLowerPermissions.SetRead();
        LibraryLowerPermissions.AddPermissionSet('CTS CB Base Read');
        AuthShareDetection.DetectInCompany(SourceEntryNo, MutBTargetCompanyTok, TempAuthShareTarget, IHttpFactory);
        LibraryPermissions.SetSuperPermissions();

        // [Then] no error occurred (reaching this line), the exact match was found, no bank was copied and the account was not linked.
        AssertRow(TempAuthShareTarget, DetectPocSourceBankCodeTok, Enum::"CTS-CB Share Target Annotation"::Ready, 1, '');
        Assert.IsFalse(TargetBank.Get(DetectPocSourceBankCodeTok), 'The source bank must not be copied without write permission.');
        TargetBankAccount.Get(DetectPocBankAccountNoTok);
        Assert.AreEqual('', TargetBankAccount."CTS-CB Bank Code", 'The Bank Account must not be linked without write permission.');

        // Cleanup of the cached lookup and the second company.
        BankInformation.SetRange(IBAN, MutBNoWriteIbanTok);
        BankInformation.DeleteAll();
        if Company.Get(MutBTargetCompanyTok) then
            Company.Delete(true);
    end;
```

### F024

- Mutants:
  - 222: `not TempAuthShareTarget.FindFirst()` -> `TempAuthShareTarget.FindFirst()` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:319)
  - 223: `not TempAuthShareTarget.FindFirst()` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:319)
  - 226: `TempAuthShareTarget.Modify()` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:327)
- Verdict: new-test
- Change: new-test
- Target procedure: MutB_DetectInCompany_AppNotActivated_AnnotatesPlaceholderAsNotActivated
- Confidence: medium
- Rationale: AnnotatePlaceholderAsNotActivated (lines 319, 327) runs only when CoreMgt.IsAppActiveInCompany is false. No existing test deactivates the company (the fixture always activates it), so the NotActivated annotation, its FindFirst guard and the Modify are never executed.
- Expected effect: Fails on mutants 222/223 because the procedure exits before annotating, leaving the row NeedsDetection; fails on 226 because without Modify the re-read row (AssertRow does Reset + FindFirst) is still NeedsDetection with an empty Outcome Message; passes on the original which persists NotActivated.

```al
    [Test]
    procedure MutB_DetectInCompany_AppNotActivated_AnnotatesPlaceholderAsNotActivated()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        LibraryActivationMgt: Codeunit "CTS-CB Library Activation Mgt.";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        CurrentCo: Text[30];
    begin
        LibraryPermissions.SetSuperPermissions();
        CurrentCo := CopyStr(CompanyName(), 1, 30);

        // [Given] Continia Banking is not active in the target company (the current company, deactivated) and a placeholder row addresses it.
        LibraryActivationMgt.DeactivateCompany();
        InitPlaceholderInCurrentCompany(TempAuthShareTarget, CurrentCo);

        // [When] DetectInCompany runs; the entry no. is irrelevant because detection stops at the activation check.
        AuthShareDetection.DetectInCompany(1, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // [Then] the placeholder row is annotated NotActivated and carries the explanatory message.
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'Expected exactly one row');
        AssertRow(TempAuthShareTarget, '', Enum::"CTS-CB Share Target Annotation"::NotActivated, 0, '');
        Assert.IsTrue(StrPos(TempAuthShareTarget."Outcome Message", CurrentCo) > 0, 'Outcome Message must name the company where the app is not active.');

        LibraryActivationMgt.ActivateCompany();
    end;
```

### F025

- Mutants:
  - 224: `not TempAuthShareTarget.FindFirst()` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:319)
  - 225: `exit` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:321)
- Verdict: new-test
- Change: new-test
- Target procedure: MutB_DetectInCompany_AppNotActivated_NoPlaceholder_LeavesBufferEmpty
- Confidence: medium
- Rationale: Lines 319-321: when the placeholder FindFirst fails, the procedure resets and exits. No test runs the not-activated path at all, so the not-found branch is untested; without the guard or its exit the code falls through to Modify on a non-existent row.
- Expected effect: Fails on mutants 224/225 because execution continues past the missing placeholder into TempAuthShareTarget.Modify() on a row that does not exist, which raises a runtime error; passes on the original which exits cleanly with an empty buffer.

```al
    [Test]
    procedure MutB_DetectInCompany_AppNotActivated_NoPlaceholder_LeavesBufferEmpty()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        IHttpFactory: Codeunit "CTS-CB Http Factory";
        LibraryActivationMgt: Codeunit "CTS-CB Library Activation Mgt.";
        LibraryPermissions: Codeunit "CTS-CB Library Permissions";
        CurrentCo: Text[30];
    begin
        LibraryPermissions.SetSuperPermissions();
        CurrentCo := CopyStr(CompanyName(), 1, 30);

        // [Given] Continia Banking is not active in the target company and the buffer has no placeholder row (defensive case).
        LibraryActivationMgt.DeactivateCompany();

        // [When]
        AuthShareDetection.DetectInCompany(1, CurrentCo, TempAuthShareTarget, IHttpFactory);

        // [Then] detection exits cleanly and does not try to modify a row that does not exist.
        Assert.AreEqual(0, CountRows(TempAuthShareTarget), 'Expected zero rows - there is no placeholder to annotate');

        LibraryActivationMgt.ActivateCompany();
    end;
```

### F027

- Mutants:
  - 232: `TempAuthShareTarget.FindLast()` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:382)
  - 233: `TempAuthShareTarget.FindLast()` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:382)
  - 253: `TotalMatched > 0` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:424)
  - 287: `BankCode = ''` -> `BankCode <> ''` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:618)
  - 288: `BankCode = ''` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:618)
  - 291: `not TempAuthShareTarget.IsEmpty()` -> `TempAuthShareTarget.IsEmpty()` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:624)
  - 293: `not TempAuthShareTarget.IsEmpty()` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:624)
  - 294: `TempAuthShareTarget.DeleteAll()` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:625)
- Verdict: new-test
- Change: new-test
- Target procedure: MutB_UpdatePlaceholderRows_StaleRowForSourceBank_IsRemoved
- Confidence: high
- Rationale: Lines 382/383, 424-425 and 618-625: the closing stale-row cleanup only has an effect when the buffer already holds a regular row for the same (company, bank) before detection. Every existing UpdatePlaceholderRows test starts with just the placeholder, so DeleteStaleRegularRowForSameBank never has anything to delete and its guards, IsEmpty check, DeleteAll and the PreEmissionMaxLineNo snapshot are unobservable. Mutant 232 (COND -> true on the FindLast() at line 382) compiles to a constant, so FindLast() is not executed and PreEmissionMaxLineNo takes the Line No. the caller's record variable already holds. InitPlaceholder/Insert leave that variable on the last row inserted (line 20), which equals the real maximum, so 232 survives. Positioning the variable on the placeholder with Get(10) before the call makes the mutant snapshot 10, so the filter '<>10 & <=10' matches nothing and the stale row 20 survives.
- Expected effect: Fails on mutants 233 (snapshot 0 -> filter Line No. <= 0 matches nothing), 253 (cleanup never called for the source bank), 287/288 (bank code guard exits for a real code), 291/293 (IsEmpty branch inverted or never taken) and 294 (DeleteAll removed) because the stale row 20 survives and CountRows is 2; passes on the original which deletes it and leaves one row. Also fails on mutant 232 because, with the record variable positioned on line 10 by Get(10), PreEmissionMaxLineNo becomes 10 instead of 20, DeleteStaleRegularRowForSameBank finds no stale row and CountRows is 2; on the original FindLast() yields 20 and the stale row is deleted.

```al
    [Test]
    procedure MutB_UpdatePlaceholderRows_StaleRowForSourceBank_IsRemoved()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        SourceBank: Record "CTS-CB Bank";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        ResolvedOtherAccountsByBank: Dictionary of [Code[30], List of [Code[20]]];
        UnidentifiedAccounts: List of [Code[20]];
    begin
        // [Given] A placeholder (line 10) plus a stale row for the source bank left by an earlier discovery (line 20).
        InitPlaceholder(TempAuthShareTarget);
        TempAuthShareTarget.Init();
        TempAuthShareTarget."Line No." := 20;
        TempAuthShareTarget."Target Company" := TargetCompanyTok;
        TempAuthShareTarget."Target Bank Code" := SourceBankCodeTok;
        TempAuthShareTarget.Annotation := Enum::"CTS-CB Share Target Annotation"::Ready;
        TempAuthShareTarget.Insert();
        CreateBank(SourceBankCodeTok, 'Source Bank', "CTS-CB Import/Export Comm Type"::Direct);
        SourceBank.Get(SourceBankCodeTok);

        // Position the caller's record on the placeholder (line 10) so it differs from the last row (line 20).
        TempAuthShareTarget.Get(10);

        // [When] Three accounts matched the source bank exactly.
        AuthShareDetection.UpdatePlaceholderRows(TempAuthShareTarget, TargetCompanyTok, SourceBank, SourceBankSystemTok, "CTS-CB Import/Export Comm Type"::Direct, 3, 0, ResolvedOtherAccountsByBank, UnidentifiedAccounts, 0, 0);

        // [Then] The placeholder became Ready and the stale pre-existing row for the same bank is gone.
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'The stale row for the source bank must be deleted');
        AssertRow(TempAuthShareTarget, SourceBankCodeTok, Enum::"CTS-CB Share Target Annotation"::Ready, 3, '');
    end;
```

### F028

- Mutants:
  - 251: `TotalMatched > 0` -> `TotalMatched >= 0` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:424)
  - 252: `TotalMatched > 0` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:424)
- Verdict: new-test
- Change: new-test
- Target procedure: MutB_UpdatePlaceholderRows_NoMatchedAccounts_KeepsRowForSourceBank
- Confidence: high
- Rationale: Line 424: `if TotalMatched > 0` guards the source-bank cleanup. All tests with TotalMatched = 0 start with a placeholder only, so running the cleanup for the source bank anyway deletes nothing and is invisible.
- Expected effect: Fails on mutants 251 (>= 0) and 252 (true) because DeleteStaleRegularRowForSameBank runs for SRCBANK with TotalMatched = 0 and deletes the pre-existing row 20, leaving one row instead of two; passes on the original which skips the cleanup.

```al
    [Test]
    procedure MutB_UpdatePlaceholderRows_NoMatchedAccounts_KeepsRowForSourceBank()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        SourceBank: Record "CTS-CB Bank";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        ResolvedOtherAccountsByBank: Dictionary of [Code[30], List of [Code[20]]];
        UnidentifiedAccounts: List of [Code[20]];
        AccountsForOtherA: List of [Code[20]];
    begin
        // [Given] A placeholder, an existing row for the source bank (line 20) and accounts resolved only to another bank.
        InitPlaceholder(TempAuthShareTarget);
        TempAuthShareTarget.Init();
        TempAuthShareTarget."Line No." := 20;
        TempAuthShareTarget."Target Company" := TargetCompanyTok;
        TempAuthShareTarget."Target Bank Code" := SourceBankCodeTok;
        TempAuthShareTarget.Annotation := Enum::"CTS-CB Share Target Annotation"::Ready;
        TempAuthShareTarget.Insert();
        CreateBank(SourceBankCodeTok, 'Source Bank', "CTS-CB Import/Export Comm Type"::Direct);
        SourceBank.Get(SourceBankCodeTok);
        CreateBank(OtherBankATok, 'Other Bank A', "CTS-CB Import/Export Comm Type"::Direct);
        AccountsForOtherA.Add('BA-001');
        ResolvedOtherAccountsByBank.Add(OtherBankATok, AccountsForOtherA);

        // [When] No account matched the source bank (ExactMatchCount = MismatchCount = 0).
        AuthShareDetection.UpdatePlaceholderRows(TempAuthShareTarget, TargetCompanyTok, SourceBank, SourceBankSystemTok, "CTS-CB Import/Export Comm Type"::Direct, 0, 0, ResolvedOtherAccountsByBank, UnidentifiedAccounts, 0, 0);

        // [Then] The placeholder became SystemNotMapped and the unrelated row for the source bank is left alone.
        Assert.AreEqual(2, CountRows(TempAuthShareTarget), 'Expected two rows - SystemNotMapped plus the untouched source-bank row');
        AssertSpecificRow(TempAuthShareTarget, OtherBankATok, Enum::"CTS-CB Share Target Annotation"::SystemNotMapped, 1, 'BA-001');
        AssertSpecificRow(TempAuthShareTarget, SourceBankCodeTok, Enum::"CTS-CB Share Target Annotation"::Ready, 0, '');
    end;
```

### F029

- Mutants:
  - 289: `BankCode = ''` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:618)
  - 290: `exit` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:619)
- Verdict: new-test
- Change: new-test
- Target procedure: MutB_UpdatePlaceholderRows_EmptySourceBankCode_KeepsOtherRowsWithoutBank
- Confidence: medium
- Rationale: Lines 618-619: the `BankCode = ''` guard in DeleteStaleRegularRowForSameBank is never exercised with an empty code because every test passes a real source bank, and no other rows without a bank code exist in the buffer to be wrongly deleted.
- Expected effect: Fails on mutants 289 (condition false) and 290 (exit removed) because the cleanup then deletes every other row with an empty Target Bank Code and Line No. <= the snapshot, so row 20 disappears and CountRows is 1; passes on the original which returns immediately for an empty code.

```al
    [Test]
    procedure MutB_UpdatePlaceholderRows_EmptySourceBankCode_KeepsOtherRowsWithoutBank()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        SourceBank: Record "CTS-CB Bank";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        ResolvedOtherAccountsByBank: Dictionary of [Code[30], List of [Code[20]]];
        UnidentifiedAccounts: List of [Code[20]];
    begin
        // [Given] A placeholder (line 10), an unrelated row without a bank code (line 20) and a source bank record that has no code.
        InitPlaceholder(TempAuthShareTarget);
        TempAuthShareTarget.Init();
        TempAuthShareTarget."Line No." := 20;
        TempAuthShareTarget."Target Company" := TargetCompanyTok;
        TempAuthShareTarget."Target Bank Code" := '';
        TempAuthShareTarget.Annotation := Enum::"CTS-CB Share Target Annotation"::DetectionFailed;
        TempAuthShareTarget.Insert();

        // [When] Two accounts matched; the cleanup is asked to run for an empty bank code.
        AuthShareDetection.UpdatePlaceholderRows(TempAuthShareTarget, TargetCompanyTok, SourceBank, SourceBankSystemTok, "CTS-CB Import/Export Comm Type"::Direct, 2, 0, ResolvedOtherAccountsByBank, UnidentifiedAccounts, 0, 0);

        // [Then] An empty bank code never triggers a cleanup: the unrelated row survives.
        Assert.AreEqual(2, CountRows(TempAuthShareTarget), 'Expected two rows - the row without a bank code must not be deleted');
        Assert.IsTrue(TempAuthShareTarget.Get(20), 'The unrelated row without a bank code must survive');
    end;
```

### F032

- Mutants:
  - 258: `TotalAttempted > 0` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:474)
- Verdict: fix
- Change: add-assert
- Target procedure: UpdatePlaceholderRows_UnidentifiedOnly_BecomesDetectionFailed
- Anchor: after line 179
- Confidence: medium
- Rationale: Line 474 selects the detailed failure message when TotalAttempted > 0. UpdatePlaceholderRows_UnidentifiedOnly_BecomesDetectionFailed reaches the line with 4 failed accounts but AssertRow never checks Outcome Message, so forcing the generic DetectionFailedMsg branch goes unnoticed.
- Expected effect: Fails on mutant 258 because the Outcome Message would be the generic 'Bank detection did not return a valid result for any bank account in this company.'; passes on the original which emits the detailed message with 4 of 4 failed (2 HTTP, 2 missing info).

```al
        Assert.AreEqual('Bank detection failed for 4 of 4 bank accounts in this company. 2 accounts had lookup or connection errors, and 2 accounts had missing IBAN or branch information.', TempAuthShareTarget."Outcome Message", 'Outcome Message mismatch');
```

### F033

- Mutants:
  - 271: `SourceLocalBank.Get(ResolvedBankCode)` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:538)
- Verdict: fix
- Change: add-assert
- Target procedure: UpdatePlaceholderRows_SingleOtherBank_BecomesSystemNotMapped
- Anchor: after line 113
- Confidence: high
- Rationale: Line 538: `SourceLocalBank.Get(ResolvedBankCode)` chooses the bank Name over the code as the row caption. UpdatePlaceholderRows_SingleOtherBank_BecomesSystemNotMapped creates OTHERBANKA 'Other Bank A' so the true branch runs, but AssertRow never checks Target Bank Name, so always falling back to the bank code is not noticed.
- Expected effect: Fails on mutant 271 because Target Bank Name would be 'OTHERBANKA' (the code) instead of 'Other Bank A'; passes on the original.

```al
        Assert.AreEqual('Other Bank A', TempAuthShareTarget."Target Bank Name", 'Target Bank Name must be the resolved bank name');
```

### F034

- Mutants:
  - 270: `SourceLocalBank.Get(ResolvedBankCode)` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:538)
- Verdict: new-test
- Change: new-test
- Target procedure: MutB_UpdatePlaceholderRows_UnknownResolvedBank_UsesBankCodeAsName
- Confidence: high
- Rationale: Line 538: the else branch (`BankName := ResolvedBankCode`) runs only when the resolved bank has no local CTS-CB Bank record. All existing tests create every resolved bank first, so the Get always succeeds and the fallback is never exercised.
- Expected effect: Fails on mutant 270 because Get is forced true and BankName becomes the never-loaded SourceLocalBank.Name (empty) instead of 'GHOSTBANK'; passes on the original which uses the code.

```al
    [Test]
    procedure MutB_UpdatePlaceholderRows_UnknownResolvedBank_UsesBankCodeAsName()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        SourceBank: Record "CTS-CB Bank";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        ResolvedOtherAccountsByBank: Dictionary of [Code[30], List of [Code[20]]];
        UnidentifiedAccounts: List of [Code[20]];
        AccountsForGhost: List of [Code[20]];
        GhostBankTok: Label 'GHOSTBANK', Locked = true;
    begin
        // [Given] An account resolved to a bank that has no CTS-CB Bank record in this company.
        InitPlaceholder(TempAuthShareTarget);
        CreateBank(SourceBankCodeTok, 'Source Bank', "CTS-CB Import/Export Comm Type"::Direct);
        SourceBank.Get(SourceBankCodeTok);
        AccountsForGhost.Add('BA-001');
        ResolvedOtherAccountsByBank.Add(GhostBankTok, AccountsForGhost);

        // [When]
        AuthShareDetection.UpdatePlaceholderRows(TempAuthShareTarget, TargetCompanyTok, SourceBank, SourceBankSystemTok, "CTS-CB Import/Export Comm Type"::Direct, 0, 0, ResolvedOtherAccountsByBank, UnidentifiedAccounts, 0, 0);

        // [Then] The SystemNotMapped row falls back to the bank code as its caption.
        Assert.AreEqual(1, CountRows(TempAuthShareTarget), 'Expected exactly one row');
        AssertRow(TempAuthShareTarget, GhostBankTok, Enum::"CTS-CB Share Target Annotation"::SystemNotMapped, 1, 'BA-001');
        Assert.AreEqual('GHOSTBANK', TempAuthShareTarget."Target Bank Name", 'Target Bank Name must fall back to the bank code when no Bank record exists');
    end;
```

### F035

- Mutants:
  - 282: `TempAuthShareTarget.FindLast()` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:583)
- Verdict: new-test
- Change: new-test
- Target procedure: MutB_NextLineNo_SecondEmittedRow_UsesMaxLineNoPlusTen
- Confidence: medium
- Rationale: NextLineNo (line 583, mutant 282 forces the FindLast() condition true) runs in EmitSystemNotMappedRow after Reset() and Init(). Init() keeps the primary key, so the record variable still holds the Line No. it was positioned on. With the condition forced to a constant FindLast() is not executed and LastLineNo is that current Line No., not the buffer maximum. In every existing test the current line equals the maximum or only one row exists, so 282 survives. Here the placeholder (line 10) is consumed by an exact match and an unrelated row sits at line 20, so the original returns 20 + 10 = 30 while the mutant returns 10 + 10 = 20. The earlier 'buffer is never empty so FindLast always succeeds' reasoning overlooked that the constant also skips the positioning.
- Expected effect: Fails on mutant 282 because NextLineNo returns 20 (current Line No. 10 + 10) and Insert() raises a duplicate-key error on the existing row at line 20; passes on the original where FindLast() returns 20, the new row gets line 30 and the buffer holds exactly 3 rows.

```al
    [Test]
    procedure MutB_NextLineNo_SecondEmittedRow_UsesMaxLineNoPlusTen()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        SourceBank: Record "CTS-CB Bank";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        ResolvedOtherAccountsByBank: Dictionary of [Code[30], List of [Code[20]]];
        UnidentifiedAccounts: List of [Code[20]];
        AccountsForOtherA: List of [Code[20]];
        UnrelatedBankTok: Label 'UNRELATED', Locked = true;
    begin
        // [Given] A placeholder (line 10) and an unrelated row for another bank (line 20).
        InitPlaceholder(TempAuthShareTarget);
        TempAuthShareTarget.Init();
        TempAuthShareTarget."Line No." := 20;
        TempAuthShareTarget."Target Company" := TargetCompanyTok;
        TempAuthShareTarget."Target Bank Code" := UnrelatedBankTok;
        TempAuthShareTarget.Annotation := Enum::"CTS-CB Share Target Annotation"::Ready;
        TempAuthShareTarget.Insert();
        CreateBank(SourceBankCodeTok, 'Source Bank', "CTS-CB Import/Export Comm Type"::Direct);
        SourceBank.Get(SourceBankCodeTok);
        CreateBank(OtherBankATok, 'Other Bank A', "CTS-CB Import/Export Comm Type"::Direct);
        AccountsForOtherA.Add('BA-001');
        ResolvedOtherAccountsByBank.Add(OtherBankATok, AccountsForOtherA);

        // [When] One account matched the source bank exactly (consumes the placeholder) and one resolved to another bank (needs a new row).
        AuthShareDetection.UpdatePlaceholderRows(TempAuthShareTarget, TargetCompanyTok, SourceBank, SourceBankSystemTok, "CTS-CB Import/Export Comm Type"::Direct, 1, 0, ResolvedOtherAccountsByBank, UnidentifiedAccounts, 0, 0);

        // [Then] The new row is appended after the highest existing line (20), i.e. at line 30.
        Assert.AreEqual(3, CountRows(TempAuthShareTarget), 'Expected placeholder, unrelated row and one new row');
        Assert.IsTrue(TempAuthShareTarget.Get(30), 'The new SystemNotMapped row must be inserted at max line + 10');
        Assert.AreEqual(OtherBankATok, TempAuthShareTarget."Target Bank Code", 'Line 30 must be the row for the other bank');
        Assert.AreEqual(Enum::"CTS-CB Share Target Annotation"::SystemNotMapped, TempAuthShareTarget.Annotation, 'Annotation mismatch');
    end;
```

### F036

- Mutants:
  - 285: `exit(Total)` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:598)
- Verdict: new-test
- Change: new-test
- Target procedure: MutB_UpdatePlaceholderRows_OtherBankAndUnidentified_FailureMessageCountsOtherBankAccounts
- Confidence: medium
- Rationale: Line 598: CountAccountsInDict's return value feeds OtherBankCount and hence TotalAttempted, which is only visible in the DetectionFailed message text. No test combines resolved-other-bank accounts with failures and checks the message, so returning 0 goes unnoticed.
- Expected effect: Fails on mutant 285 because CountAccountsInDict returns 0, TotalAttempted becomes 1 and the message reads '1 of 1' instead of '1 of 3'; passes on the original.

```al
    [Test]
    procedure MutB_UpdatePlaceholderRows_OtherBankAndUnidentified_FailureMessageCountsOtherBankAccounts()
    var
        TempAuthShareTarget: Record "CTS-CB Auth Share Target" temporary;
        SourceBank: Record "CTS-CB Bank";
        AuthShareDetection: Codeunit "CTS-CB Auth Share Detection";
        ResolvedOtherAccountsByBank: Dictionary of [Code[30], List of [Code[20]]];
        UnidentifiedAccounts: List of [Code[20]];
        AccountsForOtherA: List of [Code[20]];
    begin
        // [Given] Two accounts resolved to another bank and one account could not be resolved (HTTP failure).
        InitPlaceholder(TempAuthShareTarget);
        CreateBank(SourceBankCodeTok, 'Source Bank', "CTS-CB Import/Export Comm Type"::Direct);
        SourceBank.Get(SourceBankCodeTok);
        CreateBank(OtherBankATok, 'Other Bank A', "CTS-CB Import/Export Comm Type"::Direct);
        AccountsForOtherA.Add('BA-001');
        AccountsForOtherA.Add('BA-002');
        ResolvedOtherAccountsByBank.Add(OtherBankATok, AccountsForOtherA);
        UnidentifiedAccounts.Add('BA-X1');

        // [When]
        AuthShareDetection.UpdatePlaceholderRows(TempAuthShareTarget, TargetCompanyTok, SourceBank, SourceBankSystemTok, "CTS-CB Import/Export Comm Type"::Direct, 0, 0, ResolvedOtherAccountsByBank, UnidentifiedAccounts, 1, 0);

        // [Then] Two rows; the DetectionFailed message reports 1 failed out of 3 attempted accounts.
        Assert.AreEqual(2, CountRows(TempAuthShareTarget), 'Expected two rows - SystemNotMapped + DetectionFailed');
        TempAuthShareTarget.SetRange(Annotation, Enum::"CTS-CB Share Target Annotation"::DetectionFailed);
        Assert.IsTrue(TempAuthShareTarget.FindFirst(), 'Expected a DetectionFailed row');
        Assert.AreEqual('Bank detection failed for 1 of 3 bank accounts in this company. 1 accounts had lookup or connection errors, and 0 accounts had missing IBAN or branch information.', TempAuthShareTarget."Outcome Message", 'Outcome Message must count the other-bank accounts as attempted');
        TempAuthShareTarget.Reset();
    end;
```

## Equivalent mutants

### F012

- Mutants:
  - 145: `exit` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:76)
- Verdict: equivalent
- Confidence: high
- Rationale: Line 76 `exit` after a failed AuthenticationEntry.Get. Without it the code continues with an empty Authentication Entry record, whose Bank Code is blank.
- Expected effect: No test can tell the difference: the continuing path resolves the source bank with a blank bank code, SourceBank.Code stays blank and the guard on lines 85-86 exits, leaving the buffer untouched and making no HTTP call, exactly like the original exit on line 76.

### F013

- Mutants:
  - 147: `AuthenticationEntry."Originating Company" <> ''` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:79)
- Verdict: equivalent
- Confidence: medium
- Rationale: Line 79 forced to always take the originating-company branch. The only differing case is a blank Originating Company, which then yields SourceCompany = '' instead of the current company name.
- Expected effect: A blank company name resolves to the current company everywhere SourceCompany is used: Record.ChangeCompany('') and GetActiveCommType (documented 'Blank reads the current company') both read the current company, and a refused read falls back to the current company anyway. Non-blank values behave identically to the original.

### F014

- Mutants:
  - 162: `AccountsAttempted = 0` -> `AccountsAttempted <> 0` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:153)
  - 163: `AccountsAttempted = 0` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:153)
  - 164: `AccountsAttempted = 0` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:153)
  - 165: `exit` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:154)
- Verdict: equivalent
- Confidence: medium
- Rationale: EmitShareDetectionRan lines 153-154 (`if AccountsAttempted = 0 then exit`) only decide whether a telemetry message is logged.
- Expected effect: The only effect of the guard is whether Session.LogMessage telemetry is emitted; AL tests cannot capture telemetry and the procedure changes no record, return value or buffer, so no test can distinguish the mutants. Running the body with zero attempts completes without error.

### F015

- Mutants:
  - 168: `BankCode = ''` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:177)
  - 169: `exit` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:178)
- Verdict: equivalent
- Confidence: high
- Rationale: AppendAccountForBank lines 177-178 guard against a blank BankCode.
- Expected effect: Unreachable: the procedure is only called when ResolveBankCodeForAccount returned true, and that function returns ResolvedBankCode <> '', so BankCode is never blank here.

### F016

- Mutants:
  - 177: `exit(false)` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:206)
- Verdict: equivalent
- Confidence: high
- Rationale: ResolveBankCodeForAccount line 206 `exit(false)` inside the blank IBAN and blank branch block (MissingInfo is already set to true).
- Expected effect: Without the exit the code calls GetBankInfo with a blank IBAN and blank branch; UpdateAccountInfo.LookupInfoPresent returns false for that input, so GetBankInfo returns false and line 210 exits false with MissingInfo still true: same result, and no HTTP call in either case.

### F017

- Mutants:
  - 181: `exit(false)` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:210)
- Verdict: equivalent
- Confidence: high
- Rationale: ResolveBankCodeForAccount line 210 `exit(false)` after a failed GetBankInfo.
- Expected effect: GetBankInfo only returns false while leaving TempBank (a fresh temporary record, never pre-populated) with a blank Code, so the fall-through skips ImportBank, sets ResolvedBankCode to blank and exits with ResolvedBankCode <> '' = false: identical to the original.

### F018

- Mutants:
  - 183: `TempBank.Code <> ''` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:212)
- Verdict: equivalent
- Confidence: high
- Rationale: ResolveBankCodeForAccount line 212 `if TempBank.Code <> '' then ImportBank(...)` forced true.
- Expected effect: The only differing case is TempBank.Code = '', and ImportSetup.ImportBank exits immediately for a blank bank code (`if BankCode = '' then exit`), so nothing changes.

### F019

- Mutants:
  - 208: `exit(PreferredCompany)` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:278)
- Verdict: equivalent
- Confidence: low
- Rationale: ResolveAccessibleSourceCompany line 278 final `exit(PreferredCompany)`: without it the function returns a blank company name.
- Expected effect: The final line is reached only when the bank could not be read from either company; the caller then has SourceBank.Code blank and exits on lines 85-86 before the returned company is used, so the returned value is never observed. Low confidence: if a failed Get leaves the primary key in the record, SourceBank.Code would be non-blank there and the return value would reach GetActiveCommType.

### F023

- Mutants:
  - 221: `ToBank.Insert(true)` -> `ToBank.Insert(false)` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:309)
- Verdict: equivalent
- Confidence: medium
- Rationale: ToBank.Insert(true) vs Insert(false) only differs by running the table's OnInsert trigger and OnBeforeInsert/OnAfterInsert event subscribers. Table CTS-CB Bank has no OnInsert trigger, no table extension and no subscriber in the app, so the RunTrigger flag has no observable effect.
- Expected effect: No test can observe the difference: both calls insert the same row and run no code.

### F030

- Mutants:
  - 249: `not TempAuthShareTarget.Get(PlaceholderLineNo)` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:416)
  - 250: `exit` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:418)
  - 264: `not TempAuthShareTarget.Get(PlaceholderLineNo)` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:480)
  - 265: `exit` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:481)
  - 277: `not TempAuthShareTarget.Get(PlaceholderLineNo)` -> `false` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:547)
  - 278: `exit` -> `` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:548)
- Verdict: equivalent
- Confidence: medium
- Rationale: Each pair guards `if not TempAuthShareTarget.Get(PlaceholderLineNo) then (Reset;) exit` inside a `not PlaceholderConsumed` branch (lines 416-418, 480-481, 547-548). PlaceholderLineNo was read from a row found by FindFirst at lines 388-392 and nothing between there and these branches deletes or renames it (rows are only inserted, or the placeholder itself is modified, which sets PlaceholderConsumed), so Get always succeeds. The `then` branch is unreachable and removing the condition or the exit changes nothing.
- Expected effect: No test can make Get(PlaceholderLineNo) fail while PlaceholderConsumed is false, so original and mutants behave identically.

### F031

- Mutants:
  - 256: `TotalAttempted > 0` -> `TotalAttempted >= 0` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:474)
  - 257: `TotalAttempted > 0` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:474)
- Verdict: equivalent
- Confidence: high
- Rationale: Line 474 `TotalAttempted > 0`: EmitDetectionFailedRow is only called from UpdatePlaceholderRows when TotalFailed > 0, and TotalAttempted = TotalMatched + OtherBankCount + TotalFailed >= TotalFailed, so TotalAttempted is always > 0 there. `>= 0` and `true` are therefore indistinguishable from the original.
- Expected effect: No observable difference: the condition is true for every reachable input.

### F037

- Mutants:
  - 292: `not TempAuthShareTarget.IsEmpty()` -> `true` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:624)
- Verdict: equivalent
- Confidence: high
- Rationale: Line 624 `if not IsEmpty() then DeleteAll()` is a pure optimisation: forcing the condition true always calls DeleteAll(), which on an empty filtered set deletes nothing, so the resulting buffer is identical.
- Expected effect: No observable difference: DeleteAll() on an empty filtered set is a no-op.

### F050

- Mutants:
  - 1901: `not PaymentMthValidator.ShouldUsePaymentMethodMappings(BankAccComSetup."Transaction Type")` -> `false` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:84)
  - 1902: `exit` -> `` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:85)
- Verdict: equivalent
- Confidence: high
- Rationale: Lines 84/85 in PopulatePaymentMethodsWithConflictCheck: with the guard forced false or its exit removed, a transaction type other than Payment/Direct Debit reaches DetectAllConflicts, which only writes to its local temporary buffer, and then CopyPaymentMethodsFromBankSystem, whose first checks (lines 19-23) repeat the same ShouldUsePaymentMethodMappings guard and exit. No data is written either way.
- Expected effect: No test can observe the difference; the original and the mutant leave identical data behind.

### F051

- Mutants:
  - 1908: `not BankSysPmtMthMap.IsEmpty()` -> `true` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:103)
  - 1912: `not BankSysPmtMthMap.IsEmpty()` -> `true` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:117)
- Verdict: equivalent
- Confidence: high
- Rationale: Lines 103 (DeleteMappings) and 117 (CleanupExceptSystem): forcing `not IsEmpty()` to true only calls DeleteAll() on an empty filtered set, which deletes nothing and runs no triggers (DeleteAll() without true). The result is identical to the original.
- Expected effect: No test can observe the difference; the original and the mutant leave identical data behind.

### F052

- Mutants:
  - 1917: `PaymentMethod.FindSet()` -> `true` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:139)
- Verdict: equivalent
- Confidence: high
- Rationale: Line 139: `PaymentMethod.FindSet()` forced true. When no BC Payment Method is linked, the loop body runs once with the cleared PaymentMethod record, so Code is blank and it calls InsertMappingIfNotExists(..., BankSystemPmtMthCode, '') and then exits. That is the same call the fallback on lines 150-152 makes, so the resulting data is identical. Match-case analysis: mutant 1917 only matters when a CTS-CB Payment Method exists but no BC Payment Method links to it. The forced-true FindSet() then runs one blank iteration with the cleared PaymentMethod record, so InsertMappingIfNotExists receives a blank Short PM Code and inserts a blank-short mapping; OnInsert derives the short code (e.g. PM1) for it. Next() on the empty set returns 0, so the loop ends and the exit skips the fallback, which would have made the identical call. Where a mapping already exists the dedupe check exits in both paths. The end state is the same.
- Expected effect: No test can observe the difference; the original and the mutant leave identical data behind.

### F053

- Mutants:
  - 1919: `exit` -> `` (Bank Account/Codeunits/PaymentMethodMapper.Codeunit.al:145)
- Verdict: equivalent
- Confidence: high
- Rationale: Line 145: removing `exit` after the loop lets the fallback InsertMappingIfNotExists(..., '') run. With a blank Short PM Code the duplicate check ignores Short PM Code and only filters on bank account, transaction type and Payment Method Code, which the loop has just inserted, so the fallback always finds an existing mapping and exits without inserting.
- Expected effect: No test can observe the difference; the original and the mutant leave identical data behind.

### F059

- Mutants:
  - 4528: `TempBatchPaymentEntry.FindSet()` -> `true` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:111)
- Verdict: equivalent
- Confidence: medium
- Rationale: Line 111: 'if TempBatchPaymentEntry.FindSet() then' in CreateDisplayRecordsForBatch is forced to true. FindSet only returns false for an empty batch, and CreateDisplayRecordsForBatch is only called from BuildBatchDisplay after the 'TempBatchPaymentEntry.IsEmpty() then exit' check, so the batch is never empty here.
- Expected effect: Not applicable: with a non-empty batch FindSet is true anyway; the record is also already positioned on the first row by FindFirst in CreateHeaderRecord (line 136) which runs just before, so repeat/Next visits the same rows in the same order without FindSet.

### F062

- Mutants:
  - 4541: `TempBatchPaymentEntry.FindFirst()` -> `true` (Bank Communication/Codeunits/Export/IntBatchDispBldr.Codeunit.al:180)
- Verdict: equivalent
- Confidence: medium
- Rationale: Line 180: 'if TempBatchPaymentEntry.FindFirst() then' in GetSinglePaymentDescription forced to true. The procedure is only called from CreateHeaderRecord when LineCount = 1, i.e. the batch holds exactly one row, and CreateHeaderRecord already ran FindFirst on it at line 136.
- Expected effect: Not applicable: with exactly one row FindFirst is true and leaves the buffer on that same row, so exit(Creditor Name) returns the identical value with or without the check.

### F066

- Mutants:
  - 204: `(CurrentCompany <> PreferredCompany) and TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank)` -> `(CurrentCompany <> PreferredCompany) or TryGetSourceBank(CurrentCompany, SourceBankCode, SourceBank)` (Authentication/Codeunit/AuthShareDetection.Codeunit.al:275)
- Verdict: equivalent
- Confidence: low
- Rationale: ResolveAccessibleSourceCompany line 276: `(CurrentCompany <> PreferredCompany) and TryGetSourceBank(...)` mutated to `or`. AL does not short-circuit `and`/`or`: both operands always run (the survival of mutant 201 proves TryGetSourceBank executes as the right operand). Let A = (CurrentCompany <> PreferredCompany) and B = TryGetSourceBank. The two operators differ only when A and B differ. A false and B true needs the same company and a second successful read after the first one failed, which cannot happen. A true and B false is the remaining case: the original falls through to exit(PreferredCompany), the mutant exits with CurrentCompany. In that case SourceBank.Code is blank and the caller exits before using the returned company, unless a failed Get keeps the key in the record (open question, see F019).
- Expected effect: No observable difference unless a failed SourceBank.Get leaves the key in SourceBank.Code; if it does, the returned company reaches GetActiveCommType and the mutant would read the active map from the wrong company. Low confidence until that is confirmed.

