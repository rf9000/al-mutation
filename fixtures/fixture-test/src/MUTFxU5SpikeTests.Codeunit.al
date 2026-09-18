codeunit 50302 "MUT Fx U5 Spike Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;
    Access = Internal;

    [Test]
    procedure U5_InfiniteLoop()
    begin
        while true do
            Sleep(1000);
    end;
}
