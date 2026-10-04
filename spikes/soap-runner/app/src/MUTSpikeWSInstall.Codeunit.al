codeunit 50701 "MUT Spike WS Install"
{
    // Publishes "MUT Spike WS Runner" as the SOAP web service 'MUTSpikeRunner' at
    // <base>/WS/<company>/Codeunit/MUTSpikeRunner.
    Subtype = Install;
    Access = Internal;

    trigger OnInstallAppPerDatabase()
    var
        TenantWebService: Record "Tenant Web Service";
        WebServiceManagement: Codeunit "Web Service Management";
    begin
        WebServiceManagement.CreateTenantWebService(TenantWebService."Object Type"::Codeunit, Codeunit::"MUT Spike WS Runner", 'MUTSpikeRunner', true);
    end;
}
