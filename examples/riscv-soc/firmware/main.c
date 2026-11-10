// SoC demo firmware
//   - prints over the UART (polling the TX_BUSY flag)
//   - timer interrupt every TICK_CYCLES cycles: counts ticks, shows them on the GPIO outputs
//   - UART RX interrupt: stores each received character in upper case
//   - GPIO interrupt: counts rising edges on input pin 0 (a push button)
//   - main program: finds the primes below 50 (REMU), prints them in decimal (DIVU/REMU)
//   - finally checks its own results and prints "ALL OK" followed by EOT (0x04)
#include "soc.h"

#ifndef TICK_CYCLES
#define TICK_CYCLES 3000
#endif

static volatile uint32_t ticks, buttons, rx_count;
static volatile char     rx_buf[8];

__attribute__((interrupt("machine"))) void timer_isr(void)
{
    ticks++;
    GPIO_OUT = ticks;
    MTIMECMP_LO = MTIMECMP_LO + TICK_CYCLES;      // next tick (the high word stays 0 in this demo)
}

__attribute__((interrupt("machine"))) void uart_isr(void)
{
    char c = (char)UART_DATA;                     // reading DATA clears the interrupt
    if (c >= 'a' && c <= 'z') c -= 'a' - 'A';
    if (rx_count < sizeof rx_buf - 1) rx_buf[rx_count++] = c;
}

__attribute__((interrupt("machine"))) void gpio_isr(void)
{
    buttons++;
    GPIO_IRQ_PEND = 1;                            // acknowledge pin 0
}

static void putch(char c)
{
    while (UART_STATUS & UART_TX_BUSY) ;
    UART_DATA = (uint8_t)c;
}

static void print(const char *s)
{
    while (*s) putch(*s++);
}

static void print_dec(uint32_t v)
{
    char buf[10];
    int  n = 0;
    do { buf[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) putch(buf[--n]);
}

static void print_hex(uint32_t v)
{
    for (int i = 28; i >= 0; i -= 4) putch("0123456789abcdef"[(v >> i) & 15]);
}

static void finish(void)
{
    putch(0x04);                                  // EOT: tells the testbench to stop
    for (;;) ;
}

void exception_handler(void)
{
    print("\r\nEXCEPTION mcause=");  print_hex(csr_read(mcause));
    print(" mepc=");                 print_hex(csr_read(mepc));
    print("\r\n");
    finish();
}

void unused_handler(void)
{
    print("\r\nUNEXPECTED INTERRUPT\r\n");
    finish();
}

static int is_prime(uint32_t n)
{
    if (n < 2) return 0;
    for (uint32_t d = 2; d * d <= n; d++)
        if (n % d == 0) return 0;
    return 1;
}

int main(void)
{
    print("\r\nRV32IMC SoC   misa=0x");
    print_hex(csr_read(misa));
    print("\r\n");

    // interrupts: timer, UART RX, GPIO pin 0
    MTIMECMP_HI   = 0;
    MTIMECMP_LO   = MTIME_LO + TICK_CYCLES;
    UART_CTRL     = UART_RX_IRQ_EN;
    GPIO_IRQ_EN   = 1;
    csr_write(mie, MIE_MTIE | MIE_UART | MIE_GPIO);
    csr_set(mstatus, MSTATUS_MIE);

    uint32_t count = 0, sum = 0;
    print("primes:");
    for (uint32_t n = 0; n < 50; n++) {
        if (is_prime(n)) {
            putch(' ');
            print_dec(n);
            count++;
            sum += n;
        }
    }
    print("\r\n");

    // wait for 3 ticks, 3 received characters and one button press
    while (ticks < 3 || rx_count < 3 || buttons < 1) ;
    csr_clear(mstatus, MSTATUS_MIE);

    print("ticks=");     print_dec(ticks);
    print(" rx=");       print((const char *)rx_buf);
    print(" buttons=");  print_dec(buttons);
    print(" leds=");     print_dec(GPIO_OUT);
    print("\r\n");
    print("mcycle=");    print_dec(csr_read(mcycle));
    print(" minstret="); print_dec(csr_read(minstret));
    print("\r\n");

    int ok = count == 15 && sum == 328 && ticks >= 3 && buttons == 1 &&
             rx_buf[0] == 'A' && rx_buf[1] == 'B' && rx_buf[2] == 'C' && rx_count == 3;
    print(ok ? "ALL OK\r\n" : "FAILED\r\n");
    finish();
    return 0;
}
