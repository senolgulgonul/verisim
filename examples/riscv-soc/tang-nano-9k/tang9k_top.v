// =============================================================================
//  tang9k_top.v  --  Sipeed Tang Nano 9K (GW1NR-9C) top level for the RISC-V SoC
// -----------------------------------------------------------------------------
//  Board resources used
//    clk      pin 52   27 MHz oscillator
//    s1       pin 4    push button, active low  -> reset
//    s2       pin 3    push button, active low  -> GPIO input 0 (debounced, 1 = pressed)
//    leds     pins 10 11 13 14 15 16, active low  <- GPIO outputs 5..0
//    uart_tx  pin 17   to the on-board USB serial bridge
//    uart_rx  pin 18   from the on-board USB serial bridge
//
//  The RAM is preloaded with the firmware from firmware_b0.hex .. firmware_b3.hex.
//
//  Parameters
//    CLK_HZ        frequency of the clk pin
//    BAUD          UART baud rate
//    HALF_SPEED    0: the SoC runs at CLK_HZ
//                  1: the SoC runs at CLK_HZ / 2 (use this if timing is not met)
//    DEBOUNCE_BITS the button must be stable for 2^DEBOUNCE_BITS clock cycles
// =============================================================================
module tang9k_top #(
    parameter CLK_HZ        = 27_000_000,
    parameter BAUD          = 115_200,
    parameter HALF_SPEED    = 0,
    parameter DEBOUNCE_BITS = 16
) (
    input  wire       clk,
    input  wire       s1,
    input  wire       s2,
    output wire [5:0] leds,
    input  wire       uart_rx,
    output wire       uart_tx
);
    localparam SYS_HZ   = HALF_SPEED ? CLK_HZ / 2 : CLK_HZ;
    localparam UART_DIV = SYS_HZ / BAUD;

    // ---------------- system clock ----------------
    reg  clk_half = 1'b0;
    always @(posedge clk) clk_half <= ~clk_half;
    wire sys_clk = HALF_SPEED ? clk_half : clk;

    // ---------------- reset: power-on counter + S1 ----------------
    reg [1:0] s1_sync = 2'b11;
    reg [7:0] rst_cnt = 8'd0;
    wire      rst     = ~rst_cnt[7];
    always @(posedge sys_clk) begin
        s1_sync <= {s1_sync[0], s1};
        if (!s1_sync[1])  rst_cnt <= 8'd0;               // button pressed
        else if (rst)     rst_cnt <= rst_cnt + 8'd1;     // hold reset for 128 cycles
    end

    // ---------------- S2: synchronise and debounce ----------------
    reg [1:0]               s2_sync = 2'b11;
    reg [DEBOUNCE_BITS-1:0] db_cnt  = {DEBOUNCE_BITS{1'b0}};
    reg                     button  = 1'b0;              // 1 = pressed
    wire                    s2_now  = ~s2_sync[1];
    always @(posedge sys_clk) begin
        s2_sync <= {s2_sync[0], s2};
        if (s2_now == button)
            db_cnt <= {DEBOUNCE_BITS{1'b0}};
        else begin
            db_cnt <= db_cnt + 1'b1;
            if (&db_cnt) button <= s2_now;               // stable long enough: accept
        end
    end

    // ---------------- SoC ----------------
    wire [7:0] gpio_out;

    soc_top #(
        .RAM_AW(12),
        .RAM_INIT(1),
        .UART_DIV(UART_DIV)
    ) u_soc (
        .clk(sys_clk), .rst(rst),
        .gpio_in({7'd0, button}), .gpio_out(gpio_out),
        .uart_rx(uart_rx), .uart_tx(uart_tx)
    );

    assign leds = ~gpio_out[5:0];                        // LEDs light when the pin is low
endmodule
