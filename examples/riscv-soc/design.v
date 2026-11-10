// =============================================================================
//  design.v  --  RV32IMC + Zicsr core and a small SoC around it
// -----------------------------------------------------------------------------
//  Core modules
//    rv_alu, rv_regfile, rv_immgen, rv_decoder : base RV32I datapath pieces
//    rv_cdecoder : expands 16-bit compressed instructions (C extension)
//    rv_muldiv   : multi-cycle multiply / divide (M extension)
//    rv_csr      : machine-mode CSRs, mcycle/minstret counters, interrupt select
//    rv_core     : 4-stage pipeline top level
//
//  SoC modules (second half of this file)
//    soc_ram     : dual-port byte-writable block RAM (code + data)
//    soc_gpio    : 8 outputs, 8 inputs, edge interrupt
//    soc_uart    : 8N1 UART with RX interrupt
//    soc_timer   : 64-bit mtime / mtimecmp, software interrupt bit
//    soc_top     : core + memory + peripherals, memory map and interrupt wiring
//
//  Pipeline :  IF -> ID -> EX -> WB    (memories are synchronous-read, 32-bit words)
//  Hazards  :  EX <- WB forwarding, ID <- WB bypass, 1-cycle load-use stall,
//              1-cycle penalty for taken branch / JAL / JALR / MRET / trap,
//              multiply takes 3 cycles, divide 34 cycles
//
//  Trap model
//    An instruction that reaches EX is always on the correct path, so EX is the
//    commit point. When a trap is taken the instruction in EX leaves no side
//    effects (register write, memory access, CSR write and mul/div start are all
//    suppressed), mepc is set to its address and the PC is redirected to mtvec.
//    The instruction in ID is squashed.
//
//    Exceptions : illegal instruction (2), EBREAK (3), misaligned load (4),
//                 misaligned store (6), ECALL (11)
//    Interrupts : software (3), timer (7), external (11), fast 16..31.
//                 Taken when EX holds a valid instruction; a multiply/divide in
//                 progress is not aborted, the interrupt waits until it is done
//                 (at most 33 cycles of extra latency).
//
//  Language: Verilog-2005, compatible with Icarus Verilog and Yosys
// =============================================================================

