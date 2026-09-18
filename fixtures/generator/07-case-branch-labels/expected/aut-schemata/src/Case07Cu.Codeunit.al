codeunit 50270 "Case07 Cu"
{
    Access = Public;
    var
        FxRec: Record "MUT Fx Order";

    procedure Route(Code: Text)
    var
        ALbl: Label 'A';
        BLbl: Label 'B';
        MutationCore: Codeunit "MUT Mut";
    begin
        case Code of
            ALbl:
                case true of
                    MutationCore.Active(1):
                        begin
                        end;
                    MutationCore.Active(2):
                        FxRec.Insert(false);
                    else
                        FxRec.Insert(true);
                end;
            BLbl:
                case true of
                    MutationCore.Active(3):
                        begin
                        end;
                    MutationCore.Active(4):
                        FxRec.Modify(false);
                    else
                        FxRec.Modify(true);
                end;
        end;
    end;
}
