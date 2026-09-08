codeunit 50200 "MUT Fx Order Mgt"
{
    Access = Public;

    procedure IsLargeOrder(Quantity: Integer): Boolean
    var
        MutationCore: Codeunit "MUT Mut";
        MutCond_1: Boolean;
    begin
        case true of
            MutationCore.Active(1):
                MutCond_1 := Quantity > 10;
            MutationCore.Active(2):
                MutCond_1 := true;
            MutationCore.Active(3):
                MutCond_1 := false;
            else
                MutCond_1 := Quantity >= 10;
        end;
        if MutCond_1 then
            case true of
                MutationCore.Active(4):
                    begin
                    end;
                else
                    exit(true);
            end;
        case true of
            MutationCore.Active(5):
                begin
                end;
            else
                exit(false);
        end;
    end;

    procedure RequiresApproval(Amount: Decimal; IsTrusted: Boolean): Boolean
    var
        MutationCore: Codeunit "MUT Mut";
        MutCond_1: Boolean;
    begin
        case true of
            MutationCore.Active(6):
                MutCond_1 := (Amount >= 1000) and (not IsTrusted);
            MutationCore.Active(7):
                MutCond_1 := (Amount > 1000) or (not IsTrusted);
            MutationCore.Active(8):
                MutCond_1 := (Amount > 1000) and (IsTrusted);
            MutationCore.Active(9):
                MutCond_1 := true;
            MutationCore.Active(10):
                MutCond_1 := false;
            else
                MutCond_1 := (Amount > 1000) and (not IsTrusted);
        end;
        if MutCond_1 then
            case true of
                MutationCore.Active(11):
                    begin
                    end;
                else
                    exit(true);
            end;
        case true of
            MutationCore.Active(12):
                begin
                end;
            else
                exit(false);
        end;
    end;

    procedure PostOrder(var FxOrder: Record "MUT Fx Order")
    var
        QtyErr: Label 'Quantity must be positive.';
        MutationCore: Codeunit "MUT Mut";
        MutCond_1: Boolean;
    begin
        case true of
            MutationCore.Active(13):
                MutCond_1 := FxOrder.Quantity < 0;
            MutationCore.Active(14):
                MutCond_1 := true;
            MutationCore.Active(15):
                MutCond_1 := false;
            else
                MutCond_1 := FxOrder.Quantity <= 0;
        end;
        if MutCond_1 then
            case true of
                MutationCore.Active(16):
                    begin
                    end;
                else
                    Error(QtyErr);
            end;
        FxOrder.Posted := true;
        case true of
            MutationCore.Active(17):
                begin
                end;
            MutationCore.Active(18):
                FxOrder.Modify(false);
            else
                FxOrder.Modify(true);
        end;
    end;

    procedure CountBatches(Total: Integer; BatchSize: Integer): Integer
    var
        Remaining: Integer;
        Batches: Integer;
        MutationCore: Codeunit "MUT Mut";
        MutCond_1: Boolean;
    begin
        Remaining := Total;
        Batches := 0;
        repeat
            Remaining -= BatchSize;
            Batches += 1;
        case true of
            MutationCore.Active(19):
                MutCond_1 := Remaining < 0;
            MutationCore.Active(20):
                MutCond_1 := true;
            MutationCore.Active(21):
                MutCond_1 := false;
            else
                MutCond_1 := Remaining <= 0;
        end;
        until MutCond_1;
        case true of
            MutationCore.Active(22):
                begin
                end;
            else
                exit(Batches);
        end;
    end;

    procedure FirstMultipleAbove(Base: Integer; Threshold: Integer): Integer
    var
        Candidate: Integer;
        MutationCore: Codeunit "MUT Mut";
        MutCond_1: Boolean;
    begin
        Candidate := 0;
        while true do begin
            Candidate += Base;
            case true of
                MutationCore.Active(23):
                    MutCond_1 := Candidate >= Threshold;
                MutationCore.Active(24):
                    MutCond_1 := true;
                MutationCore.Active(25):
                    MutCond_1 := false;
                else
                    MutCond_1 := Candidate > Threshold;
            end;
            if MutCond_1 then
                case true of
                    MutationCore.Active(26):
                        begin
                        end;
                    else
                        exit(Candidate);
                end;
        end;
    end;
}
