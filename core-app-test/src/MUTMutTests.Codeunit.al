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
    procedure FormatKillReason_MultiLine_FirstLineTrimmed()
    var
        LineFeed: Text[1];
        CarriageReturn: Text[1];
    begin
        LineFeed[1] := 10;
        CarriageReturn[1] := 13;

        Assert.AreEqual('Expected 1 but got 2', MutationCore.FormatKillReason('  Expected 1 but got 2  ' + LineFeed + 'Call stack line'), 'LF should end the reason.');
        Assert.AreEqual('First', MutationCore.FormatKillReason('First' + CarriageReturn + LineFeed + 'Second'), 'CR should end the reason.');
    end;

    [Test]
    procedure FormatKillReason_Empty_StaysEmpty()
    begin
        Assert.AreEqual('', MutationCore.FormatKillReason(''), 'An empty message should stay empty.');
    end;

    [Test]
    procedure FormatKillReason_OverLong_CutTo250()
    begin
        Assert.AreEqual(PadStr('', 250, 'x'), MutationCore.FormatKillReason(PadStr('', 400, 'x')), 'The reason should be cut to 250 characters.');
    end;

    [Test]
    procedure FormatKillReason_BlankOnly_Empty()
    begin
        Assert.AreEqual('', MutationCore.FormatKillReason('   '), 'A blank message should give an empty reason.');
    end;

    [Test]
    procedure FormatKillReason_LeadingBreaks_FirstNonBlankLine()
    var
        LineFeed: Text[1];
        CarriageReturn: Text[1];
    begin
        LineFeed[1] := 10;
        CarriageReturn[1] := 13;

        Assert.AreEqual('abc', MutationCore.FormatKillReason(LineFeed + 'abc'), 'A leading LF should be skipped.');
        Assert.AreEqual('abc', MutationCore.FormatKillReason('   ' + CarriageReturn + LineFeed + 'abc'), 'Leading blanks and CR LF should be skipped.');
    end;

    [Test]
    procedure HookErrorIsEmpty()
    begin
        Assert.AreEqual('', MutationCore.GetLastHookError(), 'MUT Test Hooks swallowed an error');
    end;
}
