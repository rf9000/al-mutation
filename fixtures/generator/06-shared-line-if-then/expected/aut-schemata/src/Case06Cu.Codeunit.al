codeunit 50260 "Case06 Cu"
{
    procedure Handle(Flag: Boolean; Mode: Integer)
    var
        MutationCore: Codeunit "MUT Mut";
        MutCond_1: Boolean;
    begin
        case true of
            MutationCore.Active(1):
                MutCond_1 := true;
            MutationCore.Active(2):
                MutCond_1 := false;
            else
                MutCond_1 := Flag;
        end;
        if MutCond_1 then
            if Mode = 1 then case true of
                MutationCore.Active(3):
                    begin
                    end;
                else
                    exit;
            end;
    end;
}
