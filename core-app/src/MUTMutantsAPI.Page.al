page 50000 "MUT Mutants API"
{
    PageType = API;
    APIPublisher = 'mutation';
    APIGroup = 'core';
    APIVersion = 'v1.0';
    EntityName = 'mutant';
    EntitySetName = 'mutants';
    SourceTable = "MUT Mutant";
    DelayedInsert = true;
    Editable = true;
    Extensible = false;
    ODataKeyFields = Id;

    layout
    {
        area(Content)
        {
            repeater(General)
            {
                field(id; Rec.Id)
                {
                    Caption = 'Id';
                }
                field(stableKey; Rec."Stable Key")
                {
                    Caption = 'Stable Key';
                }
                field(objectType; Rec."Object Type")
                {
                    Caption = 'Object Type';
                }
                field(objectId; Rec."Object Id")
                {
                    Caption = 'Object Id';
                }
                field(procedureName; Rec."Procedure Name")
                {
                    Caption = 'Procedure Name';
                }
                field(lineNo; Rec."Line No.")
                {
                    Caption = 'Line No.';
                }
                field(operator; Rec.Operator)
                {
                    Caption = 'Operator';
                }
                field(originalText; Rec."Original Text")
                {
                    Caption = 'Original Text';
                }
                field(mutatedText; Rec."Mutated Text")
                {
                    Caption = 'Mutated Text';
                }
                field(status; Rec.Status)
                {
                    Caption = 'Status';
                }
            }
        }
    }
}
