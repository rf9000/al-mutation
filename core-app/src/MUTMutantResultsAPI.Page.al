page 50002 "MUT Mutant Results API"
{
    PageType = API;
    APIPublisher = 'mutation';
    APIGroup = 'core';
    APIVersion = 'v1.0';
    EntityName = 'mutantResult';
    EntitySetName = 'mutantResults';
    SourceTable = "MUT Mutant Result";
    DelayedInsert = true;
    Editable = true;
    Extensible = false;
    ODataKeyFields = "Run No.", "Mutant Id";

    layout
    {
        area(Content)
        {
            repeater(General)
            {
                field(runNo; Rec."Run No.")
                {
                    Caption = 'Run No.';
                }
                field(mutantId; Rec."Mutant Id")
                {
                    Caption = 'Mutant Id';
                }
                field(status; Rec.Status)
                {
                    Caption = 'Status';
                }
                field(durationMs; Rec."Duration Ms")
                {
                    Caption = 'Duration Ms';
                }
                field(killingTest; Rec."Killing Test")
                {
                    Caption = 'Killing Test';
                }
                field(recordedAt; Rec."Recorded At")
                {
                    Caption = 'Recorded At';
                }
            }
        }
    }
}
