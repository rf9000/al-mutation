table 50002 "MUT Mutation Run"
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
        field(2; Started; DateTime)
        {
            Caption = 'Started';
            DataClassification = SystemMetadata;
        }
        field(3; Finished; DateTime)
        {
            Caption = 'Finished';
            DataClassification = SystemMetadata;
        }
        field(4; Commit; Text[50])
        {
            Caption = 'Commit';
            DataClassification = SystemMetadata;
        }
        field(5; Backend; Code[20])
        {
            Caption = 'Backend';
            DataClassification = SystemMetadata;
        }
        field(6; Total; Integer)
        {
            Caption = 'Total';
            DataClassification = SystemMetadata;
        }
        field(7; Killed; Integer)
        {
            Caption = 'Killed';
            DataClassification = SystemMetadata;
        }
        field(8; Survived; Integer)
        {
            Caption = 'Survived';
            DataClassification = SystemMetadata;
        }
        field(9; Score; Decimal)
        {
            Caption = 'Score';
            DataClassification = SystemMetadata;
        }
    }

    keys
    {
        key(PK; "Run No.")
        {
            Clustered = true;
        }
    }
}
