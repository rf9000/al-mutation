codeunit 50200 "MUT Fx Order Mgt"
{
    Access = Public;

    procedure IsLargeOrder(Quantity: Integer): Boolean
    begin
        if Quantity >= 10 then
            exit(true);
        exit(false);
    end;

    procedure RequiresApproval(Amount: Decimal; IsTrusted: Boolean): Boolean
    begin
        if (Amount > 1000) and (not IsTrusted) then
            exit(true);
        exit(false);
    end;

    procedure PostOrder(var FxOrder: Record "MUT Fx Order")
    var
        QtyErr: Label 'Quantity must be positive.';
    begin
        if FxOrder.Quantity <= 0 then
            Error(QtyErr);
        FxOrder.Posted := true;
        FxOrder.Modify(true);
    end;

    procedure CountBatches(Total: Integer; BatchSize: Integer): Integer
    var
        Remaining: Integer;
        Batches: Integer;
    begin
        Remaining := Total;
        Batches := 0;
        repeat
            Remaining -= BatchSize;
            Batches += 1;
        until Remaining <= 0;
        exit(Batches);
    end;

    procedure FirstMultipleAbove(Base: Integer; Threshold: Integer): Integer
    var
        Candidate: Integer;
    begin
        Candidate := 0;
        while true do begin
            Candidate += Base;
            if Candidate > Threshold then
                exit(Candidate);
        end;
    end;
}
