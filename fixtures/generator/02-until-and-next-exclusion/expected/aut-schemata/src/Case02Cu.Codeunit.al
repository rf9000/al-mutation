codeunit 50220 "Case02 Cu"
{
    Access = Public;

    procedure CountDown(var Remaining: Integer; var Flag: Boolean)
    var
        MutationCore: Codeunit "MUT Mut";
        MutCond_1: Boolean;
    begin
        repeat
            Remaining -= 1;
        case true of
            MutationCore.Active(1):
                MutCond_1 := (Remaining < 0) and Flag;
            MutationCore.Active(2):
                MutCond_1 := (Remaining <= 0) or Flag;
            MutationCore.Active(3):
                MutCond_1 := true;
            MutationCore.Active(4):
                MutCond_1 := false;
            else
                MutCond_1 := (Remaining <= 0) and Flag;
        end;
        until MutCond_1;
    end;

    procedure IterateNext(var FxRec: Record "MUT Fx Order")
    begin
        repeat
            FxRec.Amount := FxRec.Amount + 1;
        until FxRec.Next() = 0;
    end;
}
