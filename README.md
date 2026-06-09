# VeriSim

**Verilog in your browser — fully client-side.**
A browser-based Verilog simulator built by compiling [Icarus Verilog](https://github.com/steveicarus/iverilog) to WebAssembly. No server, no install: edit, compile, simulate, and view waveforms entirely in the page.

**Live:** https://senolgulgonul.github.io/verisim/

---

## Ported toolchain

VeriSim runs **Icarus Verilog version 14.0 (devel)**, compiled from the project's `master` branch (the development line after the 13.0 release) to WebAssembly with [Emscripten](https://emscripten.org/).

Icarus Verilog is three cooperating programs; each is shipped here as a separate WebAssembly module:

| Program | Role | Module |
|---|---|---|
| `ivlpp` | preprocessor (macros, includes, `` `line `` directives) | `ivlpp.wasm` / `ivlpp.js` |
| `ivl`   | compiler — elaborates Verilog and emits a `.vvp` program | `ivl.wasm` / `ivl.js` |
| `vvp`   | runtime — executes the `.vvp` program, writes the VCD | `vvp.wasm` / `vvp.js` |

## How it works

A normal Icarus install runs these as separate OS processes and loads its code-generator and VPI system tasks at runtime with `dlopen`. Neither process spawning nor `dlopen` exists in the browser, so the port:

- **Orchestrates the three stages in JavaScript** instead of the `iverilog` driver. Files are passed between stages through Emscripten's in-memory filesystem (MEMFS).
- **Statically links the back end into the compiler** — the `vvp` code generator (`tgt-vvp`) is linked directly into `ivl`, and the `ivl_dlopen` / `ivl_dlsym` calls that would have loaded it are bypassed.
- **Statically links the VPI system tasks into the runtime** — `system.vpi` (`$display`, `$monitor`, `$dumpvars`, `$finish`, …) is linked into `vvp`, and its dynamic-module loader is short-circuited to call the built-in startup routine.
- **Preprocesses both sources in a single `ivlpp` pass** so cross-file `` `define `` works, with `` `line `` directives preserved so errors map back to the right file and line.

Simulation results are read back as a VCD file and rendered by a custom in-page waveform viewer.

## Features

- Two editors (testbench + design), syntax highlighting, examples, open / save / clear per pane.
- One-click compile + simulate; console shows `$display` / `$monitor` output and compiler diagnostics.
- Waveform viewer: scroll to zoom, drag to pan, click to place a time cursor with per-signal value readout.
- Pick which signals to plot, in the order you choose; scope-qualified names (`tb.clk` vs `tb.dut.clk`).
- **Timescale-aware time display** following GTKWave conventions — values shown in the coarsest exact unit (e.g. `17 ns`, otherwise `17560 ps`); axis ticks on clean steps.
- Unknown (`x`) drawn as a solid block and high-impedance (`z`) as a shaded band, GTKWave-style.
- Pasted code is normalized for non-breaking spaces and smart quotes (handy when copying from lecture slides).
- Language generation selectable: Verilog-2005 / 2009 / SystemVerilog-2012.

## Running locally

It is a static site — any HTTP server works (the `file://` protocol does **not**, because of ES modules and WebAssembly fetch). Keep all files together:

```
index.html
ivlpp.js  ivlpp.wasm
ivl.js    ivl.wasm
vvp.js    vvp.wasm
```

```bash
python3 -m http.server 8090
# then open http://localhost:8090/
```

## License & attribution

VeriSim bundles WebAssembly binaries built from **Icarus Verilog**, which is licensed under the **GNU General Public License, version 2 or later**. The compiled modules (`ivl.wasm`, `vvp.wasm`, `ivlpp.wasm`) are derivative works of that source, so they remain under the GPL, and this project is distributed under GPL-compatible terms.

- Icarus Verilog © Stephen Williams and contributors — https://github.com/steveicarus/iverilog
- Full license text: https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

The corresponding Icarus Verilog source (and the Emscripten build steps / patches used to produce the modules) is the `master` branch of the upstream repository at version 14.0 (devel).

---

*Built and maintained by [@senolgulgonul](https://github.com/senolgulgonul).*
