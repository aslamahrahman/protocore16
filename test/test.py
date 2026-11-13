# SPDX-FileCopyrightText: © 2024 Tiny Tapeout / ProtoCore16
# SPDX-License-Identifier: Apache-2.0

"""cocotb smoke: SPI-host load UART TX and check start bit on uio[0]."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


async def spi_byte(dut, mosi: int, half: int = 4) -> int:
    miso = 0
    for bi in range(7, -1, -1):
        bit = (mosi >> bi) & 1
        # CS stays low; keep ui[2]=0
        dut.ui_in.value = (0 << 2) | (bit << 1) | 0
        await ClockCycles(dut.clk, half)
        dut.ui_in.value = (0 << 2) | (bit << 1) | 1  # SCLK rise
        await ClockCycles(dut.clk, half // 2)
        miso = (miso << 1) | int(dut.uo_out.value) & 1
        await ClockCycles(dut.clk, half // 2)
        dut.ui_in.value = (0 << 2) | (bit << 1) | 0
        await ClockCycles(dut.clk, half)
    return miso & 0xFF


async def spi_write8(dut, addr: int, data: int) -> None:
    dut.ui_in.value = 0x04  # CS high
    await ClockCycles(dut.clk, 2)
    dut.ui_in.value = 0x00  # CS low
    await ClockCycles(dut.clk, 2)
    await spi_byte(dut, 0x80)
    await spi_byte(dut, addr & 0xFF)
    await spi_byte(dut, data & 0xFF)
    dut.ui_in.value = 0x04
    await ClockCycles(dut.clk, 4)


async def spi_read8(dut, addr: int) -> int:
    dut.ui_in.value = 0x04
    await ClockCycles(dut.clk, 2)
    dut.ui_in.value = 0x00
    await ClockCycles(dut.clk, 2)
    await spi_byte(dut, 0x00)
    await spi_byte(dut, addr & 0xFF)
    await ClockCycles(dut.clk, 8)  # read idle
    val = await spi_byte(dut, 0x00)
    dut.ui_in.value = 0x04
    await ClockCycles(dut.clk, 4)
    return val


UART_TX = [
    0x5040, 0x8000, 0x3001, 0x3001, 0x3001, 0x3001,
    0x3001, 0x3001, 0x3001, 0x3001, 0x8001, 0x0000,
]


@cocotb.test()
async def test_spi_host_uart(dut):
    dut._log.info("Start ProtoCore16 SPI host smoke")
    clock = Clock(dut.clk, 20, unit="ns")  # 50 MHz
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0x04
    dut.uio_in.value = 0xFF
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 4)

    await spi_write8(dut, 0x02, 0x05)
    got = await spi_read8(dut, 0x02)
    assert got == 0x05, f"SMSEL r/w failed: {got:#x}"

    await spi_write8(dut, 0x02, 0x00)  # SMSEL
    await spi_write8(dut, 0x03, 0x00)  # PROG_OFF
    for w in UART_TX:
        await spi_write8(dut, 0x04, w & 0xFF)
        await spi_write8(dut, 0x04, (w >> 8) & 0xFF)

    await spi_write8(dut, 0x09, 0x00)
    await spi_write8(dut, 0x0A, 0x03)
    await spi_write8(dut, 0x0B, 0x01)
    await spi_write8(dut, 0x0C, 0x00)
    await spi_write8(dut, 0x0D, 0x30)
    await spi_write8(dut, 0x0F, 0x88)
    await spi_write8(dut, 0x05, 0x55)
    await spi_write8(dut, 0x00, 0x01)  # enable SM0

    # Wait for UART start bit on uio[0]
    for _ in range(50000):
        await RisingEdge(dut.clk)
        oe = int(dut.uio_oe.value)
        out = int(dut.uio_out.value)
        if (oe & 1) and ((out & 1) == 0):
            dut._log.info("Saw UART start bit")
            break
    else:
        raise AssertionError("timeout waiting for UART start")

    # Sample 8 data bits (clkdiv int=3 → 4 clocks/tick)
    captured = 0
    for bi in range(8):
        await ClockCycles(dut.clk, 4)
        bit = int(dut.uio_out.value) & 1
        captured |= bit << bi
    assert captured == 0x55, f"UART data {captured:#x}"
    dut._log.info("PASS UART 0x55 via SPI host")
