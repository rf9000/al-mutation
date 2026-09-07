codeunit 50001 "MUT Test Hooks"
{
    Access = Internal;
    Permissions = tabledata "MUT Mutation Setup" = RI,
                  tabledata "MUT Mutant Result" = RI;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Test Runner - Mgt", OnBeforeTestMethodRun, '', false, false)]
    local procedure OnBeforeTestMethodRun(var CurrentTestMethodLine: Record "Test Method Line"; CodeunitID: Integer; CodeunitName: Text[30]; FunctionName: Text[128]; FunctionTestPermissions: TestPermissions; var Skip: Boolean)
    var
        Setup: Record "MUT Mutation Setup";
        MutationCore: Codeunit "MUT Mut";
    begin
        Setup.GetOrCreate();
        MutationCore.SetActive(Setup."Active Mutant Id");
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Test Runner - Mgt", OnAfterTestMethodRun, '', false, false)]
    local procedure OnAfterTestMethodRun(var CurrentTestMethodLine: Record "Test Method Line"; CodeunitID: Integer; CodeunitName: Text[30]; FunctionName: Text[128]; FunctionTestPermissions: TestPermissions; IsSuccess: Boolean)
    var
        Setup: Record "MUT Mutation Setup";
        MutantResult: Record "MUT Mutant Result";
    begin
        if IsSuccess then
            exit;
        if FunctionName = '' then
            exit;

        Setup.GetOrCreate();
        if Setup."Active Mutant Id" = 0 then
            exit;

        if MutantResult.Get(Setup."Current Run No.", Setup."Active Mutant Id") then
            exit;

        MutantResult.Init();
        MutantResult."Run No." := Setup."Current Run No.";
        MutantResult."Mutant Id" := Setup."Active Mutant Id";
        MutantResult.Status := MutantResult.Status::Killed;
        MutantResult."Killing Test" := CopyStr(CodeunitName + ':' + FunctionName, 1, 250);
        MutantResult."Recorded At" := CurrentDateTime();
        MutantResult.Insert();
    end;
}
