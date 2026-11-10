# RISC-V SoC on the Sipeed Tang Nano 9K

Runs the SoC from the parent folder on a Tang Nano 9K (GW1NR-9C, 27 MHz) using only what is
on the board: six LEDs, two push buttons and the USB serial bridge.

> **Status.** Built with Gowin IDE V1.9.12 and confirmed on a Tang Nano 9K at 27 MHz:
> the banner, the upper-case echo, the `?` status line, the S2 message and the LED counter
> all work. The timing margin is thin, see [Timing](#timing).

## What you should see

- The LEDs count up in binary, two steps per second.
- A serial terminal at **115200 baud, 8N1** shows:

  ```
  RV32IMC SoC on Tang Nano 9K
  misa=0x40001104  clock ~26956 kHz
  Type to get an upper-case echo, '?' for status, press S2.
  ```

- Typed characters are echoed back in upper case; `?` prints uptime and the cycle and
  instruction counters.
- Pressing **S2** prints `[S2 pressed N times]`.
- **S1** resets the SoC, so the banner is printed again. The banner is sent right after
  configuration, so press S1 once after opening the terminal.

## Files

| File | Purpose |
| --- | --- |
| `tang9k_top.v` | board top level: reset, button debounce, optional clock divider |
| `tang9k.cst` | pin constraints |
| `tang9k.sdc` | 27 MHz clock constraint |
| `firmware_b0.hex` … `firmware_b3.hex` | prebuilt firmware, one file per byte lane of the RAM |
| `firmware/` | firmware source (`main.c`), `Makefile`, `mkhex.py` |
| `tb_tang9k.v` | simulation of the top level with the real firmware |
| `build_oss.sh` | optional build with the open-source toolchain |
| `prebuilt/tang9k_oss.fs` | bitstream from that open-source build (untested on hardware) |

`../design.v` (core and SoC) is shared with the VeriSim example.

## Building with Gowin IDE

1. Create a project for **GW1NR-LV9QN88PC6/I5** (device GW1NR-9C).
2. Add `../design.v`, `tang9k_top.v`, `tang9k.cst` and `tang9k.sdc`.
3. Copy the four `firmware_b*.hex` files into the project folder (next to the `.gprj`).
4. Set the top module to `tang9k_top` (Project > Configuration > Synthesize).
5. Run Synthesize, then Place & Route.
6. Program the board (SRAM mode is enough for a first test) and open the serial port.

Notes from the confirmed build:

- **Firmware files.** With the four hex files next to the `.gprj`, Gowin found them without
  any further setting. If the board stays silent with all LEDs off, the RAM is empty: check
  the synthesis log for a message about `firmware_b0.hex`, or replace the four default file
  names in `soc_ram` (`INIT_B0` … `INIT_B3` in `../design.v`) with absolute paths written
  with forward slashes.
- **Expected warnings.** `EX3791` (expression truncated, the byte select of a load) and
  `NL0002` (`rv_cdecoder` "swept": the small combinational module is merged into its parent)
  are harmless.
- **No dual-purpose pin options** had to be changed.
- **Serial terminal.** 115200 baud, 8 data bits, no parity, 1 stop bit, no flow control.
  Press S1 after connecting to see the banner.

## Gowin results

From the GowinSynthesis report (V1.9.12, GW1NR-LV9QN88PC6/I5):

| Resource | Used | Available |
| --- | --- | --- |
| Logic (3475 LUT + 366 ALU) | 3841 | 8640 (45 %) |
| Registers | 1146 | 6693 (18 %) |
| Block RAM | 18 | 26 (70 %) |
| 36x36 multiplier | 1 | |

Sixteen of the block RAMs hold the 16 KB of memory (two copies of four byte lanes). The
other two are the register file: Gowin merges the register that follows the register-file
read into a block RAM, which is functionally equivalent.

### Timing

The synthesis report estimates a maximum frequency of **27.4 MHz** for a 27 MHz clock, with
17 logic levels on the longest path: register file, forwarding multiplexer, ALU, address
decode, UART transmit control. (That report is generated against a default 50 MHz
constraint, so the slack values printed in it are relative to 50 MHz, not to 27 MHz.)

The margin is about 1.5 %, so check the Timing Analysis report produced by Place & Route.
If it shows negative slack for `clk`, or the board misbehaves when warm, set
`HALF_SPEED = 1` in `tang9k_top.v` and rebuild: the SoC then runs at 13.5 MHz and the UART
divisor and the firmware's tick rate adapt automatically.

## Reference results from the open-source flow

For comparison, Yosys 0.70, nextpnr-himbaechel 0.11, Apicula 0.32, default settings:

| Resource | Used | Available |
| --- | --- | --- |
| LUT4 | 6695 | 8640 (77 %) |
| Flip-flops | 1344 | 6480 |
| Block RAM | 16 | 26 |
| 36x36 multiplier | 1 | 5 |
| Distributed RAM (register file) | 32 | 270 |

Estimated maximum frequency after routing: **33.5 MHz** (target 27 MHz). This comes from
the open-source timing model and is more optimistic than the Gowin estimate above.

To repeat it, run `./build_oss.sh`. The resulting bitstream is also provided as
`prebuilt/tang9k_oss.fs` and can be loaded with Gowin Programmer or
`openFPGALoader -b tangnano9k prebuilt/tang9k_oss.fs`. It has not been tested on hardware.

## Simulating the board design

```
iverilog -g2005 -o sim tb_tang9k.v tang9k_top.v ../design.v && vvp sim
```

Run it from this folder so that the hex files are found. The testbench shortens the UART
bit time and the tick period, types `hi?`, presses S2, waits for two LED ticks and reports
`RESULT: PASS`.

## Changing the firmware

```
cd firmware
make
```

This rebuilds `main.c` and rewrites the four hex files; copy them to the Gowin project
folder and rerun synthesis. The startup
code, linker script and register definitions are shared with `../firmware/`.

The clock frequency is not compiled in: the firmware reads the UART divisor that the top
level derived from `CLK_HZ` and computes its half-second tick from it.

## Pin assignment

| Signal | Pin | Notes |
| --- | --- | --- |
| `clk` | 52 | 27 MHz oscillator |
| `s1` | 4 | push button, active low, reset |
| `s2` | 3 | push button, active low, GPIO input 0 |
| `leds[0]` … `leds[5]` | 10, 11, 13, 14, 15, 16 | active low, GPIO outputs 0 … 5 |
| `uart_tx` | 17 | FPGA to USB serial bridge |
| `uart_rx` | 18 | USB serial bridge to FPGA |

## Known limitations

- The firmware's receive buffer holds 16 characters. Pasting a long text while a status
  line is being printed can overflow it and drop characters; typing by hand does not.
- Block RAM write mode: on this device a block RAM cannot be read at the address it is
  being written in the same cycle (Place & Route error `PA2122`). `soc_ram` in `../design.v`
  is written so that a byte lane is either read or written in a cycle.
