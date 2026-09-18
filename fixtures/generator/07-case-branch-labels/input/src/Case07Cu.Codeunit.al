codeunit 50270 "Case07 Cu"
{
    Access = Public;
    var
        FxRec: Record "MUT Fx Order";

    procedure Route(Code: Text)
    var
        ALbl: Label 'A';
        BLbl: Label 'B';
    begin
        case Code of
            ALbl:
                FxRec.Insert(true);
            BLbl:
                FxRec.Modify(true);
        end;
    end;
}
