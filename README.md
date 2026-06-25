# VeriSim

**Verilog in your browser — fully client-side.**
A browser-based Verilog simulator built by compiling [Icarus Verilog](https://github.com/steveicarus/iverilog) to WebAssembly. No server, no install: edit, compile, simulate, view waveforms, and synthesize to a gate-level or RTL schematic — entirely in the page.

**Live:** https://senolgulgonul.github.io/verisim/

---

## Ported toolchain

VeriSim runs **Icarus Verilog version 14.0 (devel)**, built from upstream commit [`c7530db`](https://github.com/steveicarus/iverilog/commit/c7530db) (`master` as of 2026-05-31, the development line after the 13.0 release), compiled to WebAssembly with [Emscripten](https://emscripten.org/).

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
- **Shareable links** load code into the editors straight from the URL: either fetch `.v` files (`?design=&testbench=`) or embed the source directly in the link (`#d=&t=`, no hosting needed). See [Sharing and loading code from a link](#sharing-and-loading-code-from-a-link).
- **Synthesis + schematic** — synthesize `design.v` with [Yosys](https://github.com/YosysHQ/yosys) (loaded on demand via [YoWASP](https://yowasp.org/)) and view it as a circuit drawn by [netlistsvg](https://github.com/nturley/netlistsvg):
  - **Gates** view — combinational logic mapped to **AND / OR / NOT** only (matching truth-table / Karnaugh-map teaching), with flip-flops kept whole as DFF blocks.
  - **RTL** view — word-level operator blocks (`$add`, `$mux`, `$adff`, …) with module hierarchy preserved.
  - Pan / zoom on the schematic: scroll to zoom, drag to pan, double-click to fit.

## Sharing and loading code from a link

VeriSim can populate the two editors directly from the URL, so a design and its testbench can be shared as a single link. There are two forms, and you can use either one (or mix a fetched design with an inline testbench, and so on).

### 1. Fetch files from a URL: `?design=<url>&testbench=<url>`

Each parameter points to a raw `.v` file that VeriSim fetches when the page opens. Both parameters are optional.

- A `raw.githubusercontent.com/...` link works directly.
- A normal `github.com/USER/REPO/blob/BRANCH/file.v` page link is converted to its raw form automatically.
- A path on the same site works too (for example `?design=examples/fulladder.v`).
- The host must allow cross-origin (CORS) requests.

Example:

```
https://senolgulgonul.github.io/verisim/?design=https://github.com/senolgulgonul/verilog/blob/main/fulladder.v&testbench=https://github.com/senolgulgonul/verilog/blob/main/fulladder_tb.v
```

This form keeps the link short, but the code has to live somewhere reachable.

### 2. Embed the code in the link: `#d=<base64url>&t=<base64url>`

The code is carried inside the link itself, so it is fully self-contained and needs no hosting. This is the form to use when a tool, a script, or an AI assistant generates fresh code and wants a one-click "open in VeriSim" link.

- `d` is the design, `t` is the testbench. Both are optional.
- Each value is the UTF-8 source, **base64url** encoded: standard base64 with `+` replaced by `-`, `/` replaced by `_`, and `=` padding removed.
- The payload lives in the URL fragment (`#...`), so it is never sent to the server and does not affect GitHub Pages routing.
- Size is fine for course examples (tens of KB). Very long sources make long links, and some chat clients may truncate them. If you need shorter links, compress before encoding (for example LZString `compressToEncodedURIComponent`) and decode to match.

Live example, a 2-input AND gate plus its testbench:

```
https://senolgulgonul.github.io/verisim/#d=bW9kdWxlIGFuZGdhdGUoaW5wdXQgYSwgaW5wdXQgYiwgb3V0cHV0IHkpOwogIGFzc2lnbiB5ID0gYSAmIGI7CmVuZG1vZHVsZQo&t=bW9kdWxlIGFuZGdhdGVfdGI7CiAgcmVnIGEsIGI7IHdpcmUgeTsKICBhbmRnYXRlIGR1dCguYShhKSwgLmIoYiksIC55KHkpKTsKICBpbml0aWFsIGJlZ2luCiAgICAkZHVtcGZpbGUoImR1bXAudmNkIik7CiAgICAkZHVtcHZhcnMoMCwgYW5kZ2F0ZV90Yik7CiAgICAkbW9uaXRvcigiYT0lYiBiPSViIHk9JWIiLCBhLCBiLCB5KTsKICAgIGE9MDsgYj0wOyAjNTsKICAgIGE9MDsgYj0xOyAjNTsKICAgIGE9MTsgYj0wOyAjNTsKICAgIGE9MTsgYj0xOyAjNTsKICAgICRmaW5pc2g7CiAgZW5kCmVuZG1vZHVsZQo
```

### Building an inline link

In a page (the same helper VeriSim uses internally):

```js
function b64urlEncode(str){
  const bytes = new TextEncoder().encode(String(str || ''));
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
}
const base = 'https://senolgulgonul.github.io/verisim/';
const link = base + '#d=' + b64urlEncode(designSrc) + '&t=' + b64urlEncode(tbSrc);
```

From the command line, straight from two files:

```bash
python3 -c "import base64; enc=lambda f: base64.urlsafe_b64encode(open(f,'rb').read()).decode().rstrip('='); print('https://senolgulgonul.github.io/verisim/#d='+enc('design.v')+'&t='+enc('tb.v'))"
```

### In the app

Open the **URL...** dialog. It offers two buttons:

- **Copy share link** builds the `?design=&testbench=` form from the two URL fields.
- **Copy code link** builds the self-contained `#d=&t=` form from whatever is currently in the editors.

> Testbench note: VeriSim reads the waveform back from the VCD your testbench writes, so keep the standard `$dumpfile("dump.vcd");` together with a `$dumpvars(...)` call.

## Running locally

It is a static site — any HTTP server works (the `file://` protocol does **not**, because of ES modules and WebAssembly fetch). Keep all files together:

```
index.html
ivlpp.js  ivlpp.wasm
ivl.js    ivl.wasm
vvp.js    vvp.wasm
elk.bundled.js          # schematic layout engine (netlistsvg dependency)
netlistsvg.bundle.js    # schematic renderer
```

The two schematic bundles are self-hosted; grab them from the [netlistsvg](https://github.com/nturley/netlistsvg) project:

```bash
curl -L -o elk.bundled.js       https://nturley.github.io/netlistsvg/elk.bundled.js
curl -L -o netlistsvg.bundle.js https://nturley.github.io/netlistsvg/built/netlistsvg.bundle.js
```

The simulator runs fully offline. The **Synthesize** tab additionally needs those two local bundles for rendering, and fetches the Yosys WebAssembly (~8 MB) from a CDN the first time you synthesize (cached by the browser thereafter).

```bash
python3 -m http.server 8090
# then open http://localhost:8090/
```

## License & attribution

VeriSim bundles WebAssembly binaries built from **Icarus Verilog**, which is licensed under the **GNU General Public License, version 2 or later**. The compiled modules (`ivl.wasm`, `vvp.wasm`, `ivlpp.wasm`) are derivative works of that source, so they remain under the GPL, and this project is distributed under GPL-compatible terms.

- Icarus Verilog © Stephen Williams and contributors — https://github.com/steveicarus/iverilog
- Full license text: https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

The corresponding Icarus Verilog source (and the Emscripten build steps / patches used to produce the modules) is the `master` branch of the upstream repository at version 14.0 (devel), commit `c7530db` (2026-05-31).

The **Synthesize** feature relies on three additional open-source projects, loaded as-is (not modified):

- **Yosys** © Claire Xenia Wolf and contributors — synthesis engine, [ISC license](https://github.com/YosysHQ/yosys/blob/main/COPYING). Delivered to the browser via [YoWASP](https://yowasp.org/).
- **netlistsvg** © Neil Turley and contributors — schematic renderer, [MIT license](https://github.com/nturley/netlistsvg).
- **Eclipse Layout Kernel (ELK)** — diagram layout used by netlistsvg, [EPL-2.0](https://github.com/eclipse/elk).

---

*Built and maintained by [@senolgulgonul](https://github.com/senolgulgonul).*
