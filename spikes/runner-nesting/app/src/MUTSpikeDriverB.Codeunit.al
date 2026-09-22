codeunit 50602 "MUT Spike Driver B"
{
    // Mechanism B: can a test method drive the BC test framework itself -- build a test
    // suite and run it -- so that "Test Runner - Mgt" executes the victim's [Test] method
    // and "MUT Test Hooks" fires for it?
    //
    // This is the mechanism that would actually deliver §6.1.6: one DemoPortal test job
    // looping many mutants inside one BC session, instead of one job per mutant. F7 blocks
    // the spec'd form (the CLI cannot be passed a TestRunner codeunit id), but F7 says
    // nothing about what an ORDINARY test codeunit does once the job is running.
    //
    // Prior: likely blocked. BC guards against starting a test run from inside one, and
    // the test-isolation transaction scopes conflict. If this codeunit does not compile at
    // all, that is also an answer: the surface is not reachable from the dependency set an
    // app on this backend can declare.
    //
    // Like driver A, this test must PASS -- see the note there.
    Subtype = Test;
    TestPermissions = Disabled;
    Access = Internal;

    [Test]
    procedure B_DriveTestSuiteFromInsideATest()
    var
        TestMethodLine: Record "Test Method Line";
        TestSuiteMgt: Codeunit "Test Suite Mgt.";
        MutationCore: Codeunit "MUT Mut";
        SuiteName: Code[10];
        Outcome: Text;
    begin
        SuiteName := 'MUTSPIKE';
        Outcome := 'B: not reached';

        if TryDriveSuite(TestSuiteMgt, TestMethodLine, SuiteName) then
            Outcome := 'B: suite run returned without error'
        else
            Outcome := 'B: blocked -- ' + GetLastErrorText();

        MutationCore.SetLastHookError(Outcome);
    end;

    [TryFunction]
    local procedure TryDriveSuite(var TestSuiteMgt: Codeunit "Test Suite Mgt."; var TestMethodLine: Record "Test Method Line"; SuiteName: Code[10])
    begin
        // Wrapped in a TryFunction so a platform refusal ("a test run is already in
        // progress", a transaction-scope error, a permission denial) is captured as text
        // rather than failing this test -- a failing driver would insert its own Killed row
        // for the sentinel mutant and destroy the observation.
        TestSuiteMgt.CreateTestSuite(SuiteName);
        TestSuiteMgt.SelectTestMethodsByRange(SuiteName, Format(Codeunit::"MUT Spike Victim"));

        TestMethodLine.SetRange("Test Suite", SuiteName);
        TestSuiteMgt.RunSelectedTests(TestMethodLine);
    end;
}
