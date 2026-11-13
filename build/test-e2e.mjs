import initIvl from './ivl.js';
import initVvp from './vvp.js';
const ivl = await initIvl({ print:()=>{}, printErr:()=>{} });
ivl.FS.writeFile('/ivl.conf', `basedir:/
module:system.vpi
generation:2005
generation:no-specify
out:/hello.vvp
iwidth:32
widthcap:65536
functor:cprop
functor:nodangle
flag:DLL=vvp.tgt
`);
ivl.FS.writeFile('/hello.v', `module main;
  reg [3:0] q = 0;
  initial begin
    $dumpfile("dump.vcd"); $dumpvars(0, main);
    #5 q = 10; #5 $display("q=%d", q); $finish;
  end
endmodule
`);
ivl.callMain(['-C/ivl.conf','--','/hello.v']);
const vvpCode = ivl.FS.readFile('/hello.vvp');
console.log('hello.vvp bytes:', vvpCode.length);
const out=[];
const vvp = await initVvp({ print:s=>out.push(s), printErr:s=>out.push('[e] '+s) });
vvp.FS.writeFile('/hello.vvp', vvpCode);
const rc = vvp.callMain(['/hello.vvp']);
console.log('=== vvp exit:', rc, '===');
console.log(out.join('\n'));
try { console.log('=== dump.vcd ===\n'+vvp.FS.readFile('/dump.vcd',{encoding:'utf8'})); }
catch(e){ console.log('!!! dump.vcd yok:', e.message); }
