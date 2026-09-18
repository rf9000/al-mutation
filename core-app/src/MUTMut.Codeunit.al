codeunit 50000 "MUT Mut"
{
    SingleInstance = true;
    Access = Public;

    var
        ActiveId: Integer;
        LastHookError: Text;

    procedure SetActive(Id: Integer)
    begin
        ActiveId := Id;
    end;

    procedure Active(Id: Integer): Boolean
    begin
        exit(Id = ActiveId);
    end;

    procedure Reset()
    begin
        ActiveId := 0;
        LastHookError := '';
    end;

    procedure GetActive(): Integer
    begin
        exit(ActiveId);
    end;

    procedure SetLastHookError(ErrorText: Text)
    begin
        LastHookError := ErrorText;
    end;

    procedure GetLastHookError(): Text
    begin
        exit(LastHookError);
    end;
}
