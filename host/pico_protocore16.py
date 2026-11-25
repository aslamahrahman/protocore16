# ProtoCore16 SPI Mode-0 host for Raspberry Pi Pico (MicroPython)
#
# Copy this file to the Pico (Thonny / mpremote). It mirrors the register
# helpers in protocore16.py but uses machine.Pin bit-bang SPI so we can hold
# CS low and insert idle time between ADDR and DATA on reads.
#
# Default host wiring → iCESugar PMOD2 (Muse Lab labels, 3.3 V, common GND):
#   Pico GP2  SCLK  →  P46
#   Pico GP3  MOSI  →  P44
#   Pico GP5  CS_N  →  P42
#   Pico GP4  MISO  ←  P37
#   Pico GP6  IRQ   ←  P36 (optional)
#   Pico GND        →  GND
#
# PE SPI-master smoke (PMOD3 uio → Pico slave on free GPs, not GP2–5):
#   PMOD3 P34  uio[0] MOSI  →  Pico GP11
#   PMOD3 P31  uio[1] SCLK  →  Pico GP10
#   PMOD3 P27  uio[2] MISO  ←  Pico GP12  (slave drives dummy 0)
#   PMOD3 P25  uio[3] CS*   →  Pico GP13  (*spi_master.pca does not toggle CS;
#                              tie GP13 to GND or ignore_cs=True on the slave)
#
# PE I²C-controller smoke (same PMOD3 P34/P31 → GP11/GP10; Pico listen-only):
#   PMOD3 P34  uio[0] SDA  →  Pico GP11  (set/out/in; PE open-drain via PINDIRS)
#   PMOD3 P31  uio[1] SCL  →  Pico GP10  (sideset; PE drives)
#   Pico uses Pin.IN + START/SCL IRQs (not OPEN_DRAIN — that hid external edges).
#   FPGA SB_IO pull-ups on gpio[]; optional external 4.7 kΩ to 3.3 V on SDA/SCL
#
# UART TX smoke appears on PMOD3 P34 (gpio[0]) and the green RGB LED.
# Idle STATUS on the 1-PE FPGA cut should read 0xF0 (not 0x00).
# read_reg() double-frames to work around host_if stale rdata_q latching.
# smoke_spi_master / smoke_i2c_controller: prepare_sm + IRQ capture (no _thread);
# autopush off (firmware already push/es).

from machine import Pin
import time

# ---- host SPI pins (override if you remapped) ----
PIN_SCLK = 2
PIN_MOSI = 3
PIN_MISO = 4
PIN_CS = 5
PIN_IRQ = 6

# ---- PE SPI-master ↔ Pico slave (must not collide with GP2–5 host SPI) ----
PIN_SLAVE_SCLK = 10
PIN_SLAVE_MOSI = 11
PIN_SLAVE_MISO = 12
PIN_SLAVE_CS = 13

# PE I²C target on Pico — same SCL/SDA nets as SPI SCLK/MOSI (GP10/GP11)
PIN_I2C_SCL = 10
PIN_I2C_SDA = 11

# PE uio indices matching firmware/spi_master.pca comments + PMOD3 map
PE_SPI_MOSI = 0   # PMOD3 P34
PE_SPI_SCLK = 1   # PMOD3 P31
PE_SPI_MISO = 2   # PMOD3 P27
PE_SPI_CS = 3     # PMOD3 P25 — wiring only; firmware does not drive CS

# PE uio for firmware/i2c_controller.pca — sideset=SCL, set/out/in=SDA
PE_I2C_SDA = 0    # PMOD3 P34
PE_I2C_SCL = 1    # PMOD3 P31

# ---- register map (same as protocore16.py / tt_um_protocore16.v) ----
REG_CTRL = 0x00
REG_STATUS = 0x01
REG_SMSEL = 0x02
REG_PROG_OFF = 0x03
REG_PROG_DATA = 0x04
REG_TXFIFO = 0x05
REG_RXFIFO = 0x06
REG_CLKDIV_LO = 0x09
REG_CLKDIV_HI = 0x0A
REG_PINCTRL = 0x0B
REG_PINCTRL2 = 0x0C
REG_EXECCTRL = 0x0D
REG_SHIFTCTRL = 0x0F
REG_PC = 0x13
REG_LEVELS = 0x14

