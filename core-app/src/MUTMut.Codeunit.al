codeunit 50000 "MUT Mut"
{
    SingleInstance = true;
    Access = Public;

    var
        ActiveId: Integer;

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
    end;

    procedure GetActive(): Integer
    begin
        exit(ActiveId);
    end;
}
