page 50004 "MUT Sessions API"
{
    // Lists the environment's active sessions and stops one on request (bound action `stop`).
    // Exists for non-terminating mutants (run 10, 2026-09-30): the CLI's test-run timeout only
    // stops the client waiting, while the BC session keeps executing the mutant's endless loop and
    // poisons every later test job. The orchestrator uses this to stop that one session instead of
    // stopping and starting the whole environment, which takes minutes and can fail outright
    // (the container's database attach races the previous container on a quick restart).
    PageType = API;
    APIPublisher = 'mutation';
    APIGroup = 'core';
    APIVersion = 'v1.0';
    EntityName = 'session';
    EntitySetName = 'sessions';
    SourceTable = "Active Session";
    Editable = false;
    InsertAllowed = false;
    ModifyAllowed = false;
    DeleteAllowed = false;
    Extensible = false;
    ODataKeyFields = "Session ID";

    layout
    {
        area(Content)
        {
            repeater(General)
            {
                field(sessionId; Rec."Session ID")
                {
                    Caption = 'Session ID';
                }
                field(userId; Rec."User ID")
                {
                    Caption = 'User ID';
                }
                field(clientType; Rec."Client Type")
                {
                    Caption = 'Client Type';
                }
                field(loginDateTime; Rec."Login Datetime")
                {
                    Caption = 'Login Date/Time';
                }
                field(serverInstanceId; Rec."Server Instance ID")
                {
                    Caption = 'Server Instance ID';
                }
                field(isCurrentSession; IsCurrentSession)
                {
                    Caption = 'Is Current Session';
                }
            }
        }
    }

    var
        IsCurrentSession: Boolean;

    trigger OnAfterGetRecord()
    begin
        IsCurrentSession := Rec."Session ID" = SessionId();
    end;

    /// <summary>
    /// Stops this session. BC documents that StopSession cannot terminate a session executing AL
    /// that does not touch the server connection, so the caller must check the session is gone
    /// afterwards rather than trust the call.
    /// </summary>
    [ServiceEnabled]
    procedure Stop(var ActionContext: WebServiceActionContext)
    begin
        if Rec."Session ID" = SessionId() then
            Error('MUT Sessions API: refusing to stop the calling session %1.', Rec."Session ID");
        StopSession(Rec."Session ID", 'al-mutation: stopping a runaway test session (non-terminating mutant)');
        ActionContext.SetObjectType(ObjectType::Page);
        ActionContext.SetObjectId(Page::"MUT Sessions API");
        ActionContext.AddEntityKey(Rec.FieldNo("Session ID"), Rec."Session ID");
        ActionContext.SetResultCode(WebServiceActionResultCode::Deleted);
    end;
}
