# Startup code and vectored trap table
        .section .text.init
        .globl _start
_start: j     reset

        .align 2
        .option push
        .option norvc                 # table entries must be 4 bytes each
vectors:
        j     exception_handler       #  0 : all exceptions
        .rept 6
        j     unused_handler
        .endr
        j     timer_isr               #  7 : machine timer
        .rept 8
        j     unused_handler
        .endr
        j     uart_isr                # 16 : fast 0 = UART RX
        j     gpio_isr                # 17 : fast 1 = GPIO
        .option pop

reset:  la    sp, _stack_top
        la    t0, _bss_start          # clear .bss
        la    t1, _bss_end
1:      bgeu  t0, t1, 2f
        sw    zero, 0(t0)
        addi  t0, t0, 4
        j     1b
2:      la    t0, vectors
        ori   t0, t0, 1               # vectored mode
        csrw  mtvec, t0
        call  main
3:      j     3b
