table 50001 "MUT Mutant"
{
    Access = Public;
    DataClassification = SystemMetadata;
    DataPerCompany = false;

    fields
    {
        field(1; Id; Integer)
        {
            Caption = 'Id';
            DataClassification = SystemMetadata;
        }
        field(2; "Stable Key"; Text[50])
        {
            Caption = 'Stable Key';
            DataClassification = SystemMetadata;
        }
        field(3; "Object Type"; Option)
        {
            Caption = 'Object Type';
            DataClassification = SystemMetadata;
            OptionMembers = Codeunit,Table,Page,Report,Enum;
        }
        field(4; "Object Id"; Integer)
        {
            Caption = 'Object Id';
            DataClassification = SystemMetadata;
        }
        field(5; "Procedure Name"; Text[128])
        {
            Caption = 'Procedure Name';
            DataClassification = SystemMetadata;
        }
        field(6; "Line No."; Integer)
        {
            Caption = 'Line No.';
            DataClassification = SystemMetadata;
        }
        field(7; Operator; Code[20])
        {
            Caption = 'Operator';
            DataClassification = SystemMetadata;
        }
        field(8; "Original Text"; Text[250])
        {
            Caption = 'Original Text';
            DataClassification = SystemMetadata;
        }
        field(9; "Mutated Text"; Text[250])
        {
            Caption = 'Mutated Text';
            DataClassification = SystemMetadata;
        }
        field(10; Status; Enum "MUT Mutant Status")
        {
            Caption = 'Status';
            DataClassification = SystemMetadata;
        }
    }

    keys
    {
        key(PK; Id)
        {
            Clustered = true;
        }
        key(StableKey; "Stable Key")
        {
            Unique = true;
        }
    }
}
