codeunit 50210 "Case01 Cu"
{
    Access = Public;
    var
        Result: Boolean;

    procedure Check(Amount: Decimal; IsTrusted: Boolean)
    var
        MutationCore: Codeunit "MUT Mut";
        MutCond_1: Boolean;
    begin
        case true of
            MutationCore.Active(1):
                MutCond_1 := (Amount >= 1000) and (not IsTrusted);
            MutationCore.Active(2):
                MutCond_1 := (Amount > 1000) or (not IsTrusted);
            MutationCore.Active(3):
                MutCond_1 := (Amount > 1000) and (IsTrusted);
            MutationCore.Active(4):
                MutCond_1 := true;
            MutationCore.Active(5):
                MutCond_1 := false;
            else
                MutCond_1 := (Amount > 1000) and (not IsTrusted);
        end;
        if MutCond_1 then
            Result := true;
    end;
}
