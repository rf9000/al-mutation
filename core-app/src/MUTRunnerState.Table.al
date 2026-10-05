table 50004 "MUT Runner State"
{
    // One row per RunMutants batch (SPEC 6.10.2). Written and committed before each mutant, so a
    // client whose SOAP call timed out can still read which session runs which mutant and stop it
    // by batch id. The runner's SOAP session is not listed in "Active Session" (S4).
    Access = Public;
    DataClassification = SystemMetadata;
    DataPerCompany = false;

    fields
    {
        field(1; "Session Id"; Integer)
        {
            Caption = 'Session Id';
            DataClassification = SystemMetadata;
        }
        field(2; "Batch Id"; Text[50])
        {
            Caption = 'Batch Id';
            DataClassification = SystemMetadata;
        }
        field(3; "Run No."; Integer)
        {
            Caption = 'Run No.';
            DataClassification = SystemMetadata;
        }
        field(4; "Mutant Id"; Integer)
        {
            Caption = 'Mutant Id';
            DataClassification = SystemMetadata;
        }
        field(5; "Mutant Started At"; DateTime)
        {
            Caption = 'Mutant Started At';
            DataClassification = SystemMetadata;
        }
        field(6; "Mutants Done"; Integer)
        {
            Caption = 'Mutants Done';
            DataClassification = SystemMetadata;
        }
        field(7; Finished; Boolean)
        {
            Caption = 'Finished';
            DataClassification = SystemMetadata;
        }
        field(8; "Stop Requested"; Boolean)
        {
            // Set and committed by StopRunner before StopSession. A runner that survives the stop
            // sees it on its next re-read and exits without writing (SPEC 6.10.2).
            Caption = 'Stop Requested';
            DataClassification = SystemMetadata;
        }
    }

    keys
    {
        key(PK; "Batch Id")
        {
            Clustered = true;
        }
    }
}
