codeunit 50004 "MUT Upgrade"
{
    Subtype = Upgrade;
    Access = Internal;

    trigger OnUpgradePerDatabase()
    var
        TenantWebService: Record "Tenant Web Service";
        WebServiceManagement: Codeunit "Web Service Management";
    begin
        // Environments that already have 1.0.0.0 never run OnInstallAppPerDatabase for 1.1.0.0.
        WebServiceManagement.CreateTenantWebService(TenantWebService."Object Type"::Codeunit, Codeunit::"MUT Runner", 'MUTRunner', true);
    end;
}
