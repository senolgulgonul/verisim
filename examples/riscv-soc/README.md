# RISC-V SoC example (RV32IMC)

A small but complete RISC-V system-on-chip written in plain Verilog-2005, sized to run
comfortably in VeriSim: a 4-stage pipelined **RV32IMC + Zicsr** core, block RAM, GPIO, UART
and timer, running firmware written in C with three interrupt sources.

The instruction set matches the core of the ESP32-C3 (RV32IMC). The peripherals and memory
map are this project's own and are not ESP32-C3 compatible.

## Run it in VeriSim

**[Open in VeriSim](https://senolgulgonul.github.io/verisim/?design=examples/riscv-soc/design.v&testbench=examples/riscv-soc/testbench.v)**
and press **Run**. The link loads `design.v` and `testbench.v` from this folder.

Expected console output:

```
RV32IMC SoC   misa=0x40001104
primes: 2 3 5 7 11 13 17 19 23 29 31 37 41 43 47
ticks=3 rx=ABC buttons=1 leds=3
mcycle=15397 minstret=7427
ALL OK
---------------------------------
18641 cycles, 8275 instructions (CPI 2.25), 7 traps, 153 characters
RESULT: PASS
```

The text above the dashed line is not printed by the testbench directly. It is what the
firmware sends over the simulated UART; the testbench decodes the `uart_tx` line bit by bit
and prints each character.

With a local Icarus Verilog:

```
iverilog -g2005 -o sim design.v testbench.v && vvp sim
```

## What the demo does

The firmware (`firmware/main.c`):

1. prints a banner and the `misa` CSR,
2. enables three interrupts: the timer, UART receive and GPIO pin 0,
3. finds the primes below 50 (using `REMU`) and prints them in decimal (`DIVU`/`REMU`),
4. waits until it has seen 3 timer ticks, 3 received characters and 1 button press,
5. checks its own results, prints `ALL OK` and sends EOT (0x04).

Meanwhile the testbench sends `abc` to the UART receiver and presses the "button"
(`gpio_in[0]`) once. The interrupt handlers upper-case the received characters, count the
button press, and show the tick count on the GPIO outputs.

The testbench stops at EOT and reports `RESULT: PASS` if the last line was `ALL OK`.

## Files

```
examples/riscv-soc/
├── design.v          core + SoC, one self-contained file
├── testbench.v       testbench with the firmware image embedded
├── README.md
├── firmware/         C sources of the demo firmware
│   ├── main.c        the demo program and interrupt handlers
│   ├── crt0.S        reset code and vectored trap table
│   ├── soc.h         peripheral register map, CSR helpers
│   ├── link.ld       linker script (16 KB RAM at address 0)
│   ├── embed.py      writes firmware.bin into ../testbench.v
│   └── Makefile
└── regress/          verification of the core
    ├── run.sh        runs the official riscv-tests
    ├── tb_regress.v  testbench used by run.sh
    ├── tb_muldiv.v   unit test of the multiply/divide unit
    └── env_irq/      test environment that injects random interrupts
```

`design.v` and `testbench.v` are all VeriSim needs. The other folders are for changing the
firmware and for re-running the verification on a PC.

## Architecture

### Core (`rv_core`)

| Item | Implementation |
| --- | --- |
| ISA | RV32I, M (multiply/divide), C (compressed), Zicsr; machine mode only |
| Pipeline | 4 stages: IF, ID, EX, WB |
| Memories | synchronous read, 32-bit words (block RAM friendly) |
| Data hazards | EX←WB forwarding, ID←WB bypass, 1-cycle stall on load-use |
| Control hazards | branches and jumps resolve in EX, 1-cycle penalty when taken |
| Multiply | 33×33 signed multiplier, 3 cycles |
| Divide | restoring radix-2, 34 cycles |
| Compressed | 16-bit instructions are expanded to 32-bit in ID; 32-bit instructions may straddle two words |
| Traps | taken in EX, which is the commit point; precise |

Modules in `design.v`:

| Module | Purpose |
| --- | --- |
| `rv_alu`, `rv_regfile`, `rv_immgen`, `rv_decoder` | base RV32I datapath |
| `rv_cdecoder` | expands compressed instructions |
| `rv_muldiv` | multi-cycle multiply / divide |
| `rv_csr` | CSRs, cycle and instruction counters, interrupt selection |
| `rv_core` | pipeline top level |
| `soc_ram` | dual-port, byte-writable RAM (code and data) |
| `soc_gpio`, `soc_uart`, `soc_timer` | peripherals |
| `soc_top` | core + memory + peripherals |

### Traps

| Kind | `mcause` |
| --- | --- |
| Illegal instruction (also: access to a non-existent CSR) | 2 |
| `EBREAK` | 3 |
| Misaligned load | 4 |
| Misaligned store | 6 |
| `ECALL` | 11 |
| Software interrupt (`MSIP`) | interrupt 3 |
| Timer interrupt (`mtime >= mtimecmp`) | interrupt 7 |
| External interrupt (unused in this SoC) | interrupt 11 |
| Fast interrupt 0: UART receive | interrupt 16 |
| Fast interrupt 1: GPIO | interrupt 17 |

`mtvec` supports direct and vectored mode; the firmware uses vectored mode. Interrupt
priority is fast 31..16 (highest number first), then external, software, timer.

### Memory map

| Address | Register | Access | Description |
| --- | --- | --- | --- |
| `0x0000_0000` | RAM | rw | code + data, 16 KB by default (`RAM_AW`) |
| `0x4000_0000` | `GPIO_OUT` | rw | 8 output pins |
| `0x4000_0004` | `GPIO_IN` | ro | 8 input pins (synchronised) |
| `0x4000_0008` | `GPIO_IRQ_EN` | rw | rising-edge interrupt enable per input pin |
| `0x4000_000C` | `GPIO_IRQ_PEND` | rw | pending edges, write 1 to clear |
| `0x4000_1000` | `UART_DATA` | rw | write: transmit a byte; read: received byte (clears `RX_VALID`) |
| `0x4000_1004` | `UART_STATUS` | ro | bit 0 `TX_BUSY`, bit 1 `RX_VALID` |
| `0x4000_1008` | `UART_DIV` | rw | clock cycles per bit |
| `0x4000_100C` | `UART_CTRL` | rw | bit 0: receive interrupt enable |
| `0x4000_2000` | `MTIME` (low, high at `+4`) | rw | 64-bit cycle counter |
| `0x4000_2008` | `MTIMECMP` (low, high at `+4`) | rw | timer compare value |
| `0x4000_2010` | `MSIP` | rw | bit 0: software interrupt |

### Bus

The peripherals sit directly on the core's data bus: address, write data and byte strobes
in one cycle, read data in the next, exactly like a synchronous RAM. There are no wait
states, so a peripheral only has to register its read data.

## Looking at waveforms

To keep the VCD small (about 1.3 MB), the testbench dumps only its own top-level signals:
`pc`, `trap_taken`, `mcause`, the three interrupt requests, the data bus
(`bus_addr`, `bus_wstrb`, `bus_wdata`), `uart_tx`, `uart_rx`, `gpio_in` and `gpio_out`.

Things worth looking at:

- `uart_tx`: start bit, 8 data bits LSB first, stop bit; 8 clock cycles per bit.
- `irq_timer` rising, then `trap_taken` with `mcause = 0x80000007`, then `gpio_out` counting.
- `uart_rx` activity followed by `irq_uart` and a trap with `mcause = 0x80000010`.

To see inside the core, change `$dumpvars(1, testbench)` to `$dumpvars(0, testbench)`.
The VCD then grows to tens of megabytes, which is slow in a browser; shorten the run first.

## Changing the firmware

Requires a RISC-V GCC (`riscv64-unknown-elf-gcc` with rv32imc multilib; on Debian/Ubuntu:
`apt install gcc-riscv64-unknown-elf`) and Python 3.

```
cd firmware
make
```

This builds `firmware.bin` and rewrites the firmware block in `../testbench.v` (between the
`FIRMWARE-BEGIN` and `FIRMWARE-END` markers), so the testbench stays a single file that can
be pasted into VeriSim.

Notes for firmware authors:

- The UART runs at 8 clock cycles per bit in the testbench (`UART_DIV`) to keep the
  simulation short.
- Interrupt handlers are plain C functions marked `__attribute__((interrupt("machine")))`.
- There is no C library; `main.c` brings its own print routines.
- Initialised data lives in the same RAM image as the code, so no copy loop is needed.

## Verification

The core is tested with the official [riscv-tests](https://github.com/riscv-software-src/riscv-tests)
using their unmodified "p" environment.

| Run | Result |
| --- | --- |
| `rv32ui`, `rv32um` built as rv32im and again as rv32imc; `rv32uc`; `rv32mi` | 111 of 111 pass |
| The user-level tests again while timer interrupts arrive at random times | 97 of 97 pass |
| `rv_muldiv` against a behavioural model, corner and random operands | 4512 operations, 0 errors |

Both Icarus Verilog 12 and 14 (devel, the version VeriSim ships) were used.

To reproduce (needs Icarus Verilog and the RISC-V GCC):

```
cd regress
git clone --recursive https://github.com/riscv-software-src/riscv-tests
./run.sh          # official tests
./run.sh irq      # the same tests under random interrupts
iverilog -g2005 -o md tb_muldiv.v ../design.v && vvp md
```

Tests that are skipped, and why:

| Test | Reason |
| --- | --- |
| `rv32ui/ma_data` | expects misaligned data access to work; this core traps instead |
| `rv32ui/fence_i` | Zifencei is not implemented (`FENCE` is a no-op) |
| `rv32mi/breakpoint` | needs debug triggers (`tselect`) |
| `rv32mi/pmpaddr` | needs PMP |

## Limitations

- Machine mode only: no user mode, no PMP, no debug module.
- `WFI` is a no-op.
- An interrupt waits for a multiply or divide in progress (up to 33 cycles of extra latency).
- Jumping to a 32-bit instruction at an address that is not a multiple of 4 costs one extra
  cycle, because the instruction spans two memory words.
- Only one fast interrupt at a time has been exercised; the priority order between several
  pending fast interrupts is untested.
- The design has been simulated and passes Yosys synthesis, but has not been run on an FPGA yet.
