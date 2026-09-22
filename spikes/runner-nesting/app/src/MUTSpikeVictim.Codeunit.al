codeunit 50600 "MUT Spike Victim"
{
    // The thing the driver tries to invoke. One deliberately-failing test, because
    // "MUT Test Hooks".OnAfterTestMethodRun only writes a Killed row when IsSuccess is
    // false -- a passing victim would leave no trace and make a non-firing hook
    // indistinguishable from a firing one.
    Subtype = Test;
    TestPermissions = Disabled;
    Access = Internal;

    [Test]
    procedure Victim_AlwaysFails()
    begin
        Error('deliberate runner-nesting spike failure');
    end;
}
