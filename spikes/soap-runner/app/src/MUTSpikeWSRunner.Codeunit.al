codeunit 50700 "MUT Spike WS Runner"
{
    // SOAP-runner spike (U-E). Exposed as the SOAP web service 'MUTSpikeRunner' by
    // "MUT Spike WS Install". Runs test codeunits from a web-service session through the
    // standard "Test Suite Mgt." -> test runner 130450 -> "Test Runner - Mgt" chain, the same
    // chain a DemoPortal job uses, so "MUT Test Hooks" fire unchanged. This is not nested
    // inside a test codeunit, so the runner-nesting refusal does not apply.
    //
    // RunMutants discovers the test methods once and then runs the selected tests once per
    // mutant in the same session, which is the in-job mutant loop of SPEC §6.1.6.
    //
    // Timeout spike (T-5): the runner's SOAP session is not listed in "Active Session", so the
    // sessions API cannot stop it. Each call therefore records its SessionId() and current
    // mutant in "MUT Spike Runner State" (committed before each mutant), and StopRunner stops a
    // session by id. Each call uses its own test suite, named after the session, so a call
    // never waits on the locks of a runaway one.
    Access = Public;
    Permissions = tabledata "AL Test Suite" = rimd,
                  tabledata "Test Method Line" = rimd,
                  tabledata "MUT Mutation Setup" = rm,
                  tabledata "MUT Spike Runner State" = rimd;

    var
        SuiteName: Code[10];

    /// Runs one test codeunit, optionally only the functions matching FunctionFilter, with no
    /// mutant active. Returns a JSON object with one entry per test function.
    procedure RunTests(CodeunitId: Integer; FunctionFilter: Text): Text
    var
        Result: JsonObject;
        ResultText: Text;
    begin
        PrepareSuite(CodeunitId, FunctionFilter);
        Result := RunSuiteOnce(0, 0);
        DeleteSuite();
        Result.WriteTo(ResultText);
        exit(ResultText);
    end;

    /// Runs one test codeunit once per mutant in MutantIds (comma-separated). The active
    /// mutant is set through "MUT Mutation Setup", whose triggers mirror it to the isolated
    /// storage the hooks read. The setup is reset to mutant 0 at the end.
    procedure RunMutants(CodeunitId: Integer; FunctionFilter: Text; MutantIds: Text; RunNo: Integer): Text
    var
        Results: JsonArray;
        MutantIdList: List of [Text];
        MutantIdText: Text;
        MutantId: Integer;
        Done: Integer;
        ResultText: Text;
    begin
        PrepareSuite(CodeunitId, FunctionFilter);
        MutantIdList := MutantIds.Split(',');
        foreach MutantIdText in MutantIdList do
            if MutantIdText.Trim() <> '' then begin
                Evaluate(MutantId, MutantIdText.Trim());
                SetState(MutantId, Done, false);
                Results.Add(RunSuiteOnce(MutantId, RunNo));
                Done += 1;
            end;
        SetActiveMutant(0, 0);
        SetState(0, Done, true);
        DeleteSuite();
        Results.WriteTo(ResultText);
        exit(ResultText);
    end;

    /// Returns every runner state row as JSON: sessionId, mutantId, startedAt, mutantsDone,
    /// finished, and whether the session is listed in "Active Session".
    procedure GetState(): Text
    var
        State: Record "MUT Spike Runner State";
        ActiveSession: Record "Active Session";
        Rows: JsonArray;
        Row: JsonObject;
        Caller: JsonObject;
        ResultText: Text;
    begin
        if State.FindSet() then
            repeat
                Clear(Row);
                Row.Add('sessionId', State."Session Id");
                Row.Add('mutantId', State."Mutant Id");
                Row.Add('startedAt', State."Started At");
                Row.Add('mutantsDone', State."Mutants Done");
                Row.Add('finished', State.Finished);
                ActiveSession.SetRange("Session ID", State."Session Id");
                Row.Add('listedInActiveSession', not ActiveSession.IsEmpty());
                Rows.Add(Row);
            until State.Next() = 0;
        Caller.Add('callerSessionId', SessionId());
        Rows.Add(Caller);
        Rows.WriteTo(ResultText);
        exit(ResultText);
    end;

    /// Stops a runner session by id. Refuses the calling session.
    procedure StopRunner(RunnerSessionId: Integer): Text
    begin
        if RunnerSessionId = SessionId() then
            Error('MUT Spike WS Runner: refusing to stop the calling session %1.', RunnerSessionId);
        StopSession(RunnerSessionId, 'al-mutation: stopping a runaway SOAP runner session (non-terminating mutant)');
        exit('stop requested');
    end;

    /// Deletes all runner state rows and every leftover per-session test suite.
    procedure ClearState(): Text
    var
        State: Record "MUT Spike Runner State";
        ALTestSuite: Record "AL Test Suite";
    begin
        State.DeleteAll();
        ALTestSuite.SetFilter(Name, 'MS*');
        ALTestSuite.DeleteAll(true);
        exit('cleared');
    end;

    local procedure PrepareSuite(CodeunitId: Integer; FunctionFilter: Text)
    var
        ALTestSuite: Record "AL Test Suite";
        TestSuiteMgt: Codeunit "Test Suite Mgt.";
    begin
        SuiteName := CopyStr('MS' + DelChr(Format(Abs(SessionId()), 0, 9), '=', '-'), 1, MaxStrLen(SuiteName));
        if ALTestSuite.Get(SuiteName) then
            ALTestSuite.Delete(true);
        TestSuiteMgt.CreateTestSuite(SuiteName);
        ALTestSuite.Get(SuiteName);
        TestSuiteMgt.SelectTestMethodsByRange(ALTestSuite, Format(CodeunitId));
        if FunctionFilter <> '' then
            TestSuiteMgt.SelectTestProceduresByName(SuiteName, FunctionFilter);
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

    local procedure SetState(MutantId: Integer; Done: Integer; IsFinished: Boolean)
    var
        State: Record "MUT Spike Runner State";
    begin
        if not State.Get(SessionId()) then begin
            State.Init();
            State."Session Id" := SessionId();
            State.Insert();
        end;
        State."Mutant Id" := MutantId;
        State."Started At" := CurrentDateTime();
        State."Mutants Done" := Done;
        State.Finished := IsFinished;
        State.Modify();
        Commit();
    end;

    local procedure RunSuiteOnce(MutantId: Integer; RunNo: Integer): JsonObject
    var
        TestMethodLine: Record "Test Method Line";
        TestSuiteMgt: Codeunit "Test Suite Mgt.";
        Result: JsonObject;
        Tests: JsonArray;
        Test: JsonObject;
        Passed: Integer;
        Failed: Integer;
        StartedAt: DateTime;
        ElapsedMs: BigInteger;
    begin
        SetActiveMutant(MutantId, RunNo);
        Commit();

        StartedAt := CurrentDateTime();
        TestMethodLine.SetRange("Test Suite", SuiteName);
        TestMethodLine.FindFirst();
        TestSuiteMgt.RunAllTests(TestMethodLine);

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
                ElapsedMs := TestMethodLine."Finish Time" - TestMethodLine."Start Time";
                Test.Add('ms', ElapsedMs);
                case TestMethodLine.Result of
                    TestMethodLine.Result::Success:
                        Passed += 1;
                    TestMethodLine.Result::Failure:
                        begin
                            Failed += 1;
                            Test.Add('error', TestMethodLine."Error Message Preview");
                        end;
                end;
                Tests.Add(Test);
            until TestMethodLine.Next() = 0;

        Result.Add('mutantId', MutantId);
        Result.Add('passed', Passed);
        Result.Add('failed', Failed);
        ElapsedMs := CurrentDateTime() - StartedAt;
        Result.Add('ms', ElapsedMs);
        Result.Add('tests', Tests);
        exit(Result);
    end;

    local procedure SetActiveMutant(MutantId: Integer; RunNo: Integer)
    var
        Setup: Record "MUT Mutation Setup";
    begin
        Setup.GetOrCreate();
        Setup."Active Mutant Id" := MutantId;
        Setup."Current Run No." := RunNo;
        // RunTrigger = true: OnModify mirrors the values to the isolated storage the hooks read.
        Setup.Modify(true);
    end;
}
