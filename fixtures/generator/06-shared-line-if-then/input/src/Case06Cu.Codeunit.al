codeunit 50260 "Case06 Cu"
{
    procedure Handle(Flag: Boolean; Mode: Integer)
    begin
        if Flag then
            if Mode = 1 then exit;
    end;
}
