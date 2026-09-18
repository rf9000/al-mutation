table 50003 "MUT Mutant Result"
{
    Access = Public;
    DataClassification = SystemMetadata;
    DataPerCompany = false;

    fields
    {
        field(1; "Run No."; Integer)
        {
            Caption = 'Run No.';
            DataClassification = SystemMetadata;
        }
        field(2; "Mutant Id"; Integer)
        {
            Caption = 'Mutant Id';
            DataClassification = SystemMetadata;
        }
        field(3; Status; Enum "MUT Mutant Status")
        {
            Caption = 'Status';
            DataClassification = SystemMetadata;
        }
        field(4; "Duration Ms"; Integer)
        {
            Caption = 'Duration Ms';
            DataClassification = SystemMetadata;
        }
        field(5; "Killing Test"; Text[250])
        {
            Caption = 'Killing Test';
            DataClassification = SystemMetadata;
        }
        field(6; "Recorded At"; DateTime)
        {
            Caption = 'Recorded At';
            DataClassification = SystemMetadata;
        }
    }

    keys
    {
        key(PK; "Run No.", "Mutant Id")
        {
            Clustered = true;
        }
    }
}
