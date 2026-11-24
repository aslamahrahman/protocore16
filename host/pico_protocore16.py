# ProtoCore16 SPI Mode-0 host for Raspberry Pi Pico (MicroPython)
#
# Copy this file to the Pico (Thonny / mpremote). It mirrors the register
# helpers in protocore16.py but uses machine.Pin bit-bang SPI so we can hold
# CS low and insert idle time between ADDR and DATA on reads.
#
# Default wiring → iCESugar PMOD2 (Muse Lab labels, 3.3 V, common GND):
#   Pico GP2  SCLK  →  P46
#   Pico GP3  MOSI  →  P44
#   Pico GP5  CS_N  →  P42
#   Pico GP4  MISO  ←  P37
#   Pico GP6  IRQ   ←  P36 (optional)
#   Pico GND        →  GND
#
# UART TX smoke appears on PMOD3 P34 (gpio[0]) and the green RGB LED.
# Idle STATUS on the 1-PE FPGA cut should read 0xF0 (not 0x00).

from machine import Pin
import time

# ---- pins (override if you remapped) ----
PIN_SCLK = 2
PIN_MOSI = 3
PIN_MISO = 4
PIN_CS = 5
PIN_IRQ = 6

# ---- register map (same as protocore16.py / tt_um_protocore16.v) ----
REG_CTRL = 0x00
REG_STATUS = 0x01
REG_SMSEL = 0x02
REG_PROG_OFF = 0x03
REG_PROG_DATA = 0x04
REG_TXFIFO = 0x05
REG_CLKDIV_LO = 0x09
REG_CLKDIV_HI = 0x0A
REG_PINCTRL = 0x0B
REG_PINCTRL2 = 0x0C
REG_EXECCTRL = 0x0D
REG_SHIFTCTRL = 0x0F

# Assembled firmware/uart_tx.pca (build/uart_tx.hex)
UART_TX_WORDS = [
    0x5040, 0x8000, 0x3001, 0x3001, 0x3001, 0x3001,
    0x3001, 0x3001, 0x3001, 0x3001, 0x8001, 0x0000,
]


class ProtoCore16Pico:
    """Bit-bang SPI Mode-0 master for ProtoCore16 on iCESugar."""

    def __init__(
        self,
        sclk=PIN_SCLK,
        mosi=PIN_MOSI,
        miso=PIN_MISO,
        cs=PIN_CS,
        irq=PIN_IRQ,
        half_us=2,
        read_idle_us=20,
    ):
        self.sclk = Pin(sclk, Pin.OUT, value=0)
        self.mosi = Pin(mosi, Pin.OUT, value=0)
        self.miso = Pin(miso, Pin.IN)
        self.cs = Pin(cs, Pin.OUT, value=1)
        self.irq = Pin(irq, Pin.IN)
        self.half_us = half_us
        self.read_idle_us = read_idle_us

    def _delay(self, us=None):
        time.sleep_us(self.half_us if us is None else us)

    def _byte(self, mosi_byte):
        miso = 0
        for bi in range(7, -1, -1):
            self.mosi.value((mosi_byte >> bi) & 1)
            self.sclk.value(0)
            self._delay()
            self.sclk.value(1)
            self._delay()
            miso = (miso << 1) | self.miso.value()
            self.sclk.value(0)
            self._delay()
        return miso & 0xFF

    def write_reg(self, addr, data):
        self.cs.value(1)
        self._delay(4)
        self.cs.value(0)
        self._delay(4)
        self._byte(0x80)  # WE=1, 1 data byte
        self._byte(addr & 0xFF)
        self._byte(data & 0xFF)
        self.cs.value(1)
        self._delay(8)

    def read_reg(self, addr):
        self.cs.value(1)
        self._delay(4)
        self.cs.value(0)
        self._delay(4)
        self._byte(0x00)
        self._byte(addr & 0xFF)
        # Idle while CS low so host_if can latch reg_rdata
        time.sleep_us(self.read_idle_us)
        val = self._byte(0x00)
        self.cs.value(1)
        self._delay(8)
        return val

    def load_program(self, sm, words):
        self.write_reg(REG_SMSEL, sm)
        self.write_reg(REG_PROG_OFF, 0)
        for w in words:
            self.write_reg(REG_PROG_DATA, w & 0xFF)
            self.write_reg(REG_PROG_DATA, (w >> 8) & 0xFF)

    def configure_uart_tx(self, sm, tx_pin, clkdiv_int):
        """clkdiv_int uses bits[15:8]; baud ≈ f_clk / (clkdiv_int + 1)."""
        self.write_reg(REG_SMSEL, sm)
        self.write_reg(REG_CLKDIV_LO, 0)
        self.write_reg(REG_CLKDIV_HI, clkdiv_int & 0xFF)
        self.write_reg(REG_PINCTRL, ((tx_pin & 7) << 2) | 1)
        self.write_reg(REG_PINCTRL2, ((tx_pin & 7) << 5) | ((tx_pin & 7) << 2))
        self.write_reg(REG_EXECCTRL, (1 << 5) | (1 << 4))  # autopull, shift_right
        self.write_reg(REG_SHIFTCTRL, (8 << 4) | 8)

    def enable_sm(self, mask):
        self.write_reg(REG_CTRL, mask & 0xF)

    def tx_push(self, sm, byte):
        self.write_reg(REG_SMSEL, sm)
        self.write_reg(REG_TXFIFO, byte & 0xFF)


