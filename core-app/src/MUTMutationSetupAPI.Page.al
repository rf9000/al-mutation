page 50003 "MUT Mutation Setup API"
{
    PageType = API;
    APIPublisher = 'mutation';
    APIGroup = 'core';
    APIVersion = 'v1.0';
    EntityName = 'mutationSetup';
    EntitySetName = 'mutationSetup';
    SourceTable = "MUT Mutation Setup";
    DelayedInsert = true;
    Editable = true;
    Extensible = false;
    ODataKeyFields = "Primary Key";

    layout
    {
        area(Content)
        {
            repeater(General)
            {
                field(primaryKey; Rec."Primary Key")
                {
                    Caption = 'Primary Key';
                }
                field(activeMutantId; Rec."Active Mutant Id")
                {
                    Caption = 'Active Mutant Id';
                }
                field(currentRunNo; Rec."Current Run No.")
                {
                    Caption = 'Current Run No.';
                }
            }
        }
    }
}
