// Tang Nano 9K demo firmware
//   - LEDs count up twice a second (timer interrupt)
//   - characters typed in a serial terminal are echoed back in upper case (UART RX interrupt)
//   - pressing S2 prints a message (GPIO interrupt)
//   - typing '?' prints a status line
// The clock frequency is derived from the UART divisor, so the same binary works
// at 27 MHz and at 13.5 MHz (HALF_SPEED).
#include "soc.h"

#define BAUD 115200u

static volatile uint32_t ticks, buttons;
static volatile uint8_t  rx_buf[16];
static volatile uint32_t rx_head, rx_tail;
static uint32_t          tick_cycles;

static void timer_schedule(uint64_t when)
{
    MTIMECMP_LO = 0xffffffffu;                    // no spurious interrupt while updating
    MTIMECMP_HI = (uint32_t)(when >> 32);
    MTIMECMP_LO = (uint32_t)when;
}

__attribute__((interrupt("machine"))) void timer_isr(void)
{
    uint64_t cmp = ((uint64_t)MTIMECMP_HI << 32) | MTIMECMP_LO;
    ticks++;
    GPIO_OUT = ticks;
    timer_schedule(cmp + tick_cycles);
}

__attribute__((interrupt("machine"))) void uart_isr(void)
{
    uint8_t c = (uint8_t)UART_DATA;               // reading DATA clears the interrupt
    if (rx_head - rx_tail < sizeof rx_buf) rx_buf[rx_head++ % sizeof rx_buf] = c;
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

void exception_handler(void)
{
    print("\r\nEXCEPTION mcause=");  print_hex(csr_read(mcause));
    print(" mepc=");                 print_hex(csr_read(mepc));
    print("\r\n");
    for (;;) ;
}

void unused_handler(void)
{
    print("\r\nUNEXPECTED INTERRUPT\r\n");
    for (;;) ;
}

static void status(void)
{
    print("\r\nuptime ");    print_dec(ticks / 2);
    print(" s, buttons ");   print_dec(buttons);
    print(", mcycle ");      print_dec(csr_read(mcycle));
    print(", minstret ");    print_dec(csr_read(minstret));
    print("\r\n");
}

int main(void)
{
    uint32_t clk_hz = UART_DIV * BAUD;
    uint32_t shown  = 0;

    tick_cycles = clk_hz / 2;                     // two ticks per second

    print("\r\n\r\nRV32IMC SoC on Tang Nano 9K\r\n");
    print("misa=0x");  print_hex(csr_read(misa));
    print("  clock ~");  print_dec(clk_hz / 1000);  print(" kHz\r\n");
    print("Type to get an upper-case echo, '?' for status, press S2.\r\n");

    timer_schedule((((uint64_t)MTIME_HI << 32) | MTIME_LO) + tick_cycles);
    UART_CTRL   = UART_RX_IRQ_EN;
    GPIO_IRQ_EN = 1;
    csr_write(mie, MIE_MTIE | MIE_UART | MIE_GPIO);
    csr_set(mstatus, MSTATUS_MIE);

    for (;;) {
        if (rx_head != rx_tail) {
            char c = (char)rx_buf[rx_tail++ % sizeof rx_buf];
            if (c == '?')                  status();
            else if (c == '\r')            print("\r\n");
            else {
                if (c >= 'a' && c <= 'z')  c -= 'a' - 'A';
                putch(c);
            }
        }
        if (buttons != shown) {
            shown = buttons;
            print("\r\n[S2 pressed ");  print_dec(shown);  print(" times]\r\n");
        }
    }
}
