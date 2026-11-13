#!/usr/bin/env bash
# Build the VeriSim WebAssembly modules (ivlpp, ivl, vvp) from Icarus Verilog.
#
#   Source   : https://github.com/steveicarus/iverilog  commit c7530db
#   Patch    : iverilog-wasm.patch (next to this script)
#   Toolchain: Emscripten 6.0.0
#
# Host packages needed: git make autoconf gperf bison flex python3
# Usage: ./build.sh            (output goes to ./work/out)
#        WORK=/tmp/vs ./build.sh
#        LINK_ONLY=1 WORK=/path/to/existing/tree ./build.sh
#                               (skip configure/compile, relink existing objects)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HERE/work}
OUT=$WORK/out
EMSDK_VERSION=6.0.0
IVERILOG_COMMIT=c7530db
JOBS=$(nproc)

mkdir -p "$WORK" "$OUT"
cd "$WORK"

# ---------- 1. Emscripten ----------
if [ ! -d emsdk ]; then
  git clone https://github.com/emscripten-core/emsdk
fi
./emsdk/emsdk install  "$EMSDK_VERSION"
./emsdk/emsdk activate "$EMSDK_VERSION"
set +u; source ./emsdk/emsdk_env.sh; set -u

# ---------- 2. Icarus Verilog source + patch ----------
if [ ! -d iverilog ]; then
  git clone https://github.com/steveicarus/iverilog
  git -C iverilog checkout "$IVERILOG_COMMIT"
  git -C iverilog apply "$HERE/iverilog-wasm.patch"
fi
cd iverilog

if [ -z "${LINK_ONLY:-}" ]; then
# ---------- 3. Configure ----------
sh autoconf.sh
emconfigure ./configure --host=wasm32-unknown-emscripten

# ---------- 4. Compile ----------
# The stock link rules expect dlopen-able plugins (vvp.tgt, system.vpi), so
# their final link step may fail or produce unusable output under Emscripten.
# Only the object files are needed; the real links are done in step 5, which
# stops with an error if any object is missing.
emmake make -j"$JOBS" -C ivlpp
emmake make -j"$JOBS" ivl                    || true
emmake make -j"$JOBS" -C tgt-vvp vvp.tgt     || true
emmake make -j"$JOBS" -C vvp vvp             || true
emmake make -j"$JOBS" -C vpi system.vpi      || true
fi

# ---------- 5. Link ----------
LINK_FLAGS=(
  -sMODULARIZE=1 -sEXPORT_ES6=1
  -sEXPORTED_RUNTIME_METHODS=callMain,FS
  -sINVOKE_RUN=0 -sEXIT_RUNTIME=0
  -sALLOW_MEMORY_GROWTH=1 -sFORCE_FILESYSTEM=1
)

# 5a. ivlpp (preprocessor)
( cd ivlpp
  emcc main.o lexor.o -o "$OUT/ivlpp.js" "${LINK_FLAGS[@]}" )

# 5b. ivl (compiler) with the vvp code generator (tgt-vvp) linked in statically
IVL_OBJS="main.o async.o design_dump.o discipline.o dup_expr.o elaborate.o
  elab_expr.o elaborate_analog.o elab_lval.o elab_net.o elab_scope.o elab_sig.o
  elab_sig_analog.o elab_type.o emit.o eval_attrib.o eval_tree.o expr_synth.o
  functor.o lexor.o lexor_keyword.o link_const.o load_module.o netlist.o
  netmisc.o nettypes.o net_analog.o net_assign.o net_design.o netclass.o
  netdarray.o netenum.o netparray.o netqueue.o netscalar.o netstruct.o
  netvector.o net_event.o net_expr.o net_func.o net_func_eval.o net_link.o
  net_modulo.o net_nex_input.o net_nex_output.o net_proc.o net_scope.o
  net_tran.o net_udp.o map_named_args.o pad_to_width.o parse.o parse_misc.o
  pform.o pform_analog.o pform_disciplines.o pform_dump.o pform_package.o
  pform_pclass.o pform_types.o symbol_search.o sync.o sys_funcs.o verinum.o
  verireal.o vpi_modules.o target.o Attrib.o HName.o Module.o PClass.o
  PDelays.o PEvent.o PExpr.o PFunction.o PGate.o PGenerate.o PModport.o
  PNamedItem.o PPackage.o PScope.o PSpec.o PTimingCheck.o PTask.o PUdp.o
  PWire.o Statement.o AStatement.o LineInfo.o StringHeap.o cprop.o
  exposenodes.o nodangle.o synth.o synth2.o syn-rules.o t-dll.o t-dll-api.o
  t-dll-expr.o t-dll-proc.o t-dll-analog.o"
