codeunit 50002 "MUT Install"
{
    Subtype = Install;
    Access = Internal;

    trigger OnInstallAppPerDatabase()
    var
        Setup: Record "MUT Mutation Setup";
        TenantWebService: Record "Tenant Web Service";
        EnvironmentInformation: Codeunit "Environment Information";
        WebServiceManagement: Codeunit "Web Service Management";
        NotSandboxErr: Label 'Mutation Core can only be installed in a sandbox environment.';
    begin
        if not EnvironmentInformation.IsSandbox() then
            Error(NotSandboxErr);

        Setup.GetOrCreate();
        WebServiceManagement.CreateTenantWebService(TenantWebService."Object Type"::Codeunit, Codeunit::"MUT Runner", 'MUTRunner', true);
    end;
}
