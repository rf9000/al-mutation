codeunit 50002 "MUT Install"
{
    Subtype = Install;
    Access = Internal;

    trigger OnInstallAppPerDatabase()
    var
        Setup: Record "MUT Mutation Setup";
        EnvironmentInformation: Codeunit "Environment Information";
        NotSandboxErr: Label 'Mutation Core can only be installed in a sandbox environment.';
    begin
        if not EnvironmentInformation.IsSandbox() then
            Error(NotSandboxErr);

        Setup.GetOrCreate();
    end;
}
