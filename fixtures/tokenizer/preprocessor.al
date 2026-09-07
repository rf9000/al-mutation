codeunit 50102 "Preprocessor Test"
{
    procedure Test()
    begin
#if FOO
        Message('foo');
#endif
#region Some Region
        Message('bar');
#endregion
    end;
}
