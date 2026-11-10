// Interrupt robustness environment: the tests run while timer interrupts arrive
// at random times. The handler only executes MRET; if interrupts are precise,
// the test results must not change at all.
#ifndef _ENV_IRQ_H
#define _ENV_IRQ_H
#define RVTEST_RV32U
#define RVTEST_RV64U
#define RVTEST_RV32M
#define RVTEST_RV64M
#define TESTNUM gp
#define RVTEST_CODE_BEGIN                                               \
        .section .text.init; .globl _start;                             \
_start: j 1f;                                                           \
        .align 2;                                                       \
irq_handler: mret;                                                      \
1:      la t0, irq_handler; csrw mtvec, t0;                             \
        li t0, 0x80; csrw mie, t0;          /* MTIE */                  \
        csrsi mstatus, 8;                   /* MIE  */                  \
        li t0, 0; li gp, 0;
#define RVTEST_CODE_END    unimp
#define RVTEST_PASS        li gp, 1; sw gp, tohost, t5; 1: j 1b;
#define RVTEST_FAIL        sll gp, gp, 1; or gp, gp, 1; sw gp, tohost, t5; 1: j 1b;
#define EXTRA_DATA
#define RVTEST_DATA_BEGIN                                               \
        EXTRA_DATA                                                      \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 6; .global tohost; tohost: .dword 0;                     \
        .align 6; .global fromhost; fromhost: .dword 0;                 \
        .popsection;                                                    \
        .align 4; .global begin_signature; begin_signature:
#define RVTEST_DATA_END    .align 4; .global end_signature; end_signature:
#endif
