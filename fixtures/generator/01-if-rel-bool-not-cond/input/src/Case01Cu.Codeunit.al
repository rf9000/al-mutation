codeunit 50210 "Case01 Cu"
{
    Access = Public;
    var
        Result: Boolean;

    procedure Check(Amount: Decimal; IsTrusted: Boolean)
    begin
        if (Amount > 1000) and (not IsTrusted) then
            Result := true;
    end;
}
