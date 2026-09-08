codeunit 50400 "MUT Mut Tests"
{
    Subtype = Test;
    Access = Internal;

    var
        Assert: Codeunit "Library Assert";
        MutationCore: Codeunit "MUT Mut";

    [Test]
    procedure SetActive_ThenActiveMatchesOnlyThatId()
    begin
        MutationCore.SetActive(5);

        Assert.IsTrue(MutationCore.Active(5), 'Active(5) should be true after SetActive(5).');
        Assert.IsFalse(MutationCore.Active(6), 'Active(6) should be false after SetActive(5).');
    end;

    [Test]
    procedure Reset_ClearsActive()
    begin
        MutationCore.SetActive(5);
        MutationCore.Reset();

        Assert.IsFalse(MutationCore.Active(5), 'Active(5) should be false after Reset().');
        Assert.AreEqual(0, MutationCore.GetActive(), 'GetActive() should be 0 after Reset().');
    end;

    [Test]
    procedure Active_ZeroWhenNothingSet()
    begin
        MutationCore.Reset();

        Assert.IsTrue(MutationCore.Active(0), 'Active(0) should be true when nothing is set (id 0 means no mutant).');
    end;

    [Test]
    procedure HookErrorIsEmpty()
    begin
        Assert.AreEqual('', MutationCore.GetLastHookError(), 'MUT Test Hooks swallowed an error');
    end;
}
