codeunit 50102 "Filter And Ternary"
{
    procedure Test()
    var
        a: Text;
    begin
        SourceFilter := filter("A" | "B" | "C");
        a := X.StartsWith('-') ? '1' : '2';
    end;
}
