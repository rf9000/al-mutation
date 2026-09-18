codeunit 50230 "Case03 Cu"
{
    Access = Public;
    var
        FxRec: Record "MUT Fx Order";

    procedure Handle(Mode: Integer)
    var
        MutationCore: Codeunit "MUT Mut";
        MutCond_1: Boolean;
    begin
        case true of
            MutationCore.Active(1):
                MutCond_1 := Mode <> 1;
            MutationCore.Active(2):
                MutCond_1 := true;
            MutationCore.Active(3):
                MutCond_1 := false;
            else
                MutCond_1 := Mode = 1;
        end;
        if MutCond_1 then
            case true of
                MutationCore.Active(4):
                    begin
                    end;
                MutationCore.Active(5):
                    FxRec.Insert(false);
                else
                    FxRec.Insert(true);
            end
        else
            case true of
                MutationCore.Active(6):
                    begin
                    end;
                MutationCore.Active(7):
                    FxRec.Modify(true);
                else
                    FxRec.Modify(false);
            end;
        case Mode of
            2:
                case true of
                    MutationCore.Active(8):
                        begin
                        end;
                    MutationCore.Active(9):
                        FxRec.Delete(false);
                    else
                        FxRec.Delete(true);
                end;
            3:
                begin
                    case true of
                        MutationCore.Active(10):
                            begin
                            end;
                        else
                            Error('bad mode');
                    end
                end;
        end;
    end;
}
