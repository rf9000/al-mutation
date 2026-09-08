codeunit 50001 "MUT Test Hooks"
{
    Access = Internal;
    Permissions = tabledata "MUT Mutation Setup" = R,
                  tabledata "MUT Mutant Result" = RI;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Test Runner - Mgt", OnBeforeTestMethodRun, '', false, false)]
    local procedure OnBeforeTestMethodRun(var CurrentTestMethodLine: Record "Test Method Line"; CodeunitID: Integer; CodeunitName: Text[30]; FunctionName: Text[128]; FunctionTestPermissions: TestPermissions; var Skip: Boolean)
    var
        MutationCore: Codeunit "MUT Mut";
        Id: Integer;
        RunNo: Integer;
    begin
        ClearLastError();
        if TryReadActiveMutant(Id, RunNo) then
            MutationCore.SetActive(Id)
        else begin
            MutationCore.SetActive(0);
            MutationCore.SetLastHookError('Before ' + FunctionName + ': ' + GetLastErrorText());
        end;
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Test Runner - Mgt", OnAfterTestMethodRun, '', false, false)]
    local procedure OnAfterTestMethodRun(var CurrentTestMethodLine: Record "Test Method Line"; CodeunitID: Integer; CodeunitName: Text[30]; FunctionName: Text[128]; FunctionTestPermissions: TestPermissions; IsSuccess: Boolean)
    var
        MutantResult: Record "MUT Mutant Result";
        MutationCore: Codeunit "MUT Mut";
        Id: Integer;
        RunNo: Integer;
    begin
        if IsSuccess then
            exit;
        if FunctionName = '' then
            exit;

        ClearLastError();
        if not TryReadActiveMutant(Id, RunNo) then begin
            MutationCore.SetLastHookError('After ' + FunctionName + ': ' + GetLastErrorText());
            exit;
        end;
        if Id = 0 then
            exit;

        if MutantResult.Get(RunNo, Id) then
            exit;

        MutantResult.Init();
        MutantResult."Run No." := RunNo;
        MutantResult."Mutant Id" := Id;
        MutantResult.Status := MutantResult.Status::Killed;
        MutantResult."Killing Test" := CopyStr(CodeunitName + ':' + FunctionName, 1, 250);
        MutantResult."Recorded At" := CurrentDateTime();
        MutantResult.Insert();
    end;

    [TryFunction]
    local procedure TryReadActiveMutant(var ActiveMutantId: Integer; var RunNo: Integer)
    var
        Setup: Record "MUT Mutation Setup";
    begin
        Setup.Get(0);
        ActiveMutantId := Setup."Active Mutant Id";
        RunNo := Setup."Current Run No.";
    end;
}
