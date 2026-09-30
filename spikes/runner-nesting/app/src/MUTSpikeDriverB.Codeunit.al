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
    // Mechanism A already established that BC refuses to nest test codeunits ("You cannot
    // nest the execution of test codeunits"), and that Codeunit.Run's return value does not
    // capture that refusal. This asks whether going through the framework's own suite runner
    // is treated any differently.
    //
    // The body lives in codeunit 50603 (an ordinary codeunit) rather than a [TryFunction]:
    // a TryFunction forbids the database writes that building a suite needs.
    Subtype = Test;
    TestPermissions = Disabled;
    Access = Internal;

    // Observation: "MUT Mut" is SingleInstance, so text stored there dies with the job's
    // session and cannot be read afterwards. This test therefore FAILS on purpose with the
    // outcome as its error message, which the job output carries. That no longer confounds
    // the result: the driving script counts a mutantResults row only when its killing test
    // is the victim, and the victim's row (if the hook fires for it) is inserted before this
    // test fails -- the hook never overwrites an existing row.
    [Test]
    procedure B_DriveTestSuiteFromInsideATest()
    var
        TestMethodLine: Record "Test Method Line";
        Outcome: Text;
        Ran: Boolean;
    begin
        Ran := Codeunit.Run(Codeunit::"MUT Spike Suite Runner");
        if Ran then
            Outcome := 'suite run returned without error'
        else
            Outcome := 'suite run blocked: ' + GetLastErrorText();

        TestMethodLine.SetRange("Test Suite", 'MUTSPIKE');
        if TestMethodLine.FindSet() then
            repeat
                Outcome += StrSubstNo(' | line %1 %2 result=%3', Format(TestMethodLine."Line Type"), TestMethodLine.Name, Format(TestMethodLine.Result));
            until TestMethodLine.Next() = 0
        else
            Outcome += ' | no suite lines remain';

        Error('B outcome: %1', Outcome);
    end;
}
