table 50000 "MUT Mutation Setup"
{
    Access = Public;
    DataClassification = SystemMetadata;
    DataPerCompany = false;

    fields
    {
        field(1; "Primary Key"; Integer)
        {
            Caption = 'Primary Key';
            DataClassification = SystemMetadata;
        }
        field(2; "Active Mutant Id"; Integer)
        {
            Caption = 'Active Mutant Id';
            DataClassification = SystemMetadata;
        }
        field(3; "Current Run No."; Integer)
        {
            Caption = 'Current Run No.';
            DataClassification = SystemMetadata;
        }
    }

    keys
    {
        key(PK; "Primary Key")
        {
            Clustered = true;
        }
    }

    trigger OnInsert()
    begin
        MirrorToIsolatedStorage();
    end;

    trigger OnModify()
    begin
        MirrorToIsolatedStorage();
    end;

    procedure GetOrCreate()
    begin
        if not Get(0) then begin
            Init();
            "Primary Key" := 0;
            Insert();
        end;
    end;

    local procedure MirrorToIsolatedStorage()
    begin
        IsolatedStorage.Set('ActiveMutantId', Format("Active Mutant Id", 0, 9), DataScope::Module);
        IsolatedStorage.Set('CurrentRunNo', Format("Current Run No.", 0, 9), DataScope::Module);
    end;
}
