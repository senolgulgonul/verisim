// =============================================================================
//  tb_tang9k.v  --  simulation of the Tang Nano 9K top level with its real firmware
// -----------------------------------------------------------------------------
//  Runs the same firmware_b0..3.hex files that Gowin loads into the block RAM.
//  CLK_HZ is overridden so that the UART needs only 8 clock cycles per bit and
//  the LEDs tick every 460800 cycles instead of every 13.5 million.
//
//  Run from this folder (the hex files must be in the current directory):
//    iverilog -g2005 -o sim tb_tang9k.v tang9k_top.v ../design.v && vvp sim
//  Add +vcd to write dump.vcd (top-level signals only).
// =============================================================================
`timescale 1ns/1ps

module tb_tang9k;
    localparam UART_DIV = 8;
    localparam CLK_NS   = 10;
    localparam BIT_NS   = UART_DIV * CLK_NS;

    reg         clk = 1'b0;
    reg         s1  = 1'b1;                     // buttons are active low
    reg         s2  = 1'b1;
    reg         uart_rx = 1'b1;
    wire        uart_tx;
    wire [5:0]  leds;
    wire [5:0]  led_count = ~leds;              // LEDs are active low
    reg  [7:0]  ch;
    integer     k;
    integer     cycles = 0, chars = 0, errors = 0;

    always #(CLK_NS/2) clk = ~clk;

    tang9k_top #(.CLK_HZ(115200 * UART_DIV), .BAUD(115200), .DEBOUNCE_BITS(4)) dut (
        .clk(clk), .s1(s1), .s2(s2), .leds(leds), .uart_rx(uart_rx), .uart_tx(uart_tx)
    );

    task uart_send(input [7:0] c);
        integer b;
        begin
            uart_rx = 1'b0;
            #(BIT_NS);
            for (b = 0; b < 8; b = b + 1) begin
                uart_rx = c[b];
                #(BIT_NS);
            end
            uart_rx = 1'b1;
            #(BIT_NS);
        end
    endtask

    // ---- UART monitor ----
    always @(negedge uart_tx) begin
        #(BIT_NS + BIT_NS/2);
        for (k = 0; k < 8; k = k + 1) begin
            ch[k] = uart_tx;
            #(BIT_NS);
        end
        chars = chars + 1;
        $write("%c", ch);
    end

    always @(posedge clk) cycles = cycles + 1;

    // ---- stimulus ----
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("dump.vcd");
            $dumpvars(1, tb_tang9k);
        end

        #200000;                                // let the banner finish
        uart_send("h");  #2000;
        uart_send("i");  #2000;
        s2 = 1'b0;  #5000;  s2 = 1'b1;          // press S2
        #40000;
        uart_send("?");

        wait (led_count == 6'd2);               // two timer ticks
        #1000;
        $display("\n---------------------------------");
        $display("%0d cycles, %0d characters, LED count = %0d", cycles, chars, led_count);
        if (dut.u_soc.u_core.u_csr.mcause[31] !== 1'b1) errors = errors + 1;   // last trap was an interrupt
        if (chars < 100)                                errors = errors + 1;
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        #30_000_000;
        $display("\nERROR: timeout");
        $finish;
    end
endmodule