# Assembled firmware/uart_tx.pca (build/uart_tx.hex)
UART_TX_WORDS = [
    0x5040, 0x8000, 0x3001, 0x3001, 0x3001, 0x3001,
    0x3001, 0x3001, 0x3001, 0x3001, 0x8001, 0x0000,
]

# Assembled firmware/spi_master.pca (build/spi_master.hex)
# out_base=MOSI, side_base=SCLK, in_base=MISO; MSB-first Mode 0
SPI_MASTER_WORDS = [
    0x5040, 0x8027, 0x3001, 0xB001, 0x2001, 0xB000, 0x0042, 0x4040, 0x0000,
]

# Assembled firmware/i2c_controller.pca (build/i2c_controller.hex)
# sideset=SCL, set/out/in=SDA; START + addr + ACK sample + data + STOP
I2C_CONTROLLER_WORDS = [
    0x5040, 0x8860, 0x8861, 0x8800, 0x9000, 0x8027, 0x8061, 0x3001,
    0x9800, 0x9000, 0x0046, 0x8060, 0x9800, 0x2801, 0x9000, 0x4000,
    0x5040, 0x8027, 0x8061, 0x3001, 0x9800, 0x9000, 0x0052, 0x8060,
    0x9800, 0x9000, 0x8061, 0x8000, 0x9800, 0x8860, 0x0000,
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

    def _read_reg_once(self, addr):
        """One SPI read frame. May return stale rdata — prefer read_reg()."""
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

    def read_reg(self, addr):
        """Read register with host_if latch workaround.

        host_if pulses reg_re on ADDR and copies reg_rdata into rdata_q that
        same cycle — but reg_rdata still reflects the *previous* reg_addr.
        A second identical frame returns the value for `addr`. Without this,
        STATUS after enable_sm often reads back as CTRL (0x01).
        """
        self._read_reg_once(addr)  # select addr / prime latch
        return self._read_reg_once(addr)

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

    def configure_spi_master(
        self,
        sm,
        mosi_pin=PE_SPI_MOSI,
        sclk_pin=PE_SPI_SCLK,
        miso_pin=PE_SPI_MISO,
        cs_pin=PE_SPI_CS,
        clkdiv_int=255,
    ):
        """Mode-0 SPI master pin bases for firmware/spi_master.pca.

        PINCTRL:  side_base[7:5]=SCLK, set_base[4:2]=CS (unused by fw), set_count=1
        PINCTRL2: out_base[7:5]=MOSI, in_base[4:2]=MISO, side_count=1
        EXECCTRL: side_en only; shift_right=0 (MSB first). Autopush is OFF —
        spi_master.pca already has an explicit push; autopush+push filled the
        4-deep RX FIFO after two bytes and parked PC on push-block.
        cs_pin is recorded in set_base for wiring docs only — spi_master.pca
        never toggles CS (tie Pico slave CS low or ignore_cs=True).
        """
        self.write_reg(REG_SMSEL, sm)
        self.write_reg(REG_CLKDIV_LO, 0)
        self.write_reg(REG_CLKDIV_HI, clkdiv_int & 0xFF)
        # side_base | set_base | set_count
        self.write_reg(
            REG_PINCTRL,
            ((sclk_pin & 7) << 5) | ((cs_pin & 7) << 2) | 1,
        )
        # out_base | in_base | side_count
        self.write_reg(
            REG_PINCTRL2,
            ((mosi_pin & 7) << 5) | ((miso_pin & 7) << 2) | 1,
        )
        # side_en | !autopush | !autopull | !shift_right
        self.write_reg(REG_EXECCTRL, (1 << 7))
        self.write_reg(REG_SHIFTCTRL, (8 << 4) | 8)

    def configure_i2c_controller(
        self,
        sm,
        sda_pin=PE_I2C_SDA,
        scl_pin=PE_I2C_SCL,
        clkdiv_int=255,
    ):
        """I²C controller pin bases for firmware/i2c_controller.pca.

        sideset=SCL, set/out/in all = SDA (open-drain via SET PINDIRS).
        PINCTRL:  side_base[7:5]=SCL, set_base[4:2]=SDA, set_count=1
        PINCTRL2: out_base[7:5]=SDA, in_base[4:2]=SDA, side_count=1
        EXECCTRL: side_en only; shift_right=0 (MSB first). Autopush/autopull
        OFF — firmware uses explicit pull/push (same stall risk as SPI).
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

    def enable_sm(self, mask):
        self.write_reg(REG_CTRL, mask & 0xF)

    def tx_push(self, sm, byte):
        self.write_reg(REG_SMSEL, sm)
        self.write_reg(REG_TXFIFO, byte & 0xFF)

    def drain_rx(self, sm=0, n=8):
        """Pop up to n RX FIFO bytes (ignores values)."""
        self.write_reg(REG_SMSEL, sm)
        for _ in range(n):
            self.read_reg(REG_RXFIFO)

    def prepare_sm(self, sm=0):
        """Stop SM0, drain FIFOs, force PC to 0 without FPGA reset.

        PE PC does not clear on CTRL=0. A prior spi_master run that stalled on
        push (RX full) left PC at the push insn — re-enable then never clocks.
        Workaround: load jmp-0 filler, briefly enable so PC collapses to 0,
        then pull-drain any leftover TX.
        """
        self.write_reg(REG_CTRL, 0)
        self.drain_rx(sm)
        self.write_reg(REG_SMSEL, sm)
        self.write_reg(REG_CLKDIV_LO, 0)
        self.write_reg(REG_CLKDIV_HI, 0)
        self.write_reg(REG_EXECCTRL, 0)
        # Every slot = JMP always → 0; from any PC we land on 0.
        self.load_program(sm, [0x0000] * 32)
        self.enable_sm(1 << sm)
        time.sleep_ms(1)
        self.write_reg(REG_CTRL, 0)
        # Drain TX: pull-block then jmp 0 until empty, then stall on pull @0.
        self.load_program(sm, [0x5040, 0x0000])
        self.enable_sm(1 << sm)
        time.sleep_ms(2)
        self.write_reg(REG_CTRL, 0)
        self.drain_rx(sm)

    def release_pe_oe(self, sm=0, set_base=0, set_count=2):
        """Clear gpio_oe on set_base..+set_count so pull-ups can idle high.

        PE OE freezes when SM stops — leftover SPI/I2C sideset often leaves
        SCL (uio[1]) driven low → idle SCL=0 before the next smoke. SDA=uio[0]
        and SCL=uio[1] are contiguous; set_base=0,set_count=2 clears both.
        """
        self.write_reg(REG_CTRL, 0)
        self.write_reg(REG_SMSEL, sm)
        self.write_reg(REG_CLKDIV_LO, 0)
        self.write_reg(REG_CLKDIV_HI, 0)
        self.write_reg(REG_EXECCTRL, 0)
        self.write_reg(
            REG_PINCTRL,
            ((set_base & 7) << 2) | (set_count & 3),
        )
        self.write_reg(REG_PINCTRL2, 0)
        # set pindirs, 0 ; jmp 0
        self.load_program(sm, [0x8060, 0x0000])
        self.enable_sm(1 << sm)
        time.sleep_ms(1)
        self.write_reg(REG_CTRL, 0)


class SpiSlaveBitbang:
    """Mode-0 SPI slave (MSB first) — MicroPython machine.SPI is master-only.

    Samples MOSI on SCLK rising edge. CS is optional: when ignore_cs=False,
    capture runs only while CS is low. Drive MISO with a fixed bit (default 0).

    Prefer irq_recv_bytes() on core 0 — RP2040 _thread + Pin polling is flaky.
    """

    def __init__(
        self,
        sclk=PIN_SLAVE_SCLK,
        mosi=PIN_SLAVE_MOSI,
        miso=PIN_SLAVE_MISO,
        cs=PIN_SLAVE_CS,
        ignore_cs=True,
        miso_level=0,
    ):
        self.sclk = Pin(sclk, Pin.IN)
        self.mosi = Pin(mosi, Pin.IN)
        self.miso = Pin(miso, Pin.OUT, value=miso_level & 1)
        self.cs = Pin(cs, Pin.IN, pull=Pin.PULL_DOWN)  # idle selected if floating
        self.ignore_cs = ignore_cs
        self.miso_level = miso_level & 1
        self._bits = []

    def _cs_active(self):
        return self.ignore_cs or (self.cs.value() == 0)

    def _on_sclk_rise(self, _pin):
        if self._cs_active():
            self._bits.append(self.mosi.value() & 1)
            self.miso.value(self.miso_level)

    def irq_arm(self):
        """Start collecting MOSI bits on SCLK rising (core-0 IRQ)."""
        self._bits = []
        self.sclk.irq(handler=self._on_sclk_rise, trigger=Pin.IRQ_RISING)

    def irq_disarm(self):
        self.sclk.irq(handler=None)

    def irq_recv_bytes(self, count=1, timeout_ms=3000):
        """Wait until IRQ path gathered count bytes; return list (may be short)."""
        need = count * 8
        deadline = time.ticks_add(time.ticks_ms(), timeout_ms)
        while len(self._bits) < need:
            if time.ticks_diff(deadline, time.ticks_ms()) < 0:
                break
            time.sleep_ms(1)
        self.irq_disarm()
        bits = self._bits
        self._bits = []
        out = []
        for i in range(0, len(bits) - (len(bits) % 8), 8):
            acc = 0
            for b in bits[i : i + 8]:
                acc = ((acc << 1) | b) & 0xFF
            out.append(acc)
            if len(out) >= count:
                break
        return out

    def recv_byte(self, timeout_ms=2000):
        """Block until 8 Mode-0 bits arrive; return int or None on timeout."""
        deadline = time.ticks_add(time.ticks_ms(), timeout_ms)
        prev = self.sclk.value()
        acc = 0
        n = 0
        while n < 8:
            if time.ticks_diff(deadline, time.ticks_ms()) < 0:
                return None
            if not self._cs_active():
                prev = self.sclk.value()
                continue
            cur = self.sclk.value()
            if cur and not prev:  # rising edge
                acc = ((acc << 1) | self.mosi.value()) & 0xFF
                self.miso.value(self.miso_level)
                n += 1
            prev = cur
        return acc

    def recv_bytes(self, count=1, timeout_ms=2000):
        out = []
        for _ in range(count):
            b = self.recv_byte(timeout_ms=timeout_ms)
            if b is None:
                break
            out.append(b)
        return out


class I2cTargetBitbang:
    """Listen-only I²C target capture for PE i2c_controller.pca (MicroPython).

    machine.I2C is controller-only on RP2 — bitbang + IRQ only. Same lesson as
    SpiSlaveBitbang: Pin.IN + edge IRQ on core 0 (not OPEN_DRAIN, not _thread).

    Framing: accept START (SDA↓ while SCL high) only in idle/done — never reset
    mid-addr/mid-data (false STARTs during ACK/bit edges caused addr=0x5A with
    starts>1). STOP (SDA↑ while SCL high) returns to idle. Skip ACK SCL rises.
    """

    def __init__(self, scl=PIN_I2C_SCL, sda=PIN_I2C_SDA, address=0x50):
        self._scl_n = scl
        self._sda_n = sda
        self.address = address & 0x7F
        # Kill leftover SPI-slave IRQs / OUT mode on the same GPs, then IN+pull.
        self.scl = Pin(scl, Pin.IN, Pin.PULL_UP)
        self.sda = Pin(sda, Pin.IN, Pin.PULL_UP)
        self.scl.irq(handler=None)
        self.sda.irq(handler=None)
        self._reset_capture()

    def _reset_capture(self):
        self._bits = 0
        self._bitn = 0
        self._phase = 0  # 0=idle 1=addr 2=data 3=done (pre-STOP)
        self._skip_ack = False
        self._addr_byte = None
        self._data_bytes = []
        self._matched = False
        self._starts = 0
        self._stops = 0
        self._scl_edges = 0
        self._starts_ignored = 0

    def _on_sda_fall(self, _pin):
        # START: SDA↓ while SCL high — only when idle/done (not mid-frame)
        if self.scl.value() != 1:
            return
        if self._phase in (1, 2):
            self._starts_ignored += 1
            return
        self._bits = 0
        self._bitn = 0
        self._phase = 1
        self._skip_ack = False
        self._matched = False
        self._addr_byte = None
        self._data_bytes = []
        self._starts += 1

    def _on_sda_rise(self, _pin):
        # STOP: SDA↑ while SCL high → idle (allows a later repeated START)
        if self.scl.value() == 1 and self._phase != 0:
            self._phase = 0
            self._skip_ack = False
            self._bitn = 0
            self._stops += 1

    def _on_sda_edge(self, pin):
        if pin.value() == 0:
            self._on_sda_fall(pin)
        else:
            self._on_sda_rise(pin)

    def _on_scl_rise(self, _pin):
        if self._phase == 0 or self._phase == 3:
            return
        self._scl_edges += 1
        # ACK slot after every 8 data bits — PE samples, we do not shift
        if self._skip_ack:
            self._skip_ack = False
            if self._phase == 1:
                self._phase = 2  # next bits are data
            else:
                self._phase = 3  # done after data ACK (STOP follows)
            return
        self._bits = ((self._bits << 1) | (self.sda.value() & 1)) & 0xFF
        self._bitn += 1
        if self._bitn < 8:
            return
        byte = self._bits
        self._bits = 0
        self._bitn = 0
        self._skip_ack = True
        if self._phase == 1:
            self._addr_byte = byte
            self._matched = ((byte >> 1) & 0x7F) == self.address
        else:
            self._data_bytes.append(byte)

    def irq_arm(self):
        self._reset_capture()
        # Re-assert IN (clears any prior OUT/OPEN_DRAIN from older host builds)
        self.scl = Pin(self._scl_n, Pin.IN, Pin.PULL_UP)
        self.sda = Pin(self._sda_n, Pin.IN, Pin.PULL_UP)
        self.scl.irq(handler=None)
        self.sda.irq(handler=None)
        self.sda.irq(handler=self._on_sda_edge, trigger=Pin.IRQ_FALLING | Pin.IRQ_RISING)
        self.scl.irq(handler=self._on_scl_rise, trigger=Pin.IRQ_RISING)

    def irq_disarm(self):
        self.scl.irq(handler=None)
        self.sda.irq(handler=None)

    def irq_wait(self, expect_data=1, timeout_ms=3000):
        """Wait until addr+expect_data bytes captured; return (addr, data_list)."""
        deadline = time.ticks_add(time.ticks_ms(), timeout_ms)
        while time.ticks_diff(deadline, time.ticks_ms()) > 0:
            if self._addr_byte is not None and len(self._data_bytes) >= expect_data:
                break
            if self._phase == 3 and len(self._data_bytes) >= expect_data:
                break
            time.sleep_ms(1)
        self.irq_disarm()
        return self._addr_byte, list(self._data_bytes)


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
    host.write_reg(REG_CTRL, 0x00)  # leave SM stopped for later smokes

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
    host.prepare_sm(0)
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


def smoke_spi_master(
    byte=0xA5,
    repeat=4,
    f_clk=12_000_000,
    clkdiv_int=255,
    mosi_pin=PE_SPI_MOSI,
    sclk_pin=PE_SPI_SCLK,
    miso_pin=PE_SPI_MISO,
    cs_pin=PE_SPI_CS,
    slave_sclk=PIN_SLAVE_SCLK,
    slave_mosi=PIN_SLAVE_MOSI,
    slave_miso=PIN_SLAVE_MISO,
    slave_cs=PIN_SLAVE_CS,
    ignore_cs=True,
    timeout_ms=3000,
):
    """PE SPI master on PMOD3 → Pico bitbang slave on GP10–13.

    Loads spi_master on SM0, sets pin bases (MOSI/SCLK/MISO + CS wiring slot),
    pushes `byte`, enables SM, and prints bytes captured on the Pico slave.
    machine.SPI cannot be a slave on RP2040/RP2350 MicroPython — bitbang/IRQ only.

    Kick sequence: prepare_sm (PC→0, drain FIFOs) → load → configure (no
    autopush) → TX push → IRQ-arm → enable → collect. Capture uses SCLK IRQ on
    core 0 (not _thread — RP2 dual-core Pin polling misses edges).
    """
    bit_hz = f_clk // (clkdiv_int + 1)
    print("PE SPI master smoke: MOSI=uio[%d] SCLK=uio[%d] MISO=uio[%d] CS=uio[%d](fw unused)" % (
        mosi_pin, sclk_pin, miso_pin, cs_pin))
    print("Pico slave: SCLK=GP%d MOSI=GP%d MISO=GP%d CS=GP%d ignore_cs=%s" % (
        slave_sclk, slave_mosi, slave_miso, slave_cs, ignore_cs))
    print("clkdiv_hi=%d (~%d Hz bit ticks)  push 0x%02x x%d" % (
        clkdiv_int, bit_hz, byte, repeat))

    host = ProtoCore16Pico()
    # Stop any leftover SM before STATUS so we can trust idle/busy bits.
    host.write_reg(REG_CTRL, 0)
    status = host.read_reg(REG_STATUS)
    print("STATUS=0x%02x (expect 0xF0 idle; 0x71=busy+TX pending leftover)" % status)
    if status == 0x00:
        print("STATUS 0x00 — run debug_spi() before PE SPI smoke")
        return host

    slave = SpiSlaveBitbang(
        sclk=slave_sclk,
        mosi=slave_mosi,
        miso=slave_miso,
        cs=slave_cs,
        ignore_cs=ignore_cs,
    )

    host.prepare_sm(0)
    host.load_program(0, SPI_MASTER_WORDS)
    host.configure_spi_master(
        0,
        mosi_pin=mosi_pin,
        sclk_pin=sclk_pin,
        miso_pin=miso_pin,
        cs_pin=cs_pin,
        clkdiv_int=clkdiv_int,
    )
    for _ in range(repeat):
        host.tx_push(0, byte)

    # Arm IRQ *before* enable so the first SCLK rise is not missed.
    slave.irq_arm()
    host.enable_sm(0x1)
    # ~1 ms/byte at clkdiv=255; give headroom beyond PE runtime.
    captured = slave.irq_recv_bytes(count=repeat, timeout_ms=timeout_ms)
    host.write_reg(REG_CTRL, 0)

    print("slave captured:", ["0x%02x" % b for b in captured] if captured else "(none)")
    if byte in captured:
        print("PASS: saw 0x%02x on Pico slave MOSI" % byte)
    else:
        print("FAIL: expected 0x%02x — check PMOD3↔GP10–13 wiring / GND / bitstream" % byte)
    st_after = host.read_reg(REG_STATUS)
    pc = host.read_reg(REG_PC)
    lv = host.read_reg(REG_LEVELS)
    print("STATUS after: 0x%02x  PC=0x%02x  LEVELS=0x%02x (expect ~0xF0/0xF1, PC~0)" % (
        st_after, pc, lv))
    return host


def smoke_i2c_controller(
    addr_byte=0xA0,
    data_byte=0x5A,
    repeat=1,
    f_clk=12_000_000,
    clkdiv_int=255,
    sda_pin=PE_I2C_SDA,
    scl_pin=PE_I2C_SCL,
    target_scl=PIN_I2C_SCL,
    target_sda=PIN_I2C_SDA,
    timeout_ms=3000,
):
    """PE I²C controller on PMOD3 → Pico listen-only target on GP10/GP11.

    Loads i2c_controller on SM0 (START + addr + ACK sample + data + STOP).
    Each transaction needs two TX pushes: addr_byte then data_byte.
    Pico is Pin.IN capture (SPI-slave pattern); firmware does not stall on NACK.

    Pin map: sideset=SCL=uio[1]/P31/GP10, set/out/in=SDA=uio[0]/P34/GP11.
    Kick: prepare_sm → load → configure (autopush off) → TX push pairs →
    IRQ-arm → enable → collect. Same prepare_sm / double-read lessons as SPI.
    """
    address7 = (addr_byte >> 1) & 0x7F
    bit_hz = f_clk // (clkdiv_int + 1)
    print("PE I2C controller smoke: SDA=uio[%d] SCL=uio[%d]" % (sda_pin, scl_pin))
    print("Pico target (listen-only): SCL=GP%d SDA=GP%d addr7=0x%02x (expect 0x%02x)" % (
        target_scl, target_sda, address7, addr_byte))
    print("clkdiv_hi=%d (~%d Hz ticks)  push addr=0x%02x data=0x%02x x%d" % (
        clkdiv_int, bit_hz, addr_byte, data_byte, repeat))

    host = ProtoCore16Pico()
    host.write_reg(REG_CTRL, 0)
    status = host.read_reg(REG_STATUS)
    print("STATUS=0x%02x (expect 0xF0 idle)" % status)
    if status == 0x00:
        print("STATUS 0x00 — run debug_spi() before PE I2C smoke")
        return host

    host.prepare_sm(0)
    # Drop leftover SPI/I2C OE (often holds SCL low) so pull-ups idle both high.
    host.release_pe_oe(0, set_base=min(sda_pin, scl_pin), set_count=2)

    target = I2cTargetBitbang(scl=target_scl, sda=target_sda, address=address7)
    print("idle SCL=%d SDA=%d (expect 1/1 after release_pe_oe + pull-ups)" % (
        target.scl.value(), target.sda.value()))
    if target.scl.value() == 0:
        print(
            "warn: SCL still low — PE OE may not have cleared, or no pull-up on "
            "P31↔GP10; add 4.7k to 3.3V if needed"
        )

    host.load_program(0, I2C_CONTROLLER_WORDS)
    host.configure_i2c_controller(
        0,
        sda_pin=sda_pin,
        scl_pin=scl_pin,
        clkdiv_int=clkdiv_int,
    )
    pinctrl = host.read_reg(REG_PINCTRL)
    pinctrl2 = host.read_reg(REG_PINCTRL2)
    execctrl = host.read_reg(REG_EXECCTRL)
    print(
        "PINCTRL=0x%02x PINCTRL2=0x%02x EXEC=0x%02x (expect 0x21 / 0x01 / 0x80)"
        % (pinctrl, pinctrl2, execctrl)
    )
    for _ in range(repeat):
        host.tx_push(0, addr_byte)
        host.tx_push(0, data_byte)

    # Arm before enable so START / first SCL edges are not missed.
    target.irq_arm()
    host.enable_sm(0x1)
    got_addr, got_data = target.irq_wait(expect_data=repeat, timeout_ms=timeout_ms)
    host.write_reg(REG_CTRL, 0)

    # Drain ACK samples the firmware pushed (values depend on shift packing)
    host.drain_rx(0, n=4)

    print(
        "target addr_byte=%s data=%s matched=%s starts=%d ignored=%d "
        "stops=%d scl_edges=%d"
        % (
            ("0x%02x" % got_addr) if got_addr is not None else "None",
            ["0x%02x" % b for b in got_data] if got_data else "(none)",
            target._matched,
            target._starts,
            target._starts_ignored,
            target._stops,
            target._scl_edges,
        )
    )
    ok = got_addr == addr_byte and data_byte in got_data
    if ok:
        print("PASS: Pico target saw addr 0x%02x data 0x%02x" % (addr_byte, data_byte))
    else:
        print(
            "FAIL: expected addr 0x%02x data 0x%02x — check P34↔GP11 SDA, "
            "P31↔GP10 SCL, GND, pull-ups; re-cp host after framing fix"
            % (addr_byte, data_byte)
        )
        if target._starts == 0 and target._scl_edges == 0:
            print(
                "hint: no START/SCL IRQs — wiring or PE sideset; green LED on P34 "
                "should flicker if SDA OE drives low"
            )
        elif got_addr == data_byte and not got_data:
            print(
                "hint: data byte seen as addr — mid-frame START reset (old host); "
                "re-cp listen-only framing fix"
            )
    st_after = host.read_reg(REG_STATUS)
    pc = host.read_reg(REG_PC)
    lv = host.read_reg(REG_LEVELS)
    print("STATUS after: 0x%02x  PC=0x%02x  LEVELS=0x%02x (expect ~0xF0/0xF1, PC~0)" % (
        st_after, pc, lv))
    # Leave SDA/SCL released for the next run's idle check
    host.release_pe_oe(0, set_base=min(sda_pin, scl_pin), set_count=2)
    return host


# Auto-run when loaded as main on the Pico
if __name__ == "__main__":
    smoke_uart_tx()
