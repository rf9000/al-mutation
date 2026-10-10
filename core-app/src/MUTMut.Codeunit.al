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

    procedure FormatKillReason(ErrorText: Text): Text[250]
    var
        LineBreaks: List of [Char];
        Position: Integer;
        CarriageReturn: Char;
        LineFeed: Char;
    begin
        // The kill reason: first line of the error message (CR or LF ends it), trimmed, cut to 250 (SPEC 6.11.1).
        // Pure text handling, no database access, so the hook and the runner can both call it.
        CarriageReturn := 13;
        LineFeed := 10;
        LineBreaks.Add(CarriageReturn);
        LineBreaks.Add(LineFeed);
        Position := ErrorText.IndexOfAny(LineBreaks);
        if Position > 0 then
            ErrorText := CopyStr(ErrorText, 1, Position - 1);
        exit(CopyStr(ErrorText.Trim(), 1, 250));
    end;
}
