codeunit 50300 "MUT Fx Order Tests"
{
    Subtype = Test;
    Permissions = tabledata "MUT Fx Order" = RIMD;
    Access = Internal;

    var
        Assert: Codeunit "Library Assert";
        FxOrderMgt: Codeunit "MUT Fx Order Mgt";

    [Test]
    procedure IsLargeOrder_Twelve_IsTrue()
    var
        Result: Boolean;
    begin
        Result := FxOrderMgt.IsLargeOrder(12);

        Assert.IsTrue(Result, 'Order with quantity 12 should be large.');
    end;

    [Test]
    procedure IsLargeOrder_Three_IsFalse()
    var
        Result: Boolean;
    begin
        Result := FxOrderMgt.IsLargeOrder(3);

        Assert.IsFalse(Result, 'Order with quantity 3 should not be large.');
    end;

    [Test]
    procedure RequiresApproval_LargeUntrusted_IsTrue()
    var
        Result: Boolean;
    begin
        Result := FxOrderMgt.RequiresApproval(5000, false);

        Assert.IsTrue(Result, 'A large untrusted order should require approval.');
    end;

    [Test]
    procedure RequiresApproval_SmallUntrusted_IsFalse()
    var
        Result: Boolean;
    begin
        Result := FxOrderMgt.RequiresApproval(100, false);

        Assert.IsFalse(Result, 'A small untrusted order should not require approval.');
    end;

    [Test]
    procedure PostOrder_PositiveQty_SetsPosted()
    var
        FxOrder: Record "MUT Fx Order";
        EntryNo: Integer;
    begin
        EntryNo := 1;
        FxOrder.Init();
        FxOrder."Entry No." := EntryNo;
        FxOrder.Quantity := 5;
        FxOrder.Insert(true);

        FxOrderMgt.PostOrder(FxOrder);

        FxOrder.Get(EntryNo);
        Assert.IsTrue(FxOrder.Posted, 'Order with positive quantity should be posted.');
    end;

    [Test]
    procedure PostOrder_ZeroQty_Errors()
    var
        FxOrder: Record "MUT Fx Order";
        EntryNo: Integer;
    begin
        EntryNo := 2;
        FxOrder.Init();
        FxOrder."Entry No." := EntryNo;
        FxOrder.Quantity := 0;
        FxOrder.Insert(true);

        asserterror FxOrderMgt.PostOrder(FxOrder);
        Assert.ExpectedError('Quantity must be positive.');
    end;

    [Test]
    procedure CountBatches_TenByThree_IsFour()
    var
        Result: Integer;
    begin
        Result := FxOrderMgt.CountBatches(10, 3);

        Assert.AreEqual(4, Result, 'Ten split into batches of three should take four batches.');
    end;

    [Test]
    procedure CountBatches_NineByThree_IsThree()
    var
        Result: Integer;
    begin
        Result := FxOrderMgt.CountBatches(9, 3);

        Assert.AreEqual(3, Result, 'Nine split into batches of three should take three batches.');
    end;

    [Test]
    procedure FirstMultipleAbove_Base3_Threshold9_IsTwelve()
    var
        Result: Integer;
    begin
        Result := FxOrderMgt.FirstMultipleAbove(3, 9);

        Assert.AreEqual(12, Result, 'The first multiple of three above nine should be twelve.');
    end;
}
