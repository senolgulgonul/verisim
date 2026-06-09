# VeriSim

[![GitHub stars](https://img.shields.io/github/stars/senolgulgonul/verisim?style=social)](https://github.com/senolgulgonul/verisim/stargazers)
[![License: GPL v2](https://img.shields.io/badge/License-GPL%20v2-blue.svg)](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)

**Browser-based Verilog simulator — no installation required.**

🔗 **[Try it live → senolgulgonul.github.io/verisim](https://senolgulgonul.github.io/verisim)**

---

## What is VeriSim?

VeriSim is a fully client-side Verilog simulator built by compiling [Icarus Iverilog](https://github.com/steveicarus/iverilog) to [WebAssembly](https://webassembly.org/). It runs entirely in your browser — no backend, no installation, no dependencies.

Write Verilog, simulate, and see results instantly.

---

## Features

- ✅ Full Icarus Iverilog toolchain compiled to WASM
- ✅ Runs 100% in the browser — nothing to install
- ✅ Supports standard Verilog (IEEE 1364)
- ✅ `$display`, `$monitor`, `$dumpfile` / `$dumpvars` (VCD output)
- ✅ Works offline after first load
- ✅ Zero friction — share a design, just send a link

---

## Quick Start

1. Open **[senolgulgonul.github.io/verisim](https://senolgulgonul.github.io/verisim)**
2. Write or paste your Verilog source
3. Click **Simulate**
4. View the console output or waveform dump

No account, no signup, no install.

---

## Example

```verilog
module hello;
  initial begin
    $display("Hello from VeriSim!");
    #10 $finish;
  end
endmodule
```

---

## How It Was Built

VeriSim ports Icarus Iverilog to the browser via Emscripten/WASM:

- **Icarus Iverilog** is the open-source Verilog simulation and synthesis tool by Stephen Williams.
- The toolchain (`iverilog` + `vvp`) is compiled to WebAssembly using [Emscripten](https://emscripten.org/).
- The compiled WASM module is loaded and driven by a thin JavaScript layer in the browser.
- No server-side execution — everything happens on the client.

---

## Limitations

- Synthesizable / behavioral Verilog is well supported; some SystemVerilog features may not be available depending on the Icarus version compiled.
- File I/O beyond VCD dumps is not supported in the browser sandbox.
- Very large simulations may be slow compared to a native build.

---

## Local Development

```bash
git clone https://github.com/senolgulgonul/verisim
cd verisim
# Serve locally (any static file server works)
npx serve .
```

To rebuild the WASM binary from source, you'll need [Emscripten](https://emscripten.org/docs/getting_started/downloads.html) installed. Build instructions are in [`wasm/BUILD.md`](wasm/BUILD.md).

---

## Credits

- [Icarus Iverilog](https://github.com/steveicarus/iverilog) — Stephen Williams & contributors
- [Emscripten](https://emscripten.org/) — WASM compilation toolchain

---

## License

VeriSim is licensed under the [GNU General Public License v2](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html) (GPL-2.0), the same license as Icarus Iverilog which it is derived from.
