codeunit 50003 "MUT Runner"
{
    // SOAP service 'MUTRunner' (SPEC 6.10.2). Runs test codeunits from a web-service session through
    // "Test Suite Mgt." -> test runner 130450 -> "Test Runner - Mgt", so "MUT Test Hooks" fire unchanged.
    // This session is not a test codeunit, so the runner-nesting refusal does not apply, and it
    // may write Mutation Core's tables.
    Access = Public;
    Permissions = tabledata "AL Test Suite" = rimd,
                  tabledata "Test Method Line" = rimd,
                  tabledata "MUT Mutation Setup" = rim,
                  tabledata "MUT Mutant Result" = rim,
                  tabledata "MUT Runner State" = rimd;

    var
        SuiteName: Code[10];
        StopReasonTxt: Label 'al-mutation: stopping a runaway SOAP runner session (non-terminating mutant)', Locked = true;
        BatchNotFoundErr: Label 'No runner state row exists for batch %1.', Comment = '%1 = batch id';
        BatchFinishedErr: Label 'Batch %1 has already finished.', Comment = '%1 = batch id';
        OwnSessionErr: Label 'Refusing to stop the calling session %1.', Comment = '%1 = session id';
        BatchIdErr: Label 'The batch id must be 1 to 50 characters.';
        MutantIdErr: Label 'Mutant id "%1" is not a positive integer.', Comment = '%1 = the offending list entry';
        StopFailedTxt: Label 'not stopped: %1', Comment = '%1 = error text';

    procedure RunMutants(BatchId: Text; CodeunitIds: Text; MutantIds: Text; RunNo: Integer): Text
    var
        State: Record "MUT Runner State";
        MutantResult: Record "MUT Mutant Result";
        Results: JsonArray;
        Entry: JsonObject;
        MutantIdList: List of [Integer];
        MutantId: Integer;
        Tests: JsonArray;
        Passed: Integer;
        Failed: Integer;
        KillingTest: Text;
        DurationMs: BigInteger;
        ResultText: Text;
    begin
        CheckBatchId(BatchId);
        ParseMutantIds(MutantIds, MutantIdList);

        State.Init();
        State."Batch Id" := CopyStr(BatchId, 1, MaxStrLen(State."Batch Id"));
        State."Session Id" := SessionId();
        State."Run No." := RunNo;
        State."Mutant Id" := 0;
        State.Insert();
        Commit();

        PrepareSuite(CodeunitIds);

        foreach MutantId in MutantIdList do begin
            // A stop was requested (StopRunner) but this session survived StopSession: end without
            // writing anything, not even the active mutant (SPEC 6.10.2).
            if StopRequested(State) then
                exit(StoppedResult(Results));
            State."Mutant Id" := MutantId;
            State."Mutant Started At" := CurrentDateTime();
            State.Modify();
            Commit();

            SetActiveMutant(MutantId, RunNo);

            Clear(Tests);
            RunSuite(Tests, Passed, Failed, KillingTest, DurationMs);

            if StopRequested(State) then
                exit(StoppedResult(Results));

            Clear(Entry);
            Entry.Add('mutantId', MutantId);
            if Passed + Failed = 0 then begin
                Entry.Add('status', 'Empty');
                Entry.Add('killingTest', '');
            end else begin
                if not MutantResult.Get(RunNo, MutantId) then begin
                    MutantResult.Init();
                    MutantResult."Run No." := RunNo;
                    MutantResult."Mutant Id" := MutantId;
                    if Failed > 0 then begin
                        MutantResult.Status := MutantResult.Status::Killed;
                        MutantResult."Killing Test" := CopyStr(KillingTest, 1, MaxStrLen(MutantResult."Killing Test"));
                    end else
                        MutantResult.Status := MutantResult.Status::Survived;
                    MutantResult."Duration Ms" := DurationMs;
                    MutantResult."Recorded At" := CurrentDateTime();
                    MutantResult.Insert();
                end;
                Entry.Add('status', GetStatusName(MutantResult.Status));
                Entry.Add('killingTest', MutantResult."Killing Test");
            end;
            Entry.Add('durationMs', DurationMs);
            Entry.Add('passed', Passed);
            Entry.Add('failed', Failed);
            Results.Add(Entry);

            // Re-read before the write: the row may have been modified by StopRunner meanwhile.
            if StopRequested(State) then
                exit(StoppedResult(Results));
            State."Mutants Done" += 1;
            State.Modify();
            Commit();
        end;

        if StopRequested(State) then
            exit(StoppedResult(Results));
        SetActiveMutant(0, 0);
        State."Mutant Id" := 0;
        State.Finished := true;
        State.Modify();
        DeleteSuite();
        Results.WriteTo(ResultText);
        exit(ResultText);
    end;

    procedure RunTests(CodeunitIds: Text): Text
    var
        Result: JsonObject;
        Tests: JsonArray;
        Passed: Integer;
        Failed: Integer;
        KillingTest: Text;
        DurationMs: BigInteger;
        ResultText: Text;
    begin
        SetActiveMutant(0, 0);
        PrepareSuite(CodeunitIds);
        RunSuite(Tests, Passed, Failed, KillingTest, DurationMs);
        DeleteSuite();

        Result.Add('passed', Passed);
        Result.Add('failed', Failed);
        Result.Add('durationMs', DurationMs);
        Result.Add('tests', Tests);
        Result.WriteTo(ResultText);
        exit(ResultText);
    end;

    procedure GetRunnerState(): Text
    var
        State: Record "MUT Runner State";
        Result: JsonObject;
        Rows: JsonArray;
        Row: JsonObject;
        ResultText: Text;
    begin
        if State.FindSet() then
            repeat
                Clear(Row);
                Row.Add('batchId', State."Batch Id");
                Row.Add('sessionId', State."Session Id");
                Row.Add('runNo', State."Run No.");
                Row.Add('mutantId', State."Mutant Id");
                Row.Add('mutantStartedAt', Format(State."Mutant Started At", 0, 9));
                Row.Add('mutantsDone', State."Mutants Done");
                Row.Add('finished', State.Finished);
                Rows.Add(Row);
            until State.Next() = 0;

        Result.Add('serverNowUtc', Format(CurrentDateTime(), 0, 9));
        Result.Add('rows', Rows);
        Result.WriteTo(ResultText);
        exit(ResultText);
    end;

    procedure StopRunner(BatchId: Text): Text
    var
        State: Record "MUT Runner State";
    begin
        CheckBatchId(BatchId);
        if not State.Get(CopyStr(BatchId, 1, MaxStrLen(State."Batch Id"))) then
            Error(BatchNotFoundErr, BatchId);
        if State.Finished then
            Error(BatchFinishedErr, BatchId);
        if State."Session Id" = SessionId() then
            Error(OwnSessionErr, State."Session Id");
        // Committed before StopSession: a runner that survives the stop exits on its next re-read
        // without writing a result or setting the active mutant.
        State."Stop Requested" := true;
        State.Modify();
        Commit();
        ClearLastError();
        if TryStopSession(State."Session Id") then
            exit('stopped');
        exit(StrSubstNo(StopFailedTxt, GetLastErrorText()));
    end;

    procedure DeleteRunnerState(BatchId: Text): Text
    var
        State: Record "MUT Runner State";
        ALTestSuite: Record "AL Test Suite";
    begin
        CheckBatchId(BatchId);
        if not State.Get(CopyStr(BatchId, 1, MaxStrLen(State."Batch Id"))) then
            exit('not found');
        if ALTestSuite.Get(GetSuiteName(State."Session Id")) then
            ALTestSuite.Delete(true);
        State.Delete();
        Commit();
        exit('deleted');
    end;

    local procedure StopRequested(var State: Record "MUT Runner State"): Boolean
    begin
        // Re-reads the row, so the caller's next Modify works on the current version.
        if not State.Get(State."Batch Id") then
            exit(true);
        exit(State."Stop Requested");
    end;

    local procedure StoppedResult(Results: JsonArray): Text
    var
        ResultText: Text;
    begin
        Results.WriteTo(ResultText);
        exit(ResultText);
    end;

    local procedure GetStatusName(Status: Enum "MUT Mutant Status"): Text
    begin
        // The enum value name (Killed, Survived, ...), not its caption.
        exit(Status.Names().Get(Status.Ordinals().IndexOf(Status.AsInteger())));
    end;

    [TryFunction]
    local procedure TryStopSession(RunnerSessionId: Integer)
    begin
        StopSession(RunnerSessionId, StopReasonTxt);
    end;

    local procedure CheckBatchId(BatchId: Text)
    begin
        if (BatchId = '') or (StrLen(BatchId) > 50) then
            Error(BatchIdErr);
    end;

    local procedure ParseMutantIds(MutantIds: Text; var MutantIdList: List of [Integer])
    var
        MutantIdText: Text;
        MutantId: Integer;
    begin
        foreach MutantIdText in MutantIds.Split(',') do
            if MutantIdText.Trim() <> '' then begin
                if not Evaluate(MutantId, MutantIdText.Trim()) or (MutantId <= 0) then
                    Error(MutantIdErr, MutantIdText);
                MutantIdList.Add(MutantId);
            end;
    end;

    local procedure GetSuiteName(RunnerSessionId: Integer): Code[10]
    begin
        exit(CopyStr('MR' + Format(Abs(RunnerSessionId), 0, 9), 1, 10));
    end;

    local procedure PrepareSuite(CodeunitIds: Text)
    var
        ALTestSuite: Record "AL Test Suite";
        TestSuiteMgt: Codeunit "Test Suite Mgt.";
    begin
        SuiteName := GetSuiteName(SessionId());
        if ALTestSuite.Get(SuiteName) then
            ALTestSuite.Delete(true);
        TestSuiteMgt.CreateTestSuite(SuiteName);
        ALTestSuite.Get(SuiteName);
        TestSuiteMgt.SelectTestMethodsByRange(ALTestSuite, CodeunitIds);
        Commit();
    end;

    local procedure DeleteSuite()
    var
        ALTestSuite: Record "AL Test Suite";
    begin
        if ALTestSuite.Get(SuiteName) then
            ALTestSuite.Delete(true);
        Commit();
    end;

    local procedure SetActiveMutant(MutantId: Integer; RunNo: Integer)
    var
        Setup: Record "MUT Mutation Setup";
    begin
        if not Setup.Get(0) then begin
            Setup.Init();
            Setup."Primary Key" := 0;
            Setup.Insert();
        end;
        Setup."Active Mutant Id" := MutantId;
        Setup."Current Run No." := RunNo;
        // RunTrigger = true: OnModify mirrors the values to the isolated storage the hooks read (S3).
        Setup.Modify(true);
        Commit();
    end;

    local procedure RunSuite(var Tests: JsonArray; var Passed: Integer; var Failed: Integer; var KillingTest: Text; var DurationMs: BigInteger)
    var
        TestMethodLine: Record "Test Method Line";
        TestSuiteMgt: Codeunit "Test Suite Mgt.";
        Test: JsonObject;
        StartedAt: DateTime;
        TestMs: BigInteger;
    begin
        Passed := 0;
        Failed := 0;
        KillingTest := '';

        StartedAt := CurrentDateTime();
        TestMethodLine.SetRange("Test Suite", SuiteName);
        if not TestMethodLine.FindFirst() then // S2: RunAllTests reads "Test Suite" from the record
            exit;
        TestSuiteMgt.RunAllTests(TestMethodLine);
        DurationMs := CurrentDateTime() - StartedAt;

        TestMethodLine.Reset();
        TestMethodLine.SetRange("Test Suite", SuiteName);
        TestMethodLine.SetRange("Line Type", TestMethodLine."Line Type"::"Function");
        TestMethodLine.SetRange(Run, true);
        if TestMethodLine.FindSet() then
            repeat
                Clear(Test);
                Test.Add('codeunit', TestMethodLine."Test Codeunit");
                Test.Add('name', TestMethodLine."Function");
                Test.Add('result', Format(TestMethodLine.Result));
                TestMs := TestMethodLine."Finish Time" - TestMethodLine."Start Time";
                Test.Add('durationMs', TestMs);
                case TestMethodLine.Result of
                    TestMethodLine.Result::Success:
                        Passed += 1;
                    TestMethodLine.Result::Failure:
                        begin
                            Failed += 1;
                            if KillingTest = '' then
                                KillingTest := GetCodeunitName(TestMethodLine."Test Codeunit") + ':' + TestMethodLine."Function";
                        end;
                end;
                Test.Add('error', TestMethodLine."Error Message Preview");
                Tests.Add(Test);
            until TestMethodLine.Next() = 0;
    end;

    local procedure GetCodeunitName(TestCodeunitId: Integer): Text[30]
    var
        CodeunitLine: Record "Test Method Line";
    begin
        // The hook receives the name as Text[30] (SPEC 6.1.4); truncate alike so both writers store the same text.
        CodeunitLine.SetRange("Test Suite", SuiteName);
        CodeunitLine.SetRange("Line Type", CodeunitLine."Line Type"::"Codeunit");
        CodeunitLine.SetRange("Test Codeunit", TestCodeunitId);
        if CodeunitLine.FindFirst() then
            exit(CopyStr(CodeunitLine.Name, 1, 30));
        exit('');
    end;
}
