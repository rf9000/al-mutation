codeunit 50240 "Case04 Cu"
{
    Access = Public;

    procedure Compute(Value: Integer): Integer
    begin
#if DEBUG
        if Value > 100 then
            exit(Value);
#endif
        if Value < 0 then // mutation:ignore
            exit(0);
        exit(Value);
    end;
}
