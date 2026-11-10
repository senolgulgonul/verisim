// Register map of the SoC peripherals
#ifndef SOC_H
#define SOC_H
#include <stdint.h>

#define REG32(a)        (*(volatile uint32_t *)(a))

#define GPIO_OUT        REG32(0x40000000)
#define GPIO_IN         REG32(0x40000004)
#define GPIO_IRQ_EN     REG32(0x40000008)
#define GPIO_IRQ_PEND   REG32(0x4000000C)   // write 1 to clear

#define UART_DATA       REG32(0x40001000)
#define UART_STATUS     REG32(0x40001004)
#define UART_DIV        REG32(0x40001008)
#define UART_CTRL       REG32(0x4000100C)
#define UART_TX_BUSY    1u
#define UART_RX_VALID   2u
#define UART_RX_IRQ_EN  1u

#define MTIME_LO        REG32(0x40002000)
#define MTIME_HI        REG32(0x40002004)
#define MTIMECMP_LO     REG32(0x40002008)
#define MTIMECMP_HI     REG32(0x4000200C)
#define MSIP            REG32(0x40002010)

#define MIE_MTIE        (1u << 7)
#define MIE_UART        (1u << 16)
#define MIE_GPIO        (1u << 17)
#define MSTATUS_MIE     (1u << 3)

#define csr_read(csr)       ({ uint32_t v_; __asm__ volatile ("csrr %0, " #csr : "=r"(v_)); v_; })
#define csr_write(csr, v)   __asm__ volatile ("csrw " #csr ", %0" : : "r"((uint32_t)(v)))
#define csr_set(csr, v)     __asm__ volatile ("csrs " #csr ", %0" : : "r"((uint32_t)(v)))
#define csr_clear(csr, v)   __asm__ volatile ("csrc " #csr ", %0" : : "r"((uint32_t)(v)))

#endif
