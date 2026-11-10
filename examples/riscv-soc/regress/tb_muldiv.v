`timescale 1ns/1ps
// rv_muldiv unit test: corner values + random operands, checked against a behavioural model
//   iverilog -g2005 -o md tb_muldiv.v design.v && vvp md
module tb_muldiv;
    reg clk = 0, rst = 1, start = 0;
    always #5 clk = ~clk;
    reg  [2:0]  op;  reg [31:0] a, b;
    wire idle, done; wire [31:0] result;
    rv_muldiv dut (.clk(clk), .rst(rst), .start(start), .op(op), .a(a), .b(b),
                   .idle(idle), .done(done), .result(result));

    function [31:0] model(input [2:0] f, input [31:0] x, input [31:0] y);
        reg signed [63:0] sx, sy; reg [63:0] ux, uy, p; reg signed [31:0] ix, iy, iq;
        begin
            sx = $signed(x); sy = $signed(y); ux = x; uy = y; ix = x; iy = y;
            case (f)
                3'd0: begin p = ux * uy;          model = p[31:0];  end
                3'd1: begin p = sx * sy;          model = p[63:32]; end
                3'd2: begin p = sx * $signed(uy); model = p[63:32]; end
                3'd3: begin p = ux * uy;          model = p[63:32]; end
                3'd4: begin iq = ix / iy; model = (y == 0) ? 32'hffffffff : (x == 32'h80000000 && y == 32'hffffffff) ? x : iq; end
                3'd5: model = (y == 0) ? 32'hffffffff : x / y;
                3'd6: begin iq = ix % iy; model = (y == 0) ? x : (x == 32'h80000000 && y == 32'hffffffff) ? 0 : iq; end
                3'd7: model = (y == 0) ? x : x % y;
            endcase
        end
    endfunction

    reg [31:0] corner [0:7];
    integer i, j, k, n = 0, errors = 0;

    task run(input [2:0] f, input [31:0] x, input [31:0] y);
        begin
            @(negedge clk); op = f; a = x; b = y; start = 1;
            @(negedge clk); start = 0; a = 32'hx; b = 32'hx; op = 3'hx;   // operands must have been captured
            while (!done) @(negedge clk);
            n = n + 1;
            if (result !== model(f, x, y)) begin
                errors = errors + 1;
                if (errors < 10) $display("ERROR op=%0d a=%h b=%h  result=%h expected=%h", f, x, y, result, model(f, x, y));
            end
        end
    endtask

    initial begin
        corner[0] = 32'h00000000; corner[1] = 32'h00000001; corner[2] = 32'hffffffff; corner[3] = 32'h80000000;
        corner[4] = 32'h7fffffff; corner[5] = 32'h00000002; corner[6] = 32'hfffffffe; corner[7] = 32'h80000001;
        repeat (3) @(negedge clk); rst = 0;
        for (k = 0; k < 8; k = k + 1)
            for (i = 0; i < 8; i = i + 1)
                for (j = 0; j < 8; j = j + 1)
                    run(k, corner[i], corner[j]);
        for (i = 0; i < 4000; i = i + 1)
            run($random, $random, (i % 4 == 0) ? ($random & 32'hff) : $random);
        $display("%0d operations, %0d errors -> %s", n, errors, errors ? "FAIL" : "PASS");
        $finish;
    end
endmodule
