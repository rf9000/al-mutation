table 50702 "MUT Spike Runner State"
{
    // One row per runner session (timeout spike, T-5). Written and committed before each
    // mutant, so a client whose SOAP call timed out can still read which session to stop and
    // which mutant hung. The runner's SOAP session does not appear in "Active Session".
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
        field(2; "Mutant Id"; Integer)
        {
            Caption = 'Mutant Id';
            DataClassification = SystemMetadata;
        }
        field(3; "Started At"; DateTime)
        {
            Caption = 'Started At';
            DataClassification = SystemMetadata;
        }
        field(4; "Mutants Done"; Integer)
        {
            Caption = 'Mutants Done';
            DataClassification = SystemMetadata;
        }
        field(5; Finished; Boolean)
        {
            Caption = 'Finished';
            DataClassification = SystemMetadata;
        }
    }

    keys
    {
        key(PK; "Session Id")
        {
            Clustered = true;
        }
    }
}