def debug_spi():
    """Register readback + raw MISO levels — use when STATUS stays 0x00."""
    host = ProtoCore16Pico()
    print("pins: SCLK=GP%d MOSI=GP%d MISO=GP%d CS=GP%d" % (
        PIN_SCLK, PIN_MOSI, PIN_MISO, PIN_CS))
    print("MISO level CS=1: %d (expect 0 or 1, not stuck if floating odd)" % host.miso.value())
    host.cs.value(0)
    time.sleep_us(10)
    print("MISO level CS=0 idle: %d" % host.miso.value())
    host.cs.value(1)

    st = [host.read_reg(REG_STATUS) for _ in range(4)]
    print("STATUS x4:", ["0x%02x" % x for x in st], "  (expect ~0xF0 idle on 1-PE cut)")

    host.write_reg(REG_SMSEL, 0x5A)
    rb = host.read_reg(REG_SMSEL)
    print("SMSEL write 0x5A -> read 0x%02x  (expect 0x5A)" % rb)

    host.write_reg(REG_CTRL, 0x01)
    print("CTRL write 0x01 -> read 0x%02x  (expect 0x01)" % host.read_reg(REG_CTRL))

    # Unknown addr should return 0xA5 on fpga1 cut
    print("default reg 0x7F -> 0x%02x  (expect 0xA5)" % host.read_reg(0x7F))

    if rb != 0x5A:
        print("FAIL: no SPI readback — check MISO P37↔GP4, CS P42↔GP5, GND, bitstream.")
    else:
        print("PASS: SPI host path is alive.")
    return host


def smoke_uart_tx(baud=None, f_clk=12_000_000, tx_pin=0, byte=0x00, repeat=2500):
    """Load uart_tx on SM0, push bytes, watch PMOD3 P34 / green LED.

    clkdiv_hi is only 8 bits, so slowest bit rate at 12 MHz is ~46.9 kbaud
    (clkdiv_hi=255). Defaults use that floor + many 0x00 bytes so green stays
    lit/flickering for ~0.5 s. For a fast check: smoke_uart_tx(baud=115200, byte=0x55, repeat=8).
    """
    if baud is None:
        clkdiv_int = 255  # slowest integer divider
    else:
        clkdiv_int = max(0, min(255, (f_clk // baud) - 1))
    host = ProtoCore16Pico()
    # Idle 1-PE STATUS = {tx_e0, 111, 000, bz0} → 0xF0 when empty/not busy
    status = host.read_reg(REG_STATUS)
    print("STATUS=0x%02x (expect 0xF0 idle)  clkdiv_hi=%d (~%d baud)" % (
        status, clkdiv_int, f_clk // (clkdiv_int + 1)))
    if status == 0x00:
        print("STATUS 0x00 usually means MISO stuck low — run pico_protocore16.debug_spi()")
    host.load_program(0, UART_TX_WORDS)
    host.configure_uart_tx(0, tx_pin, clkdiv_int)
    host.enable_sm(0x1)
    for _ in range(repeat):
        host.tx_push(0, byte)
        # Keep TX FIFO fed; short pause only so PE doesn't starve visibly
        if (_ & 15) == 15:
            time.sleep_ms(1)
    print("pushed 0x%02x x%d — watch green LED / PMOD3 P34 (~%.2fs of frames)" % (
        byte, repeat, repeat * 10 / (f_clk / (clkdiv_int + 1))))
    print("STATUS after: 0x%02x" % host.read_reg(REG_STATUS))
    return host


# Auto-run when loaded as main on the Pico
if __name__ == "__main__":
    smoke_uart_tx()
