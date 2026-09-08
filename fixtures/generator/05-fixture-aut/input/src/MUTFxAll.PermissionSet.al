permissionset 50200 "MUT Fx All"
{
    Assignable = true;
    Caption = 'MUT Fixture - all';

    Permissions =
        tabledata "MUT Fx Order" = RIMD,
        table "MUT Fx Order" = X,
        codeunit "MUT Fx Order Mgt" = X;
}
