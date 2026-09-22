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

        // The observation channel: IsolatedStorage via Mutation Core, which the restricted
        // test session can write even though it cannot read Mutation Core's own tables
        // (spike U4). The authoritative answer is whether a mutantResults row appeared,
        // read over the API by Invoke-RunnerNestingSpike.ps1; this is supporting colour.
        MutationCore.SetLastHookError('A: Codeunit.Run returned ' + Format(Ran));
    end;
}
