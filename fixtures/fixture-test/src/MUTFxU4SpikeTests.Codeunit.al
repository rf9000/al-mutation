codeunit 50301 "MUT Fx U4 Spike Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;
    Access = Internal;

    var
        Assert: Codeunit "Library Assert";

    [Test]
    procedure U4_Passing()
    begin
        Assert.IsTrue(true, 'This test always passes.');
    end;

    [Test]
    procedure U4_Failing()
    begin
        Error('deliberate U4 failure');
    end;
}
