codeunit 50603 "MUT Spike Suite Runner"
{
    // Mechanism B's body, as an ordinary (non-test) codeunit invoked with Codeunit.Run from
    // driver B. The first attempt wrapped this in a [TryFunction], and BC refused with "Call
    // to the function 'INSERT' is not allowed inside the call to 'RunTests' when it is used as
    // a TryFunction" -- a TryFunction forbids database writes, and building a test suite
    // writes rows. Codeunit.Run with a return value also captures errors, but permits writes.
    Access = Internal;

    trigger OnRun()
    var
        ALTestSuite: Record "AL Test Suite";
        TestMethodLine: Record "Test Method Line";
        TestSuiteMgt: Codeunit "Test Suite Mgt.";
        SuiteName: Code[10];
    begin
        SuiteName := 'MUTSPIKE';
        if ALTestSuite.Get(SuiteName) then
            ALTestSuite.Delete(true);
        TestSuiteMgt.CreateTestSuite(SuiteName);
        ALTestSuite.Get(SuiteName);
        TestSuiteMgt.SelectTestMethodsByRange(ALTestSuite, Format(Codeunit::"MUT Spike Victim"));

        TestMethodLine.SetRange("Test Suite", SuiteName);
        TestSuiteMgt.RunSelectedTests(TestMethodLine);
    end;
}