// ----------------------------------------------------------------------------
//  ALU  --  alu_op is encoded as {funct7[5], funct3}; 4'b1111 = pass B (LUI)
// ----------------------------------------------------------------------------
module rv_alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  op,
    output reg  [31:0] y
);
    localparam ADD  = 4'b0000, SUB  = 4'b1000, SLL = 4'b0001, SLT = 4'b0010,
               SLTU = 4'b0011, XOR_ = 4'b0100, SRL = 4'b0101, SRA = 4'b1101,
               OR_  = 4'b0110, AND_ = 4'b0111, PASS_B = 4'b1111;

    wire [4:0] shamt = b[4:0];

    always @(*) begin
        case (op)
            ADD    : y = a + b;
            SUB    : y = a - b;
            SLL    : y = a << shamt;
            SLT    : y = {31'b0, $signed(a) < $signed(b)};
            SLTU   : y = {31'b0, a < b};
            XOR_   : y = a ^ b;
            SRL    : y = a >> shamt;
            SRA    : y = $signed(a) >>> shamt;
            OR_    : y = a | b;
            AND_   : y = a & b;
            PASS_B : y = b;
            default: y = 32'b0;
        endcase
    end
endmodule

// ----------------------------------------------------------------------------
//  Register file  --  32 x 32 bits, x0 = 0, asynchronous read, synchronous write
// ----------------------------------------------------------------------------
module rv_regfile (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  rs1_addr,
    input  wire [4:0]  rs2_addr,
    input  wire [4:0]  rd_addr,
    input  wire [31:0] rd_data,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data
);
    reg [31:0] x [0:31];

    integer i;
    initial for (i = 0; i < 32; i = i + 1) x[i] = 32'b0;

    assign rs1_data = (rs1_addr == 5'd0) ? 32'b0 : x[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'b0 : x[rs2_addr];

    always @(posedge clk)
        if (we && rd_addr != 5'd0)
            x[rd_addr] <= rd_data;
endmodule

// ----------------------------------------------------------------------------
//  Immediate generator  --  I / S / B / U / J
// ----------------------------------------------------------------------------
module rv_immgen (
    input  wire [31:0] instr,
    input  wire [2:0]  imm_sel,
    output reg  [31:0] imm
);
    localparam IMM_I = 3'd0, IMM_S = 3'd1, IMM_B = 3'd2, IMM_U = 3'd3, IMM_J = 3'd4;

    always @(*) begin
        case (imm_sel)
            IMM_I  : imm = {{20{instr[31]}}, instr[31:20]};
            IMM_S  : imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            IMM_B  : imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            IMM_U  : imm = {instr[31:12], 12'b0};
            IMM_J  : imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            default: imm = 32'b0;
        endcase
    end
endmodule

// ----------------------------------------------------------------------------
//  Decoder / control unit
// ----------------------------------------------------------------------------
module rv_decoder (
    input  wire [31:0] instr,
    output reg  [3:0]  alu_op,
    output reg         alu_a_pc,    // 1: A = PC      0: A = rs1
    output reg         alu_b_imm,   // 1: B = imm     0: B = rs2
    output reg  [2:0]  imm_sel,
    output reg  [1:0]  wb_sel,      // 0: ALU   1: memory   2: PC+4
    output reg         reg_we,
    output reg         mem_we,
    output reg         mem_re,
    output reg         branch,
    output reg         jal,
    output reg         jalr,
    output reg         md,          // multiply / divide (M extension)
    output reg         csr,         // CSRRW/S/C(I)
    output reg         ecall,
    output reg         ebreak,
    output reg         mret,
    output reg         illegal
);
    localparam OP_LUI    = 7'b0110111, OP_AUIPC  = 7'b0010111,
               OP_JAL    = 7'b1101111, OP_JALR   = 7'b1100111,
               OP_BRANCH = 7'b1100011, OP_LOAD   = 7'b0000011,
               OP_STORE  = 7'b0100011, OP_OPIMM  = 7'b0010011,
               OP_OP     = 7'b0110011, OP_MISC   = 7'b0001111,
               OP_SYSTEM = 7'b1110011;

    localparam IMM_I = 3'd0, IMM_S = 3'd1, IMM_B = 3'd2, IMM_U = 3'd3, IMM_J = 3'd4;
    localparam WB_ALU = 2'd0, WB_MEM = 2'd1, WB_PC4 = 2'd2;
    localparam ALU_ADD = 4'b0000, ALU_PASS_B = 4'b1111;

    wire [6:0] opcode = instr[6:0];
    wire [2:0] funct3 = instr[14:12];
    wire [6:0] funct7 = instr[31:25];

    always @(*) begin
        // defaults: write nothing (NOP)
        alu_op    = ALU_ADD;
        alu_a_pc  = 1'b0;
        alu_b_imm = 1'b0;
        imm_sel   = IMM_I;
        wb_sel    = WB_ALU;
        reg_we    = 1'b0;
        mem_we    = 1'b0;
        mem_re    = 1'b0;
        branch    = 1'b0;
        jal       = 1'b0;
        jalr      = 1'b0;
        md        = 1'b0;
        csr       = 1'b0;
        ecall     = 1'b0;
        ebreak    = 1'b0;
        mret      = 1'b0;
        illegal   = 1'b0;

        case (opcode)
            OP_LUI: begin
                alu_op = ALU_PASS_B; alu_b_imm = 1'b1; imm_sel = IMM_U; reg_we = 1'b1;
            end
            OP_AUIPC: begin
                alu_a_pc = 1'b1; alu_b_imm = 1'b1; imm_sel = IMM_U; reg_we = 1'b1;
            end
            OP_JAL: begin
                jal = 1'b1; imm_sel = IMM_J; wb_sel = WB_PC4; reg_we = 1'b1;
            end
            OP_JALR: begin
                jalr = 1'b1; alu_b_imm = 1'b1; imm_sel = IMM_I; wb_sel = WB_PC4; reg_we = 1'b1;
                illegal = (funct3 != 3'b000);
            end
            OP_BRANCH: begin
                branch = 1'b1; imm_sel = IMM_B;
                illegal = (funct3 == 3'b010) || (funct3 == 3'b011);
            end
            OP_LOAD: begin
                alu_b_imm = 1'b1; imm_sel = IMM_I; wb_sel = WB_MEM; reg_we = 1'b1; mem_re = 1'b1;
                illegal = (funct3 == 3'b011) || (funct3 == 3'b110) || (funct3 == 3'b111);
            end
            OP_STORE: begin
                alu_b_imm = 1'b1; imm_sel = IMM_S; mem_we = 1'b1;
                illegal = (funct3 > 3'b010);
            end
            OP_OPIMM: begin
                alu_b_imm = 1'b1; imm_sel = IMM_I; reg_we = 1'b1;
                // for shifts funct7[5] selects SRL/SRA; otherwise it is part of the immediate
                if (funct3 == 3'b001) begin
                    alu_op  = {1'b0, funct3};
                    illegal = (funct7 != 7'b0000000);
                end else if (funct3 == 3'b101) begin
                    alu_op  = {funct7[5], funct3};
                    illegal = (funct7 != 7'b0000000) && (funct7 != 7'b0100000);
                end else begin
                    alu_op  = {1'b0, funct3};
                end
            end
            OP_OP: begin
                reg_we = 1'b1;
                alu_op = {funct7[5], funct3};
                if (funct7 == 7'b0000000)
                    illegal = 1'b0;
                else if (funct7 == 7'b0100000)
                    illegal = (funct3 != 3'b000) && (funct3 != 3'b101);   // SUB and SRA only
                else if (funct7 == 7'b0000001)
                    md = 1'b1;                                            // MUL.. / DIV.. (operation = funct3)
                else
                    illegal = 1'b1;
            end
            OP_MISC: begin
                // FENCE / FENCE.I : single core, no cache -> NOP
            end
            OP_SYSTEM: begin
                if (funct3 == 3'b000) begin
                    if (instr[19:15] == 5'd0 && instr[11:7] == 5'd0) begin
                        case (instr[31:20])
                            12'h000: ecall  = 1'b1;
                            12'h001: ebreak = 1'b1;
                            12'h302: mret   = 1'b1;
                            12'h105: ;                                    // WFI -> NOP
                            default: illegal = 1'b1;
                        endcase
                    end else
                        illegal = 1'b1;
                end else if (funct3 == 3'b100) begin
                    illegal = 1'b1;
                end else begin
                    csr = 1'b1; reg_we = 1'b1; imm_sel = IMM_I;           // CSR address = imm[11:0]
                end
            end
            default: illegal = 1'b1;
        endcase

        if (illegal) begin
            reg_we = 1'b0; mem_we = 1'b0; mem_re = 1'b0;
            branch = 1'b0; jal    = 1'b0; jalr   = 1'b0; md = 1'b0;
            csr    = 1'b0; ecall  = 1'b0; ebreak = 1'b0; mret = 1'b0;
        end
    end
endmodule

// ----------------------------------------------------------------------------
//  Compressed instruction expander (C extension, RV32C without F/D)
//    Translates a 16-bit instruction into its 32-bit equivalent, so the rest of
//    the decoder only ever sees 32-bit instructions.
// ----------------------------------------------------------------------------
module rv_cdecoder (
    input  wire [15:0] c,
    output reg  [31:0] instr,
    output reg         illegal
);
    localparam OP_IMM = 7'b0010011, OP_OP    = 7'b0110011, OP_LUI  = 7'b0110111,
               OP_LOAD = 7'b0000011, OP_STORE = 7'b0100011, OP_JAL  = 7'b1101111,
               OP_JALR = 7'b1100111, OP_BRANCH = 7'b1100011;

    wire [4:0] rd    = c[11:7];             // full register fields
    wire [4:0] rs2   = c[6:2];
    wire [4:0] rs1p  = {2'b01, c[9:7]};     // 3-bit fields: x8..x15
    wire [4:0] rs2p  = {2'b01, c[4:2]};
    wire [5:0] imm6  = {c[12], c[6:2]};

    always @(*) begin
        instr   = 32'h0000_0013;
        illegal = 1'b0;

        case ({c[1:0], c[15:13]})
            // ------------------------ Quadrant 0 ------------------------
            5'b00_000: begin   // C.ADDI4SPN -> addi rd', x2, nzuimm
                instr   = {2'b00, c[10:7], c[12:11], c[5], c[6], 2'b00, 5'd2, 3'b000, rs2p, OP_IMM};
                illegal = (c[12:5] == 8'd0);               // includes 0x0000
            end
            5'b00_010:         // C.LW -> lw rd', off(rs1')
                instr = {5'b0, c[5], c[12:10], c[6], 2'b00, rs1p, 3'b010, rs2p, OP_LOAD};
            5'b00_110:         // C.SW -> sw rs2', off(rs1')
                instr = {5'b0, c[5], c[12], rs2p, rs1p, 3'b010, c[11:10], c[6], 2'b00, OP_STORE};

            // ------------------------ Quadrant 1 ------------------------
            5'b01_000:         // C.ADDI / C.NOP -> addi rd, rd, imm
                instr = {{6{c[12]}}, imm6, rd, 3'b000, rd, OP_IMM};
            5'b01_001,         // C.JAL -> jal x1, off     (RV32 only)
            5'b01_101:         // C.J   -> jal x0, off
                instr = {c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], c[12],
                         {8{c[12]}}, 4'b0000, ~c[15], OP_JAL};
            5'b01_010:         // C.LI -> addi rd, x0, imm
                instr = {{6{c[12]}}, imm6, 5'd0, 3'b000, rd, OP_IMM};
            5'b01_011: begin
                if (rd == 5'd2)    // C.ADDI16SP -> addi x2, x2, nzimm
                    instr = {{3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0000, 5'd2, 3'b000, 5'd2, OP_IMM};
                else               // C.LUI -> lui rd, nzimm
                    instr = {{14{c[12]}}, imm6, rd, OP_LUI};
                illegal = (imm6 == 6'd0);
            end
            5'b01_100: begin
                case (c[11:10])
                    2'b00: begin   // C.SRLI
                        instr   = {7'b0000000, c[6:2], rs1p, 3'b101, rs1p, OP_IMM};
                        illegal = c[12];                   // shamt[5] must be 0 on RV32
                    end
                    2'b01: begin   // C.SRAI
                        instr   = {7'b0100000, c[6:2], rs1p, 3'b101, rs1p, OP_IMM};
                        illegal = c[12];
                    end
                    2'b10:         // C.ANDI
                        instr = {{6{c[12]}}, imm6, rs1p, 3'b111, rs1p, OP_IMM};
                    2'b11: begin
                        case (c[6:5])
                            2'b00: instr = {7'b0100000, rs2p, rs1p, 3'b000, rs1p, OP_OP};   // C.SUB
                            2'b01: instr = {7'b0000000, rs2p, rs1p, 3'b100, rs1p, OP_OP};   // C.XOR
                            2'b10: instr = {7'b0000000, rs2p, rs1p, 3'b110, rs1p, OP_OP};   // C.OR
                            2'b11: instr = {7'b0000000, rs2p, rs1p, 3'b111, rs1p, OP_OP};   // C.AND
                        endcase
                        illegal = c[12];                   // C.SUBW / C.ADDW: RV64
                    end
                endcase
            end
            5'b01_110,         // C.BEQZ -> beq rs1', x0, off
            5'b01_111:         // C.BNEZ -> bne rs1', x0, off
                instr = {{4{c[12]}}, c[6:5], c[2], 5'd0, rs1p, 2'b00, c[13],
                         c[11:10], c[4:3], c[12], OP_BRANCH};

            // ------------------------ Quadrant 2 ------------------------
            5'b10_000: begin   // C.SLLI -> slli rd, rd, shamt
                instr   = {7'b0000000, c[6:2], rd, 3'b001, rd, OP_IMM};
                illegal = c[12];
            end
            5'b10_010: begin   // C.LWSP -> lw rd, off(x2)
                instr   = {4'b0000, c[3:2], c[12], c[6:4], 2'b00, 5'd2, 3'b010, rd, OP_LOAD};
                illegal = (rd == 5'd0);
            end
            5'b10_100: begin
                if (!c[12]) begin
                    if (rs2 == 5'd0) begin                 // C.JR -> jalr x0, 0(rs1)
                        instr   = {12'b0, rd, 3'b000, 5'd0, OP_JALR};
                        illegal = (rd == 5'd0);
                    end else                               // C.MV -> add rd, x0, rs2
                        instr = {7'b0000000, rs2, 5'd0, 3'b000, rd, OP_OP};
                end else begin
                    if (rs2 == 5'd0) begin
                        if (rd == 5'd0) instr = 32'h0010_0073;                       // C.EBREAK
                        else            instr = {12'b0, rd, 3'b000, 5'd1, OP_JALR};  // C.JALR
                    end else                               // C.ADD -> add rd, rd, rs2
                        instr = {7'b0000000, rs2, rd, 3'b000, rd, OP_OP};
                end
            end
            5'b10_110:         // C.SWSP -> sw rs2, off(x2)
                instr = {4'b0000, c[8:7], c[12], rs2, 5'd2, 3'b010, c[11:9], 2'b00, OP_STORE};

            default: illegal = 1'b1;   // C.FLD/C.FLW/C.FSD/C.FSW ... (no F/D)
        endcase
    end
endmodule

// ----------------------------------------------------------------------------
//  Multiply / divide unit (M extension)  --  multi-cycle
//    op = funct3 : 000 MUL   001 MULH   010 MULHSU   011 MULHU
//                  100 DIV   101 DIVU   110 REM      111 REMU
//    start   : asserted for 1 cycle while idle; a, b and op are captured then
//    done    : result is valid (1 cycle), then the unit returns to idle
//    Latency : multiply 3 cycles (start + product register + done)
//              divide 34 cycles (start + 32 steps + done), restoring radix-2
// ----------------------------------------------------------------------------
module rv_muldiv (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [2:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire        idle,
    output wire        done,
    output reg  [31:0] result
);
    localparam S_IDLE = 2'd0, S_MUL = 2'd1, S_DIV = 2'd2, S_DONE = 2'd3;
    reg [1:0] state;
    reg [2:0] op_q;

    assign idle = (state == S_IDLE);
    assign done = (state == S_DONE);

    // ---------------- multiply: 33 x 33 signed ----------------
    // MULH: s x s,  MULHSU: s x u,  MULHU: u x u  -> extend to 33 bits with the sign bit
    wire a_signed = (op == 3'b001) || (op == 3'b010);
    wire b_signed = (op == 3'b001);
    reg  signed [32:0] mul_a, mul_b;
    reg  signed [65:0] prod;

    // ---------------- divide: operates on magnitudes ----------------
    wire        div_signed = ~op[0];                      // DIV, REM
    wire [31:0] a_abs = (div_signed && a[31]) ? -a : a;
    wire [31:0] b_abs = (div_signed && b[31]) ? -b : b;

    reg  [31:0] divisor, quo, rem;
    reg         neg_q, neg_r;
    reg  [4:0]  cnt;

    wire [32:0] rem_sh = {rem, quo[31]};                  // shift remainder, bring in next dividend bit
    wire [32:0] diff   = rem_sh - {1'b0, divisor};
    wire        ge     = ~diff[32];                       // rem_sh >= divisor

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: if (start) begin
                    op_q    <= op;
                    // multiply operands
                    mul_a   <= {a_signed & a[31], a};
                    mul_b   <= {b_signed & b[31], b};
                    // divide operands
                    quo     <= a_abs;                     // dividend starts in the quotient register
                    rem     <= 32'd0;
                    divisor <= b_abs;
                    neg_q   <= div_signed && (a[31] ^ b[31]) && (b != 32'd0);
                    neg_r   <= div_signed && a[31];
                    cnt     <= 5'd31;
                    state   <= op[2] ? S_DIV : S_MUL;
                end
                S_MUL: begin
                    prod  <= mul_a * mul_b;
                    state <= S_DONE;
                end
                S_DIV: begin
                    rem   <= ge ? diff[31:0] : rem_sh[31:0];
                    quo   <= {quo[30:0], ge};
                    cnt   <= cnt - 5'd1;
                    if (cnt == 5'd0) state <= S_DONE;
                end
                S_DONE: state <= S_IDLE;
            endcase
        end
    end

    // The special cases fall out of the algorithm:
    //   x / 0        : ge = 1 on every step -> quotient = 0xFFFFFFFF, remainder = x
    //   -2^31 / -1   : |a| = 2^31, same signs -> quotient = 0x80000000, remainder = 0
    always @(*) begin
        case (op_q)
            3'b000 : result = prod[31:0];                 // MUL
            3'b001,
            3'b010,
            3'b011 : result = prod[63:32];                // MULH, MULHSU, MULHU
            3'b100,
            3'b101 : result = neg_q ? -quo : quo;         // DIV, DIVU
            default: result = neg_r ? -rem : rem;         // REM, REMU
        endcase
    end
endmodule

// ----------------------------------------------------------------------------
//  CSR unit  --  machine mode only
//
//    0x300 mstatus   MIE (3), MPIE (7), MPP (12:11) hardwired to 11
//    0x301 misa      RV32IMC, read-only
//    0x304 mie       MSIE (3), MTIE (7), MEIE (11), fast interrupts (31:16)
//    0x305 mtvec     base [31:2], mode [0] : 0 = direct, 1 = vectored
//    0x310 mstatush  0
//    0x340 mscratch  0x341 mepc   0x342 mcause   0x343 mtval
//    0x344 mip       state of the interrupt inputs, read-only
//    0xB00 mcycle    0xB80 mcycleh    0xB02 minstret   0xB82 minstreth
//    0xC00 cycle     0xC80 cycleh     0xC02 instret    0xC82 instreth  (read-only)
//    0xF11..0xF15    mvendorid, marchid, mimpid, mhartid, mconfigptr = 0
//
//  Accessing a non-existent CSR or writing a read-only CSR -> illegal.
//  Interrupt priority: fast 31..16 (highest number first) > MEI > MSI > MTI
// ----------------------------------------------------------------------------
module rv_csr (
    input  wire        clk,
    input  wire        rst,

    // CSR instruction (EX stage)
    input  wire        en,           // EX holds a CSR instruction
    input  wire        commit,       // instruction commits (no trap) -> write allowed
    input  wire [11:0] addr,
    input  wire [2:0]  funct3,       // x01 RW, x10 RS, x11 RC;  [2] = immediate
    input  wire [4:0]  rs1_field,    // rs1 index or zimm
    input  wire [31:0] rs1_data,
    output reg  [31:0] rdata,
    output wire        illegal,

    // trap entry / return
    input  wire        trap,         // a trap is taken this cycle
    input  wire [31:0] trap_cause,
    input  wire [31:0] trap_pc,      // address saved to mepc
    input  wire [31:0] trap_tval,
    input  wire        mret,         // MRET commits this cycle
    output wire [31:0] mepc_o,
    output wire [31:0] mtvec_o,

    // interrupts
    input  wire        irq_software,
    input  wire        irq_timer,
    input  wire        irq_external,
    input  wire [15:0] irq_fast,
    output wire        irq_pending,  // enabled interrupt pending (includes mstatus.MIE)
    output reg  [4:0]  irq_code,

    input  wire        instr_done    // for minstret: an instruction committed in EX
);
    localparam MISA = 32'h4000_1104;             // MXL = 32 bits,  I + M + C

    reg         mstatus_mie, mstatus_mpie;
    reg  [31:0] mie, mtvec, mscratch, mepc, mcause, mtval;
    reg  [63:0] mcycle, minstret;
    reg  [31:0] mip;                              // interrupt inputs, registered once

    assign mepc_o  = mepc;
    assign mtvec_o = mtvec;

    // ---------------- read ----------------
    reg known;
    always @(*) begin
        known = 1'b1;
        case (addr)
            12'h300: rdata = {19'b0, 2'b11, 3'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};
            12'h301: rdata = MISA;
            12'h304: rdata = mie;
            12'h305: rdata = mtvec;
            12'h310: rdata = 32'b0;
            12'h340: rdata = mscratch;
            12'h341: rdata = mepc;
            12'h342: rdata = mcause;
            12'h343: rdata = mtval;
            12'h344: rdata = mip;
            12'hB00: rdata = mcycle[31:0];
            12'hB80: rdata = mcycle[63:32];
            12'hB02: rdata = minstret[31:0];
            12'hB82: rdata = minstret[63:32];
            12'hC00: rdata = mcycle[31:0];        // cycle / instret: read-only shadows
            12'hC80: rdata = mcycle[63:32];
            12'hC02: rdata = minstret[31:0];
            12'hC82: rdata = minstret[63:32];
            12'hF11, 12'hF12, 12'hF13, 12'hF14, 12'hF15: rdata = 32'b0;
            default: begin rdata = 32'b0; known = 1'b0; end
        endcase
    end

    // ---------------- write ----------------
    wire [31:0] wsrc    = funct3[2] ? {27'b0, rs1_field} : rs1_data;
    wire        wr_req  = (funct3[1:0] == 2'b01) || (rs1_field != 5'd0);   // RS/RC with x0 do not write
    wire        rd_only = (addr[11:10] == 2'b11);
    assign illegal = en && (!known || (wr_req && rd_only));

    reg [31:0] wval;
    always @(*) begin
        case (funct3[1:0])
            2'b10  : wval = rdata |  wsrc;
            2'b11  : wval = rdata & ~wsrc;
            default: wval = wsrc;
        endcase
    end
    wire we = en && commit && wr_req && !illegal;

    localparam MIE_MASK = 32'hFFFF_0888;

    always @(posedge clk) begin
        mip <= {irq_fast, 4'b0, irq_external, 3'b0, irq_timer, 3'b0, irq_software, 3'b0};

        if (rst) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mie          <= 32'b0;
            mtvec        <= 32'b0;
            mcycle       <= 64'b0;
            minstret     <= 64'b0;
        end else begin
            mcycle <= mcycle + 64'd1;
            // an instruction that writes minstret does not increment it (the written value reads back)
            if (instr_done && !(we && (addr == 12'hB02 || addr == 12'hB82)))
                minstret <= minstret + 64'd1;

            if (trap) begin
                mepc         <= {trap_pc[31:1], 1'b0};
                mcause       <= trap_cause;
                mtval        <= trap_tval;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
            end else if (mret) begin
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end else if (we) begin
                case (addr)
                    12'h300: begin mstatus_mie <= wval[3]; mstatus_mpie <= wval[7]; end
                    12'h304: mie            <= wval & MIE_MASK;
                    12'h305: mtvec          <= {wval[31:2], 1'b0, wval[0]};
                    12'h340: mscratch       <= wval;
                    12'h341: mepc           <= {wval[31:1], 1'b0};
                    12'h342: mcause         <= wval;
                    12'h343: mtval          <= wval;
                    12'hB00: mcycle[31:0]   <= wval;
                    12'hB80: mcycle[63:32]  <= wval;
                    12'hB02: minstret[31:0] <= wval;
                    12'hB82: minstret[63:32] <= wval;
                    default: ;                    // misa, mstatush, mip: writes are ignored
                endcase
            end
        end
    end

    // ---------------- interrupt select ----------------
    wire [31:0] irqs = mip & mie;
    assign irq_pending = mstatus_mie && (irqs != 32'b0);

    integer k;
    always @(*) begin
        irq_code = 5'd7;                          // MTI (lowest)
        if (irqs[3])  irq_code = 5'd3;            // MSI
        if (irqs[11]) irq_code = 5'd11;           // MEI
        for (k = 16; k < 32; k = k + 1)
            if (irqs[k]) irq_code = k[4:0];       // fast interrupts, highest number wins
    end
endmodule

// ----------------------------------------------------------------------------
//  Core top level  --  4-stage pipeline
// ----------------------------------------------------------------------------
module rv_core #(
    parameter RESET_PC = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        rst,          // synchronous, active-high

    // instruction memory: SYNCHRONOUS read (address this cycle, data next cycle)
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,

    // data memory: SYNCHRONOUS read, synchronous write, word aligned
    output wire [31:0] dmem_addr,    // [1:0] is always 00
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,   // byte write strobes
    output wire        dmem_re,
    input  wire [31:0] dmem_rdata,

    // interrupt inputs (level sensitive, active-high)
    input  wire        irq_software,
    input  wire        irq_timer,
    input  wire        irq_external,
    input  wire [15:0] irq_fast,

    // tracing
    output wire        retire,       // an instruction completed this cycle (WB)
    output wire        trap_taken    // a trap was taken this cycle (exception or interrupt)
);
    localparam NOP = 32'h0000_0013;

    // pipeline control signals (driven further down)
    wire        redirect;            // EX: taken branch / JAL / JALR / MRET / trap
    wire [31:0] redirect_pc;
    wire        stall;               // ID: load-use hazard
    wire        ex_wait;             // EX: multiply/divide in progress
    wire        trap;                // EX: exception or interrupt being taken

    // =========================== IF ===========================
    // With the C extension instructions are aligned to 2-byte boundaries, so a
    // 32-bit instruction can straddle two memory words. The memory delivers one
    // word (w) per cycle.
    //
    //   pc_d[1] = 0 : instruction starts in the lower half of w    -> {w[31:16], w[15:0]}
    //   pc_d[1] = 1 : its lower half is the upper half of the PREVIOUS word
    //       hold_valid = 1 : lower half is in hold, upper half is w[15:0] -> {w[15:0], hold}
    //       hold_valid = 0 : (jumped to an unaligned address) w is the word that
    //                        contains the instruction; its lower half is w[31:16].
    //                        A 16-bit instruction executes right away; a 32-bit one
    //                        is "incomplete": 1 bubble while the next word is fetched.
    //
    // The memory has no enable: when the output must be held, the same address is
    // simply presented again (fa_q).
    reg  [31:0] pc_d;                // address of the instruction in ID
    reg         valid_d;             // memory output is valid
    reg  [31:0] fa_q;                // word address last presented to the memory
    reg  [15:0] hold;                // upper half of the previous word
    reg         hold_valid;

    wire [31:0] w          = imem_rdata;
    wire        unaligned  = pc_d[1];
    wire [15:0] lo16       = !unaligned ? w[15:0]  : hold_valid ? hold : w[31:16];
    wire [15:0] hi16       = !unaligned ? w[31:16] : w[15:0];
    wire        is_c       = (lo16[1:0] != 2'b11);
    wire        incomplete = unaligned & ~hold_valid & ~is_c;
    wire        instr_ok   = valid_d & ~incomplete;

    // address of the next instruction (an incomplete one is retried)
    wire [31:0] seq_pc   = incomplete ? pc_d : pc_d + (is_c ? 32'd2 : 32'd4);
    // for an unaligned instruction the lower half is at hand (goes to hold); fetch the word with the upper half
    wire [29:0] seq_word = seq_pc[31:2] + {29'd0, seq_pc[1]};
    wire        freeze   = stall | ex_wait;

    assign imem_addr = !valid_d ? {pc_d[31:2], 2'b00}        :   // first fetch after reset
                       redirect ? {redirect_pc[31:2], 2'b00} :   // word containing the target
                       freeze   ? fa_q                       :   // re-read the same word
                                  {seq_word, 2'b00};

    always @(posedge clk) begin
        if (rst) begin
            pc_d       <= RESET_PC;
            valid_d    <= 1'b0;
            hold_valid <= 1'b0;
        end else begin
            fa_q <= imem_addr;
            if (!valid_d) begin
                valid_d    <= 1'b1;
            end else if (redirect) begin
                pc_d       <= redirect_pc;
                hold_valid <= 1'b0;
            end else if (!freeze) begin
                pc_d       <= seq_pc;
                hold_valid <= seq_pc[1];
                if (seq_pc[1]) hold <= w[31:16];
            end
        end
    end

    // =========================== ID ===========================
    wire [31:0] c_instr;
    wire        c_illegal;
    rv_cdecoder u_cdec (.c(lo16), .instr(c_instr), .illegal(c_illegal));

    wire [31:0] instr_d = !instr_ok ? NOP                         :
                          is_c      ? (c_illegal ? NOP : c_instr) :   // no side effects if illegal
                                      {hi16, lo16};
    wire [4:0]  rs1_d   = instr_d[19:15];
    wire [4:0]  rs2_d   = instr_d[24:20];
    wire [4:0]  rd_d    = instr_d[11:7];

    wire [3:0]  alu_op_d;
    wire        alu_a_pc_d, alu_b_imm_d;
    wire [2:0]  imm_sel_d;
    wire [1:0]  wb_sel_d;
    wire        reg_we_d, mem_we_d, mem_re_d, branch_d, jal_d, jalr_d, md_d, dec_illegal_d;
    wire        csr_d, ecall_d, ebreak_d, mret_d;

    rv_decoder u_dec (
        .instr(instr_d), .alu_op(alu_op_d), .alu_a_pc(alu_a_pc_d), .alu_b_imm(alu_b_imm_d),
        .imm_sel(imm_sel_d), .wb_sel(wb_sel_d), .reg_we(reg_we_d), .mem_we(mem_we_d),
        .mem_re(mem_re_d), .branch(branch_d), .jal(jal_d), .jalr(jalr_d),
        .md(md_d), .csr(csr_d), .ecall(ecall_d), .ebreak(ebreak_d), .mret(mret_d),
        .illegal(dec_illegal_d)
    );
    wire illegal_d = dec_illegal_d | (instr_ok & is_c & c_illegal);

    wire [31:0] imm_d;
    rv_immgen u_imm (.instr(instr_d), .imm_sel(imm_sel_d), .imm(imm_d));

    // WB stage signals (driven further down)
    reg         wb_reg_we;
    reg  [4:0]  wb_rd;
    wire [31:0] wb_data;

    wire [31:0] rf_rs1, rf_rs2;
    rv_regfile u_rf (
        .clk(clk), .we(wb_reg_we),
        .rs1_addr(rs1_d), .rs2_addr(rs2_d),
        .rd_addr(wb_rd),  .rd_data(wb_data),
        .rs1_data(rf_rs1), .rs2_data(rf_rs2)
    );

    // ID <- WB bypass: read a register that is being written this cycle
    wire        wb_wr      = wb_reg_we && (wb_rd != 5'd0);
    wire [31:0] rs1_data_d = (wb_wr && wb_rd == rs1_d) ? wb_data : rf_rs1;
    wire [31:0] rs2_data_d = (wb_wr && wb_rd == rs2_d) ? wb_data : rf_rs2;

    // does the instruction use rs1 / rs2?  (avoids needless stalls)
    wire [6:0]  opcode_d  = instr_d[6:0];
    wire        use_rs1_d = !(opcode_d == 7'b0110111 || opcode_d == 7'b0010111 ||   // LUI, AUIPC
                              opcode_d == 7'b1101111);                               // JAL
    wire        use_rs2_d =  (opcode_d == 7'b1100011 || opcode_d == 7'b0100011 ||   // BRANCH, STORE
                              opcode_d == 7'b0110011);                               // OP

    // ----------------------- ID/EX registers -----------------------
    reg         ex_valid;
    reg         ex_c;                // 16-bit instruction (link address is PC+2)
    reg  [31:0] ex_pc, ex_rs1_data, ex_rs2_data, ex_imm;
    reg  [4:0]  ex_rs1, ex_rs2, ex_rd;
    reg  [2:0]  ex_funct3;
    reg  [3:0]  ex_alu_op;
    reg         ex_alu_a_pc, ex_alu_b_imm;
    reg  [1:0]  ex_wb_sel;
    reg         ex_reg_we, ex_mem_we, ex_mem_re, ex_branch, ex_jal, ex_jalr, ex_md, ex_illegal;
    reg         ex_csr, ex_ecall, ex_ebreak, ex_mret;

    // load-use: the result of a load in EX is only available in WB
    assign stall = ex_mem_re && (ex_rd != 5'd0) &&
                   ((use_rs1_d && rs1_d == ex_rd) || (use_rs2_d && rs2_d == ex_rd));

    // keep the instruction in ID out of EX -> bubble
    wire kill_d = redirect | stall;

    always @(posedge clk) begin
        if (rst) begin
            ex_valid   <= 1'b0;
            ex_reg_we  <= 1'b0;  ex_mem_we <= 1'b0;  ex_mem_re  <= 1'b0;
            ex_branch  <= 1'b0;  ex_jal    <= 1'b0;  ex_jalr    <= 1'b0;
            ex_md      <= 1'b0;  ex_illegal <= 1'b0;
            ex_csr     <= 1'b0;  ex_ecall  <= 1'b0;  ex_ebreak  <= 1'b0;  ex_mret <= 1'b0;
        end else if (ex_wait) begin
            // EX is waiting: ID/EX registers hold their values
        end else begin
            if (kill_d) begin
                ex_valid   <= 1'b0;
                ex_reg_we  <= 1'b0;  ex_mem_we <= 1'b0;  ex_mem_re  <= 1'b0;
                ex_branch  <= 1'b0;  ex_jal    <= 1'b0;  ex_jalr    <= 1'b0;
                ex_md      <= 1'b0;  ex_illegal <= 1'b0;
                ex_csr     <= 1'b0;  ex_ecall  <= 1'b0;  ex_ebreak  <= 1'b0;  ex_mret <= 1'b0;
            end else begin
                ex_valid   <= instr_ok;
                ex_reg_we  <= reg_we_d;  ex_mem_we <= mem_we_d;  ex_mem_re  <= mem_re_d;
                ex_branch  <= branch_d;  ex_jal    <= jal_d;     ex_jalr    <= jalr_d;
                ex_md      <= md_d;      ex_illegal <= illegal_d;
                ex_csr     <= csr_d;     ex_ecall  <= ecall_d;   ex_ebreak  <= ebreak_d;  ex_mret <= mret_d;
            end
            // datapath registers: no reset needed
            ex_pc        <= pc_d;
            ex_c         <= is_c;
            ex_rs1       <= rs1_d;
            ex_rs2       <= rs2_d;
            ex_rd        <= rd_d;
            ex_rs1_data  <= rs1_data_d;
            ex_rs2_data  <= rs2_data_d;
            ex_imm       <= imm_d;
            ex_funct3    <= instr_d[14:12];
            ex_alu_op    <= alu_op_d;
            ex_alu_a_pc  <= alu_a_pc_d;
            ex_alu_b_imm <= alu_b_imm_d;
            ex_wb_sel    <= wb_sel_d;
        end
    end

    // =========================== EX ===========================
    reg  [31:0] wb_result;           // ALU / PC+4 result of the instruction in WB

    // EX <- WB forwarding (wb_result is enough: when WB holds a load, EX holds a bubble)
    // Note: WB drains while a multiply/divide waits, so rv_muldiv captures its
    // operands in the first cycle, while forwarding is still valid.
    wire [31:0] op1 = (wb_wr && wb_rd == ex_rs1) ? wb_result : ex_rs1_data;
    wire [31:0] op2 = (wb_wr && wb_rd == ex_rs2) ? wb_result : ex_rs2_data;

    wire [31:0] alu_a = ex_alu_a_pc  ? ex_pc  : op1;
    wire [31:0] alu_b = ex_alu_b_imm ? ex_imm : op2;
    wire [31:0] alu_y;
    rv_alu u_alu (.a(alu_a), .b(alu_b), .op(ex_alu_op), .y(alu_y));

    // branch comparator
    wire eq  = (op1 == op2);
    wire lt  = ($signed(op1) < $signed(op2));
    wire ltu = (op1 < op2);
    reg  take;
    always @(*) begin
        case (ex_funct3)
            3'b000 : take = eq;      // BEQ
            3'b001 : take = ~eq;     // BNE
            3'b100 : take = lt;      // BLT
            3'b101 : take = ~lt;     // BGE
            3'b110 : take = ltu;     // BLTU
            3'b111 : take = ~ltu;    // BGEU
            default: take = 1'b0;
        endcase
    end

    // ---------------- CSRs, exceptions, interrupts ----------------
    wire [1:0]  boff       = alu_y[1:0];
    wire        misaligned = (ex_funct3[1:0] == 2'b01 && boff[0]) ||          // LH/LHU/SH
                             (ex_funct3[1:0] == 2'b10 && boff != 2'b00);      // LW/SW
    wire        exc_load   = ex_mem_re & misaligned;
    wire        exc_store  = ex_mem_we & misaligned;

    wire        md_idle, md_done;
    wire [31:0] csr_rdata, mepc, mtvec;
    wire        csr_illegal, irq_pending;
    wire [4:0]  irq_code;

    wire        exception = ex_illegal | csr_illegal | ex_ecall | ex_ebreak | exc_load | exc_store;
    // interrupt: EX must hold a valid instruction (for mepc); wait for a running multiply/divide
    wire        irq_take  = irq_pending & ex_valid & ~(ex_md & ~md_idle);
    assign      trap      = irq_take | exception;

    wire [31:0] trap_cause = irq_take                    ? {1'b1, 26'd0, irq_code} :
                             (ex_illegal | csr_illegal)  ? 32'd2  :
                             ex_ebreak                   ? 32'd3  :
                             exc_load                    ? 32'd4  :
                             exc_store                   ? 32'd6  :
                                                           32'd11;            // ECALL (M)
    wire [31:0] trap_tval  = (~irq_take & ~ex_illegal & ~csr_illegal & ~ex_ebreak &
                              (exc_load | exc_store)) ? alu_y : 32'd0;
    // in vectored mode interrupts go to base + 4*cause, exceptions go to base
    wire [31:0] trap_vec   = (mtvec[0] & irq_take) ? {mtvec[31:2] + {25'd0, irq_code}, 2'b00}
                                                   : {mtvec[31:2], 2'b00};

    // the instruction in EX commits (side effects allowed)
    wire        commit = ex_valid & ~ex_wait & ~trap;

    rv_csr u_csr (
        .clk(clk), .rst(rst),
        .en(ex_csr), .commit(commit), .addr(ex_imm[11:0]), .funct3(ex_funct3),
        .rs1_field(ex_rs1), .rs1_data(op1), .rdata(csr_rdata), .illegal(csr_illegal),
        .trap(trap), .trap_cause(trap_cause), .trap_pc(ex_pc), .trap_tval(trap_tval),
        .mret(ex_mret & commit), .mepc_o(mepc), .mtvec_o(mtvec),
        .irq_software(irq_software), .irq_timer(irq_timer), .irq_external(irq_external),
        .irq_fast(irq_fast), .irq_pending(irq_pending), .irq_code(irq_code),
        .instr_done(commit)
    );

    assign redirect    = trap | ex_mret | ex_jal | ex_jalr | (ex_branch & take);
    assign redirect_pc = trap    ? trap_vec              :
                         ex_mret ? mepc                  :
                         ex_jalr ? {alu_y[31:1], 1'b0}   :
                                   (ex_pc + ex_imm);
    assign trap_taken  = trap;

    // multiply / divide: start in the first cycle, hold EX until done
    wire [31:0] md_result;
    rv_muldiv u_md (
        .clk(clk), .rst(rst),
        .start(ex_md & md_idle & ~trap), .op(ex_funct3), .a(op1), .b(op2),
        .idle(md_idle), .done(md_done), .result(md_result)
    );
    assign ex_wait = ex_md & ~md_done & ~trap;

    wire [31:0] ex_result = ex_md              ? md_result        :
                            ex_csr             ? csr_rdata        :
                            (ex_wb_sel == 2'd2) ? (ex_pc + (ex_c ? 32'd2 : 32'd4)) :
                                                  alu_y;

    // data memory request
    assign dmem_addr = {alu_y[31:2], 2'b00};
    assign dmem_re   = ex_mem_re & ~trap;

    assign dmem_wdata = (ex_funct3[1:0] == 2'b00) ? {4{op2[7:0]}}  :
                        (ex_funct3[1:0] == 2'b01) ? {2{op2[15:0]}} :
                                                    op2;
    reg [3:0] wstrb;
    always @(*) begin
        case (ex_funct3[1:0])
            2'b00  : wstrb = 4'b0001 << boff;                 // SB
            2'b01  : wstrb = boff[1] ? 4'b1100 : 4'b0011;     // SH
            default: wstrb = 4'b1111;                         // SW
        endcase
    end
    assign dmem_wstrb = (ex_mem_we & ~trap) ? wstrb : 4'b0000;

    // ----------------------- EX/WB registers -----------------------
    reg        wb_valid, wb_mem_re;
    reg [2:0]  wb_funct3;
    reg [1:0]  wb_boff;

    always @(posedge clk) begin
        if (rst) begin
            wb_valid  <= 1'b0;
            wb_reg_we <= 1'b0;
            wb_mem_re <= 1'b0;
        end else begin
            wb_valid  <= commit;                    // bubble into WB while waiting or on a trap
            wb_reg_we <= ex_reg_we & commit;
            wb_mem_re <= ex_mem_re & commit;
        end
        wb_rd     <= ex_rd;
        wb_result <= ex_result;
        wb_funct3 <= ex_funct3;
        wb_boff   <= boff;
    end

    // =========================== WB ===========================
    // load: select byte / half word, sign- or zero-extend
    wire [7:0]  ld_b = dmem_rdata >> {wb_boff, 3'b000};
    wire [15:0] ld_h = wb_boff[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];
    reg  [31:0] ld_data;
    always @(*) begin
        case (wb_funct3)
            3'b000 : ld_data = {{24{ld_b[7]}},  ld_b};        // LB
            3'b001 : ld_data = {{16{ld_h[15]}}, ld_h};        // LH
            3'b100 : ld_data = {24'b0, ld_b};                 // LBU
            3'b101 : ld_data = {16'b0, ld_h};                 // LHU
            default: ld_data = dmem_rdata;                    // LW
        endcase
    end

    assign wb_data = wb_mem_re ? ld_data : wb_result;

    assign retire = wb_valid;
endmodule

// #############################################################################
//  SoC
//
//  Memory map
//    0x0000_0000  RAM      code + data, block RAM, 2^RAM_AW words (default 16 KB)
//    0x4000_0000  GPIO     +0x0 OUT       [7:0]  rw
//                          +0x4 IN        [7:0]  ro  (synchronised inputs)
//                          +0x8 IRQ_EN    [7:0]  rw  (per input pin, rising edge)
//                          +0xC IRQ_PEND  [7:0]  rw  (write 1 to clear)
//    0x4000_1000  UART     +0x0 DATA      write: transmit, read: received byte (clears RX_VALID)
//                          +0x4 STATUS    bit0 TX_BUSY, bit1 RX_VALID   ro
//                          +0x8 DIV       clock cycles per bit          rw
//                          +0xC CTRL      bit0 RX interrupt enable      rw
//    0x4000_2000  TIMER    +0x0 MTIME     low      +0x4 MTIME high      rw
//                          +0x8 MTIMECMP  low      +0xC MTIMECMP high   rw
//                          +0x10 MSIP     bit0 software interrupt       rw
//
//  Interrupts : MTI = (mtime >= mtimecmp), MSI = MSIP,
//               fast 0 (mcause 16) = UART RX, fast 1 (mcause 17) = GPIO
//
//  Bus : the core's native data bus. A request (address, write data, strobes)
//        is presented in one cycle and read data is returned in the next one,
//        exactly like a synchronous RAM. There are no wait states, so every
//        peripheral simply registers its read data.
// #############################################################################

// ----------------------------------------------------------------------------
//  Dual-port RAM, byte-writable  (maps to block RAM)
//    port A : read only   (instruction fetch)
//    port B : read/write  (data bus)
//  Four separate byte lanes keep the byte-enable logic inferable.
// ----------------------------------------------------------------------------
module soc_ram #(
    parameter AW = 12                        // 2^AW words
) (
    input  wire          clk,
    input  wire [AW-1:0] a_addr,
    output reg  [31:0]   a_rdata,
    input  wire [AW-1:0] b_addr,
    input  wire [31:0]   b_wdata,
    input  wire [3:0]    b_wstrb,
    output reg  [31:0]   b_rdata
);
    reg [7:0] lane0 [0:(1<<AW)-1];
    reg [7:0] lane1 [0:(1<<AW)-1];
    reg [7:0] lane2 [0:(1<<AW)-1];
    reg [7:0] lane3 [0:(1<<AW)-1];

    always @(posedge clk)
        a_rdata <= {lane3[a_addr], lane2[a_addr], lane1[a_addr], lane0[a_addr]};

    always @(posedge clk) begin
        if (b_wstrb[0]) lane0[b_addr] <= b_wdata[7:0];
        if (b_wstrb[1]) lane1[b_addr] <= b_wdata[15:8];
        if (b_wstrb[2]) lane2[b_addr] <= b_wdata[23:16];
        if (b_wstrb[3]) lane3[b_addr] <= b_wdata[31:24];
        b_rdata <= {lane3[b_addr], lane2[b_addr], lane1[b_addr], lane0[b_addr]};
    end
endmodule

// ----------------------------------------------------------------------------
//  GPIO  --  8 outputs, 8 inputs, rising-edge interrupt per input pin
// ----------------------------------------------------------------------------
module soc_gpio (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,          // this peripheral is addressed
    input  wire        we,
    input  wire [3:2]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,        // valid the cycle after sel
    input  wire [7:0]  pins_in,
    output reg  [7:0]  pins_out,
    output wire        irq
);
    reg [7:0] in_meta, in_sync, in_prev;
    reg [7:0] irq_en, irq_pend;

    wire [7:0] rising = in_sync & ~in_prev;
    assign irq = |(irq_pend & irq_en);

    always @(posedge clk) begin
        in_meta <= pins_in;                  // 2-flop synchroniser
        in_sync <= in_meta;
        in_prev <= in_sync;

        if (rst) begin
            pins_out <= 8'd0;
            irq_en   <= 8'd0;
            irq_pend <= 8'd0;
            in_prev  <= 8'hff;               // no false edge right after reset
            rdata    <= 32'd0;
        end else begin
            irq_pend <= irq_pend | rising;
            if (sel && we) begin
                case (addr)
                    2'd0: pins_out <= wdata[7:0];
                    2'd2: irq_en   <= wdata[7:0];
                    2'd3: irq_pend <= (irq_pend | rising) & ~wdata[7:0];
                    default: ;
                endcase
            end
            rdata <= 32'd0;
            if (sel) begin
                case (addr)
                    2'd0: rdata <= {24'd0, pins_out};
                    2'd1: rdata <= {24'd0, in_sync};
                    2'd2: rdata <= {24'd0, irq_en};
                    2'd3: rdata <= {24'd0, irq_pend};
                endcase
            end
        end
    end
endmodule

// ----------------------------------------------------------------------------
//  UART  --  8N1 transmitter and receiver, programmable bit time
// ----------------------------------------------------------------------------
module soc_uart #(
    parameter DIV_RESET = 16'd234            // clock cycles per bit after reset
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        we,
    input  wire        re,
    input  wire [3:2]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    input  wire        rx,
    output wire        tx,
    output wire        irq
);
    reg [15:0] div;
    reg        rx_irq_en;

    // ---------------- transmitter ----------------
    reg [15:0] tx_cnt;
    reg [3:0]  tx_bits;                      // 0 = idle
    reg [9:0]  tx_shift;                     // {stop, data[7:0], start}
    wire       tx_busy  = (tx_bits != 4'd0);
    wire       tx_start = sel && we && (addr == 2'd0) && !tx_busy;
    assign     tx = tx_shift[0];

    // ---------------- receiver ----------------
    reg        rx_meta, rx_sync;
    reg [15:0] rx_cnt;
    reg [3:0]  rx_bits;                      // 0 = idle, 1..8 data bits pending, 9 = start, 10 = stop
    reg [7:0]  rx_shift, rx_data;
    reg        rx_valid;
    wire       rx_read = sel && re && (addr == 2'd0);
    assign     irq = rx_valid & rx_irq_en;

    always @(posedge clk) begin
        rx_meta <= rx;                       // 2-flop synchroniser
        rx_sync <= rx_meta;

        if (rst) begin
            div       <= DIV_RESET;
            rx_irq_en <= 1'b0;
            tx_bits   <= 4'd0;
            tx_shift  <= 10'h3ff;
            tx_cnt    <= 16'd0;
            rx_bits   <= 4'd0;
            rx_cnt    <= 16'd0;
            rx_valid  <= 1'b0;
            rdata     <= 32'd0;
        end else begin
            // ---- registers ----
            if (sel && we) begin
                case (addr)
                    2'd2: div       <= wdata[15:0];
                    2'd3: rx_irq_en <= wdata[0];
                    default: ;
                endcase
            end
            rdata <= 32'd0;
            if (sel) begin
                case (addr)
                    2'd0: rdata <= {24'd0, rx_data};
                    2'd1: rdata <= {30'd0, rx_valid, tx_busy};
                    2'd2: rdata <= {16'd0, div};
                    2'd3: rdata <= {31'd0, rx_irq_en};
                endcase
            end

            // ---- transmit ----
            if (tx_start) begin
                tx_shift <= {1'b1, wdata[7:0], 1'b0};
                tx_bits  <= 4'd10;
                tx_cnt   <= div - 16'd1;
            end else if (tx_busy) begin
                if (tx_cnt == 16'd0) begin
                    tx_shift <= {1'b1, tx_shift[9:1]};
                    tx_bits  <= tx_bits - 4'd1;
                    tx_cnt   <= div - 16'd1;
                end else
                    tx_cnt <= tx_cnt - 16'd1;
            end

            // ---- receive ----
            if (rx_read) rx_valid <= 1'b0;

            if (rx_bits == 4'd0) begin
                if (!rx_sync) begin                      // falling edge: start bit
                    rx_bits <= 4'd9;
                    rx_cnt  <= {1'b0, div[15:1]};        // sample in the middle of the bit
                end
            end else if (rx_cnt != 16'd0) begin
                rx_cnt <= rx_cnt - 16'd1;
            end else begin
                rx_cnt <= div - 16'd1;
                if (rx_bits == 4'd9) begin               // middle of the start bit
                    rx_bits <= rx_sync ? 4'd0 : 4'd8;    // glitch -> back to idle
                end else if (rx_bits == 4'd10) begin     // middle of the stop bit
                    rx_bits <= 4'd0;
                    if (rx_sync) begin
                        rx_data  <= rx_shift;
                        rx_valid <= 1'b1;
                    end
                end else begin                           // data bits, LSB first
                    rx_shift <= {rx_sync, rx_shift[7:1]};
                    rx_bits  <= (rx_bits == 4'd1) ? 4'd10 : rx_bits - 4'd1;
                end
            end
        end
    end
endmodule

// ----------------------------------------------------------------------------
//  Timer  --  64-bit mtime / mtimecmp and the software interrupt bit (CLINT-like)
// ----------------------------------------------------------------------------
module soc_timer (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        we,
    input  wire [4:2]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output reg         irq_timer,
    output wire        irq_software
);
    reg [63:0] mtime, mtimecmp;
    reg        msip;
    assign irq_software = msip;

    always @(posedge clk) begin
        if (rst) begin
            mtime     <= 64'd0;
            mtimecmp  <= 64'hffff_ffff_ffff_ffff;
            msip      <= 1'b0;
            irq_timer <= 1'b0;
            rdata     <= 32'd0;
        end else begin
            mtime     <= mtime + 64'd1;
            irq_timer <= (mtime >= mtimecmp);
            if (sel && we) begin
                case (addr)
                    3'd0: mtime[31:0]     <= wdata;
                    3'd1: mtime[63:32]    <= wdata;
                    3'd2: mtimecmp[31:0]  <= wdata;
                    3'd3: mtimecmp[63:32] <= wdata;
                    3'd4: msip            <= wdata[0];
                    default: ;
                endcase
            end
            rdata <= 32'd0;
            if (sel) begin
                case (addr)
                    3'd0: rdata <= mtime[31:0];
                    3'd1: rdata <= mtime[63:32];
                    3'd2: rdata <= mtimecmp[31:0];
                    3'd3: rdata <= mtimecmp[63:32];
                    3'd4: rdata <= {31'd0, msip};
                    default: ;
                endcase
            end
        end
    end
endmodule

// ----------------------------------------------------------------------------
//  SoC top level
// ----------------------------------------------------------------------------
module soc_top #(
    parameter RAM_AW   = 12,                 // RAM size = 2^RAM_AW words (12 -> 16 KB)
    parameter UART_DIV = 16'd234             // clk / baud, e.g. 27 MHz / 115200
) (
    input  wire       clk,
    input  wire       rst,                   // synchronous, active-high
    input  wire [7:0] gpio_in,
    output wire [7:0] gpio_out,
    input  wire       uart_rx,
    output wire       uart_tx
);
    // ---------------- core ----------------
    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata;
    reg  [31:0] dmem_rdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_re;
    wire        irq_software, irq_timer, irq_uart, irq_gpio;
    wire        retire, trap_taken;

    rv_core #(.RESET_PC(32'h0000_0000)) u_core (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb),
        .dmem_re(dmem_re),     .dmem_rdata(dmem_rdata),
        .irq_software(irq_software), .irq_timer(irq_timer), .irq_external(1'b0),
        .irq_fast({14'd0, irq_gpio, irq_uart}),
        .retire(retire), .trap_taken(trap_taken)
    );

    // ---------------- address decode ----------------
    wire sel_ram   = (dmem_addr[31:28] == 4'h0);
    wire sel_io    = (dmem_addr[31:28] == 4'h4);
    wire sel_gpio  = sel_io && (dmem_addr[15:12] == 4'h0);
    wire sel_uart  = sel_io && (dmem_addr[15:12] == 4'h1);
    wire sel_timer = sel_io && (dmem_addr[15:12] == 4'h2);
    wire io_we     = (dmem_wstrb != 4'b0000);

    // ---------------- RAM ----------------
    wire [31:0] ram_rdata;
    soc_ram #(.AW(RAM_AW)) u_ram (
        .clk(clk),
        .a_addr(imem_addr[RAM_AW+1:2]), .a_rdata(imem_rdata),
        .b_addr(dmem_addr[RAM_AW+1:2]), .b_wdata(dmem_wdata),
        .b_wstrb(sel_ram ? dmem_wstrb : 4'b0000), .b_rdata(ram_rdata)
    );

    // ---------------- peripherals ----------------
    wire [31:0] gpio_rdata, uart_rdata, timer_rdata;

    soc_gpio u_gpio (
        .clk(clk), .rst(rst), .sel(sel_gpio), .we(io_we), .addr(dmem_addr[3:2]),
        .wdata(dmem_wdata), .rdata(gpio_rdata),
        .pins_in(gpio_in), .pins_out(gpio_out), .irq(irq_gpio)
    );

    soc_uart #(.DIV_RESET(UART_DIV)) u_uart (
        .clk(clk), .rst(rst), .sel(sel_uart), .we(io_we), .re(dmem_re), .addr(dmem_addr[3:2]),
        .wdata(dmem_wdata), .rdata(uart_rdata),
        .rx(uart_rx), .tx(uart_tx), .irq(irq_uart)
    );

    soc_timer u_timer (
        .clk(clk), .rst(rst), .sel(sel_timer), .we(io_we), .addr(dmem_addr[4:2]),
        .wdata(dmem_wdata), .rdata(timer_rdata),
        .irq_timer(irq_timer), .irq_software(irq_software)
    );

    // ---------------- read data mux ----------------
    // Read data arrives one cycle after the request, so the select is registered.
    // Peripherals drive 0 when not addressed and can simply be ORed together.
    reg sel_ram_q;
    always @(posedge clk) sel_ram_q <= sel_ram;

    always @(*) begin
        if (sel_ram_q) dmem_rdata = ram_rdata;
        else           dmem_rdata = gpio_rdata | uart_rdata | timer_rdata;
    end
endmodule
