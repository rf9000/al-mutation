enum 50000 "MUT Mutant Status"
{
    Access = Public;
    Extensible = false;

    value(0; Pending)
    {
        Caption = 'Pending';
    }
    value(1; Killed)
    {
        Caption = 'Killed';
    }
    value(2; Survived)
    {
        Caption = 'Survived';
    }
    value(3; Equivalent)
    {
        Caption = 'Equivalent';
    }
    value(4; Timeout)
    {
        Caption = 'Timeout';
    }
    value(5; CompileError)
    {
        Caption = 'Compile Error';
    }
    value(6; Uncovered)
    {
        Caption = 'Uncovered';
    }
}
