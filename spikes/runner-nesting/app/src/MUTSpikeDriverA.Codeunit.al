codeunit 50601 "MUT Spike Driver A"
{
    // Mechanism A: can a test method invoke another test codeunit with CODEUNIT.RUN such
    // that "MUT Test Hooks" fires for the inner test?
    //
    // Prior: no. CODEUNIT.RUN executes the target's OnRun trigger as an ordinary codeunit;
    // its [Test] methods are not invoked and "Test Runner - Mgt" -- which publishes the
    // OnBefore/OnAfterTestMethodRun events the hooks subscribe to -- is never involved.
    // The spike runs it anyway: the whole point of §6.1.6 is worth an empirical answer
    // rather than a confident one.
    //
    // This test must PASS. If it failed, "MUT Test Hooks".OnAfterTestMethodRun would
    // insert a Killed row for the sentinel mutant that the driving script is checking for,
    // and a non-firing hook would be indistinguishable from a firing one.
    Subtype = Test;
    TestPermissions = Disabled;
    Access = Internal;

    [Test]
    procedure A_CodeunitRunOnTestCodeunit()
    var
        MutationCore: Codeunit "MUT Mut";
        Ran: Boolean;
    begin
        Ran := Codeunit.Run(Codeunit::"MUT Spike Victim");

        // Live result (2026-09-30): never reached. BC raises "You cannot nest the execution of
        // test codeunits. Test codeunit 50600 MUT Spike Victim was called from another test
        // codeunit." at the Codeunit.Run call, and the return value does not capture it.
        // Kept only so the variable is used; "MUT Mut" is SingleInstance, so this text is not
        // readable after the job ends.
        MutationCore.SetLastHookError('A: Codeunit.Run returned ' + Format(Ran));
    end;
}
