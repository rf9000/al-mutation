codeunit 50240 "Case04 Cu"
{
    Access = Public;

    procedure Compute(Value: Integer): Integer
    var
        MutationCore: Codeunit "MUT Mut";
    begin
#if DEBUG
        if Value > 100 then
            exit(Value);
#endif
        if Value < 0 then // mutation:ignore
            case true of
                MutationCore.Active(1):
                    begin
                    end;
                else
                    exit(0);
            end;
        case true of
            MutationCore.Active(2):
                begin
                end;
            else
                exit(Value);
        end;
    end;
}
