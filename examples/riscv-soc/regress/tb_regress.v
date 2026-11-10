`timescale 1ns/1ps
// riscv-tests runner (official "p" environment). A test reports its result by
// writing to the tohost address:  1 = pass,  (test_no << 1) | 1 = fail
//   +hex=file  +tohost=address(hex)  [+irq : inject random timer interrupts]
module tb_regress;
    reg         clk = 0, rst = 1;
    reg  [31:0] mem [0:16383];                    // 64 KB, indexed by the low address bits
    wire [31:0] ia, da, wd;
    wire [3:0]  ws;
    wire        re, retire, trap;
    reg  [31:0] id, rd;
    reg         irq_timer = 0;
    reg  [1023:0] hex;
    reg  [31:0] tohost;
    reg         irq_en;
    integer     i, cyc = 0, nirq = 0, seed = 1;

    always #5 clk = ~clk;
    always @(posedge clk) begin id <= mem[ia[15:2]]; if (re) rd <= mem[da[15:2]]; end

    rv_core #(.RESET_PC(32'h8000_0000)) dut (.clk(clk), .rst(rst),
        .imem_addr(ia), .imem_rdata(id),
        .dmem_addr(da), .dmem_wdata(wd), .dmem_wstrb(ws), .dmem_re(re), .dmem_rdata(rd),
        .irq_software(1'b0), .irq_timer(irq_timer), .irq_external(1'b0), .irq_fast(16'b0),
        .retire(retire), .trap_taken(trap));

    always @(posedge clk) begin
        if (ws[0]) mem[da[15:2]][7:0]   <= wd[7:0];
        if (ws[1]) mem[da[15:2]][15:8]  <= wd[15:8];
        if (ws[2]) mem[da[15:2]][23:16] <= wd[23:16];
        if (ws[3]) mem[da[15:2]][31:24] <= wd[31:24];
    end

    initial begin
        for (i = 0; i < 16384; i = i + 1) mem[i] = 0;
        if (!$value$plusargs("hex=%s", hex)) $finish;
        if (!$value$plusargs("tohost=%h", tohost)) $finish;
        irq_en = $test$plusargs("irq");
        $readmemh(hex, mem);
        repeat (2) @(posedge clk); #1 rst = 0;
    end

    // request an interrupt at random intervals; drop it once taken (self-acknowledging device)
    always @(posedge clk) if (!rst && irq_en) begin
        if (trap && dut.irq_take) begin irq_timer <= 1'b0; nirq = nirq + 1; end
        else if (!irq_timer && ($random(seed) % 7 == 0)) irq_timer <= 1'b1;
    end

    always @(posedge clk) if (!rst) begin
        cyc = cyc + 1;
        if (ws != 0 && da == tohost) begin
            if (wd == 32'd1) begin
                if (irq_en) $display("PASS (%0d cycles, %0d interrupts)", cyc, nirq);
                else        $display("PASS (%0d cycles)", cyc);
            end else        $display("FAIL test #%0d", wd >> 1);
            $finish;
        end
        if (cyc > 300000) begin $display("FAIL timeout pc=%h", dut.pc_d); $finish; end
    end
endmodule
