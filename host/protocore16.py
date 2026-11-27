#!/usr/bin/env python3
"""Host helpers for ProtoCore16 SPI Mode-0 register interface.

SPI pins (Tiny Tapeout / iCESugar FPGA top):
  ui[0]=SCLK  ui[1]=MOSI  ui[2]=CS_N  uo[0]=MISO  uo[1]=IRQ

Frame while CS low (MSB first):
  byte0 CMD  [7]=WE [6]=AUTOINC [5:0]=NBYTES-1
  byte1 ADDR
  byte2.. DATA

Reads need a few idle system clocks between ADDR and DATA so the slave can
latch reg_rdata into its shift register (see sim/tb_host_spi.v).

Board bring-up (Raspberry Pi Pico MicroPython): see pico_protocore16.py —
same register helpers / uart_tx / spi_master / i2c_controller smokes, bit-bang
SPI on GP2–GP6 → iCESugar PMOD2. This module stays CPython/sim-oriented
(HostBFM + PyEngine). FT232H is optional only; Pico is the documented hardware
host path.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol


# Register map (matches tt_um_protocore16.v)
REG_CTRL = 0x00
REG_STATUS = 0x01
REG_SMSEL = 0x02
REG_PROG_OFF = 0x03
REG_PROG_DATA = 0x04
REG_TXFIFO = 0x05
REG_RXFIFO = 0x06
REG_IRQ_FLAGS = 0x07
REG_IRQ_ENABLE = 0x08
REG_CLKDIV_LO = 0x09
REG_CLKDIV_HI = 0x0A
REG_PINCTRL = 0x0B
REG_PINCTRL2 = 0x0C
REG_EXECCTRL = 0x0D
REG_WRAPCFG = 0x0E
REG_SHIFTCTRL = 0x0F
REG_CRC_CTRL = 0x10
REG_CRC_B0 = 0x11
REG_CRC_B1 = 0x12
REG_PC = 0x13
REG_LEVELS = 0x14
REG_CRC_B2 = 0x15
REG_CRC_B3 = 0x16


def load_hex(path: str | Path) -> list[int]:
    words = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line:
            words.append(int(line, 16))
    return words


class RegBus(Protocol):
    """Minimal register access used by ProtoCore16Client helpers."""

    def write_reg(self, addr: int, data: int) -> None: ...
    def read_reg(self, addr: int) -> int: ...


class ProtoCore16Client:
    """Shared programming helpers; subclass or mix in with write_reg/read_reg.

    Hardware path: MicroPython on Pico implements the same methods in
    pico_protocore16.py (cannot import this file on-device).
    """

    def load_program(self: RegBus, sm: int, words: list[int]) -> None:
        self.write_reg(REG_SMSEL, sm)
        self.write_reg(REG_PROG_OFF, 0)
        for w in words:
            self.write_reg(REG_PROG_DATA, w & 0xFF)
            self.write_reg(REG_PROG_DATA, (w >> 8) & 0xFF)

    def configure_uart_tx(self: RegBus, sm: int, tx_pin: int, clkdiv_int: int) -> None:
        self.write_reg(REG_SMSEL, sm)
        self.write_reg(REG_CLKDIV_LO, 0)
        self.write_reg(REG_CLKDIV_HI, clkdiv_int & 0xFF)
        self.write_reg(REG_PINCTRL, ((tx_pin & 7) << 2) | 1)
        self.write_reg(REG_PINCTRL2, ((tx_pin & 7) << 5) | ((tx_pin & 7) << 2))
        self.write_reg(REG_EXECCTRL, (1 << 5) | (1 << 4))  # autopull, shift_right
        self.write_reg(REG_SHIFTCTRL, (8 << 4) | 8)

    def configure_spi_master(
        self: RegBus,
        sm: int,
        mosi_pin: int = 0,
        sclk_pin: int = 1,
        miso_pin: int = 2,
        cs_pin: int = 3,
        clkdiv_int: int = 255,
    ) -> None:
        """Mode-0 SPI master bases for firmware/spi_master.pca (MSB first).

        cs_pin lands in set_base for wiring symmetry; spi_master.pca does not
        toggle CS. EXECCTRL enables sideset (no autopush); shift_right=0.
        """
        self.write_reg(REG_SMSEL, sm)
        self.write_reg(REG_CLKDIV_LO, 0)
        self.write_reg(REG_CLKDIV_HI, clkdiv_int & 0xFF)
        self.write_reg(
            REG_PINCTRL,
            ((sclk_pin & 7) << 5) | ((cs_pin & 7) << 2) | 1,
        )
        self.write_reg(
            REG_PINCTRL2,
            ((mosi_pin & 7) << 5) | ((miso_pin & 7) << 2) | 1,
        )
        # side_en only — spi_master.pca has explicit push; autopush+push
        # fills the 4-deep RX FIFO after two bytes and stalls on push-block.
        self.write_reg(REG_EXECCTRL, (1 << 7))
        self.write_reg(REG_SHIFTCTRL, (8 << 4) | 8)

    def configure_i2c_controller(
        self: RegBus,
        sm: int,
        sda_pin: int = 0,
        scl_pin: int = 1,
        clkdiv_int: int = 255,
    ) -> None:
        """I²C controller bases for firmware/i2c_controller.pca (MSB first).

        sideset=SCL; set/out/in=SDA (open-drain via SET PINDIRS). EXECCTRL
        enables sideset only — no autopush/autopull (firmware pull/push).
        """
        self.write_reg(REG_SMSEL, sm)
        self.write_reg(REG_CLKDIV_LO, 0)
        self.write_reg(REG_CLKDIV_HI, clkdiv_int & 0xFF)
        self.write_reg(
            REG_PINCTRL,
            ((scl_pin & 7) << 5) | ((sda_pin & 7) << 2) | 1,
        )
        self.write_reg(
            REG_PINCTRL2,
            ((sda_pin & 7) << 5) | ((sda_pin & 7) << 2) | 1,
        )
        self.write_reg(REG_EXECCTRL, (1 << 7))
        self.write_reg(REG_SHIFTCTRL, (8 << 4) | 8)

    def enable_sm(self: RegBus, mask: int) -> None:
        self.write_reg(REG_CTRL, mask & 0xF)

    def tx_push(self: RegBus, sm: int, byte: int) -> None:
        self.write_reg(REG_SMSEL, sm)
        self.write_reg(REG_TXFIFO, byte & 0xFF)


@dataclass
class HostBFM(ProtoCore16Client):
    """SPI Mode-0 BFM driven via clocked callbacks (cocotb / Verilog-TB glue)."""

    write_ui: callable
    read_uo: callable
    step: callable  # advance 1 system clock
    half_period: int = 4  # system clocks per SPI half-bit
    read_idle: int = 8    # idle clocks between ADDR and DATA on reads

    def _ui(self, sclk: int, mosi: int, cs_n: int) -> int:
        return (cs_n << 2) | (mosi << 1) | sclk

    def _drive(self, sclk: int, mosi: int, cs_n: int, n: int | None = None) -> None:
        self.write_ui(self._ui(sclk, mosi, cs_n))
        for _ in range(self.half_period if n is None else n):
            self.step()

    def _byte(self, mosi: int, cs_n: int = 0) -> int:
        miso = 0
        for bi in range(7, -1, -1):
            bit = (mosi >> bi) & 1
            self._drive(0, bit, cs_n)
            self._drive(1, bit, cs_n)  # sample on rise
            miso = (miso << 1) | (self.read_uo() & 1)
            self._drive(0, bit, cs_n)
        return miso & 0xFF

    def write_reg(self, addr: int, data: int) -> None:
        self._drive(0, 0, 1, 2)
        self._drive(0, 0, 0, 2)  # CS active
        self._byte(0x80)  # WE=1, 1 data byte
        self._byte(addr & 0xFF)
        self._byte(data & 0xFF)
        self._drive(0, 0, 1, 4)

    def read_reg(self, addr: int) -> int:
        self._drive(0, 0, 1, 2)
        self._drive(0, 0, 0, 2)
        self._byte(0x00)
        self._byte(addr & 0xFF)
        for _ in range(self.read_idle):
            self.step()
        val = self._byte(0x00)
        self._drive(0, 0, 1, 4)
        return val


@dataclass
class PyEngine:
    """Minimal Python ISA model for unit-testing assemblers/firmware ideas."""

    imem: list[int] = field(default_factory=lambda: [0x9000] * 32)
    pc: int = 0
    x: int = 0
    y: int = 0
    osr: int = 0
    isr: int = 0
    gpio_out: int = 0
    gpio_oe: int = 0
    gpio_in: int = 0
    tx: list[int] = field(default_factory=list)
    rx: list[int] = field(default_factory=list)
    shift_right: bool = True
    enabled: bool = False
    trace: list[str] = field(default_factory=list)

    def step(self) -> None:
        if not self.enabled:
            return
        instr = self.imem[self.pc & 31]
        op = (instr >> 12) & 0xF
        pay = instr & 0xFF
        adv = True
        if op == 0x0:  # JMP
            cond = (pay >> 5) & 7
            addr = pay & 0x1F
            take = False
            if cond == 0:
                take = True
            elif cond == 1:
                take = self.x == 0
            elif cond == 2:
                take = self.x != 0
                self.x = (self.x - 1) & 0xFFFF
            elif cond == 3:
                take = self.y != 0
                self.y = (self.y - 1) & 0xFFFF
            elif cond == 4:
                take = self.y == 0
            elif cond == 5:
                take = self.x != self.y
            if take:
                self.pc = addr
                adv = False
        elif op == 0x5:  # PULL
            if self.tx:
                self.osr = self.tx.pop(0)
            else:
                adv = False
        elif op == 0x8:  # SET
            dst = (pay >> 5) & 7
            imm = pay & 0x1F
            if dst == 0:
                self.gpio_out = imm & 1
                self.gpio_oe = 1
            elif dst == 1:
                self.x = imm
            elif dst == 2:
                self.y = imm
        elif op == 0x3:  # OUT
            n = pay & 0x1F or 32
            dst = (pay >> 5) & 7
            if dst == 0:
                bit = self.osr & 1 if self.shift_right else (self.osr >> 31) & 1
                self.gpio_out = bit
                self.gpio_oe = 1
            if self.shift_right:
                self.osr >>= n
            else:
                self.osr = (self.osr << n) & 0xFFFFFFFF
        elif op == 0x4:  # PUSH
            self.rx.append(self.isr & 0xFF)
            self.isr = 0
        if adv:
            self.pc = (self.pc + 1) & 31
        self.trace.append(f"pc={self.pc:02x} out={self.gpio_out}")


def smoke_uart_tx_model(hex_path: str) -> list[int]:
    """Run UART TX program in PyEngine; return list of pin levels per bit time."""
    words = load_hex(hex_path)
    eng = PyEngine()
    for i, w in enumerate(words[:32]):
        eng.imem[i] = w
    eng.tx = [0x55]
    eng.enabled = True
    levels = []
    for _ in range(40):
        prev = eng.pc
        eng.step()
        levels.append(eng.gpio_out & 1)
        if eng.pc == 0 and prev != 0 and len(levels) > 5:
            break
    return levels
