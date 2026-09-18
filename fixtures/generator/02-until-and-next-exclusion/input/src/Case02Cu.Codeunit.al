codeunit 50220 "Case02 Cu"
{
    Access = Public;

    procedure CountDown(var Remaining: Integer; var Flag: Boolean)
    begin
        repeat
            Remaining -= 1;
        until (Remaining <= 0) and Flag;
    end;

    procedure IterateNext(var FxRec: Record "MUT Fx Order")
    begin
        repeat
            FxRec.Amount := FxRec.Amount + 1;
        until FxRec.Next() = 0;
    end;
}
