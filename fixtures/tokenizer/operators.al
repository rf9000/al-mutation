codeunit 50101 "Operators Test"
{
    procedure Test()
    var
        a: Integer;
    begin
        a := 1;
        a += 1;
        a -= 1;
        a *= 1;
        a /= 1;
        if a <> 1 then;
        if a <= 1 then;
        if a >= 1 then;
        if a < 1 then;
        IF a > 1 THEN;
        a := a::Value;
        a := 1 .. 5;
        a := a + 1 - 1 * 1 / 1;
        a := 1.5;
        a.b := 1;
    end;
}
