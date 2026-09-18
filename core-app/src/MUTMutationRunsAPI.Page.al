page 50001 "MUT Mutation Runs API"
{
    PageType = API;
    APIPublisher = 'mutation';
    APIGroup = 'core';
    APIVersion = 'v1.0';
    EntityName = 'mutationRun';
    EntitySetName = 'mutationRuns';
    SourceTable = "MUT Mutation Run";
    DelayedInsert = true;
    Editable = true;
    Extensible = false;
    ODataKeyFields = "Run No.";

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
                field(started; Rec.Started)
                {
                    Caption = 'Started';
                }
                field(finished; Rec.Finished)
                {
                    Caption = 'Finished';
                }
                field(commit; Rec.Commit)
                {
                    Caption = 'Commit';
                }
                field(backend; Rec.Backend)
                {
                    Caption = 'Backend';
                }
                field(total; Rec.Total)
                {
                    Caption = 'Total';
                }
                field(killed; Rec.Killed)
                {
                    Caption = 'Killed';
                }
                field(survived; Rec.Survived)
                {
                    Caption = 'Survived';
                }
                field(score; Rec.Score)
                {
                    Caption = 'Score';
                }
            }
        }
    }
}