TGT_VVP_OBJS="vvp.o draw_class.o draw_delay.o draw_enum.o draw_mux.o
  draw_net_input.o draw_substitute.o draw_switch.o draw_ufunc.o draw_vpi.o
  eval_condit.o eval_expr.o eval_object.o eval_real.o eval_string.o
  eval_vec4.o modpath.o stmt_assign.o vvp_process.o vvp_proc_loops.o
  vvp_scope.o"
# shellcheck disable=SC2086
em++ -std=c++11 -O2 $IVL_OBJS $(printf 'tgt-vvp/%s ' $TGT_VVP_OBJS) \
  -o "$OUT/ivl.js" "${LINK_FLAGS[@]}"

# 5c. vvp (runtime) with the system.vpi tasks linked in statically
VVP_OBJS="main.o lib_main.o parse.o parse_misc.o lexor.o arith.o
  array_common.o array.o bufif.o compile.o concat.o dff.o class_type.o
  enum_type.o extend.o file_line.o latch.o npmos.o part.o permaheap.o reduce.o
  resolv.o sfunc.o stop.o substitute.o symbols.o ufunc.o codes.o vthread.o
  schedule.o statistics.o tables.o udp.o vvp_island.o vvp_net.o vvp_net_sig.o
  vvp_object.o vvp_cobject.o vvp_darray.o event.o logic.o delay.o words.o
  island_tran.o vpi_modules.o vpi_bit.o vpi_callback.o vpi_cobject.o
  vpi_const.o vpi_darray.o vpi_event.o vpi_iter.o vpi_mcd.o vpi_priv.o
  vpi_scope.o vpi_real.o vpi_signal.o vpi_string.o vpi_tasks.o vpi_time.o
  vpi_vthr_vector.o vpip_bin.o vpip_hex.o vpip_oct.o vpip_to_dec.o
  vpip_format.o vvp_vpi.o"
VPI_OBJS="sys_table.o sys_convert.o sys_countdrivers.o sys_darray.o
  sys_deposit.o sys_display.o sys_fileio.o sys_finish.o sys_icarus.o
  sys_plusargs.o sys_queue.o sys_random.o sys_random_mti.o sys_readmem.o
  sys_readmem_lex.o sys_scanf.o sys_sdf.o sys_time.o sys_vcd.o sys_vcdoff.o
  vcd_priv.o mt19937int.o sys_priv.o sdf_parse.o sdf_lexor.o stringheap.o
  vams_simparam.o table_mod.o table_mod_parse.o table_mod_lexor.o vcd_priv2.o"
( cd vvp
  # shellcheck disable=SC2086
  em++ -std=c++11 -O2 $VVP_OBJS $(printf '../vpi/%s ' $VPI_OBJS) \
    -o "$OUT/vvp.js" "${LINK_FLAGS[@]}" )

# ---------- 6. Smoke test ----------
ls -l "$OUT"
if [ -f "$HERE/test-e2e.mjs" ]; then
  cp "$HERE/test-e2e.mjs" "$OUT/"
  ( cd "$OUT" && node test-e2e.mjs )
fi
echo "Done. Copy $OUT/{ivlpp,ivl,vvp}.{js,wasm} next to index.html."
