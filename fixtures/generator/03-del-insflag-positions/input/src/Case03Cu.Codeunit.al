codeunit 50230 "Case03 Cu"
{
    Access = Public;
    var
        FxRec: Record "MUT Fx Order";

    procedure Handle(Mode: Integer)
    begin
        if Mode = 1 then
            FxRec.Insert(true)
        else
            FxRec.Modify(false);
        case Mode of
            2:
                FxRec.Delete(true);
            3:
                begin
                    Error('bad mode')
                end;
        end;
    end;
}
