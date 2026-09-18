permissionset 50000 "MUT Core All"
{
    Assignable = true;
    Caption = 'Mutation Core - all';

    Permissions =
        tabledata "MUT Mutation Setup" = RIMD,
        table "MUT Mutation Setup" = X,
        tabledata "MUT Mutant" = RIMD,
        table "MUT Mutant" = X,
        tabledata "MUT Mutation Run" = RIMD,
        table "MUT Mutation Run" = X,
        tabledata "MUT Mutant Result" = RIMD,
        table "MUT Mutant Result" = X,
        codeunit "MUT Mut" = X,
        codeunit "MUT Test Hooks" = X,
        codeunit "MUT Install" = X,
        page "MUT Mutants API" = X,
        page "MUT Mutation Runs API" = X,
        page "MUT Mutant Results API" = X,
        page "MUT Mutation Setup API" = X;
}
