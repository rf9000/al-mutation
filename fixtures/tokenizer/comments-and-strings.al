// this comment has a "quote" in it
codeunit 50100 "My Codeunit"
{
    /* this is a
       two-line block comment */
    procedure DoIt()
    var
        s: Text;
    begin
        s := 'a // not a comment '' with quote';
        Message('done');
    end;
}
