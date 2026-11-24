# ProtoCore16 → Muse Lab iCESugar (iCE40UP5K-SG48)
# Requires: yosys, nextpnr-ice40, icepack  (optional: iceprog / icesprog)

PROJ     := protocore16_icesugar
TOP      := icesugar_protocore16_top
PCF      := icesugar.pcf
BUILD    := build

RTL_DIR  := ../src
# 1-PE FPGA cut (tt_um_protocore16_fpga1.v). Full 4-PE ASIC top does not fit UP5K.
RTL      := \
	$(RTL_DIR)/fifo4x8.v \
	$(RTL_DIR)/crc_unit.v \
	$(RTL_DIR)/nrzi_unit.v \
	$(RTL_DIR)/pe_engine.v \
	$(RTL_DIR)/host_if.v \
	tt_um_protocore16_fpga1.v \
	icesugar_protocore16_top.v

YOSYS    ?= yosys
NEXTPNR  ?= nextpnr-ice40
ICEPACK  ?= icepack
ICEPROG  ?= iceprog

.PHONY: all synth pnr pack prog clean dirs

all: $(BUILD)/$(PROJ).bin

dirs:
	@mkdir -p $(BUILD)

synth: $(BUILD)/$(PROJ).json

$(BUILD)/$(PROJ).json: $(RTL) | dirs
	$(YOSYS) -ql $(BUILD)/yosys.log -p \
		"read_verilog -sv $(RTL); synth_ice40 -top $(TOP) -json $@"

pnr: $(BUILD)/$(PROJ).asc

$(BUILD)/$(PROJ).asc: $(BUILD)/$(PROJ).json $(PCF) | dirs
	$(NEXTPNR) --up5k --package sg48 \
		--json $(BUILD)/$(PROJ).json \
		--pcf $(PCF) \
		--asc $@ \
		--freq 12 \
		-l $(BUILD)/nextpnr.log

pack: $(BUILD)/$(PROJ).bin

$(BUILD)/$(PROJ).bin: $(BUILD)/$(PROJ).asc | dirs
	$(ICEPACK) $< $@

# Prefer iceprog if present; otherwise copy .bin to iCELink USB mass storage.
prog: $(BUILD)/$(PROJ).bin
	@if command -v $(ICEPROG) >/dev/null 2>&1; then \
		$(ICEPROG) $(BUILD)/$(PROJ).bin; \
	elif command -v icesprog >/dev/null 2>&1; then \
		icesprog $(BUILD)/$(PROJ).bin; \
	else \
		echo "No iceprog/icesprog in PATH."; \
		echo "Drag $(BUILD)/$(PROJ).bin onto the iCELink USB drive, or:"; \
		echo "  cp $(BUILD)/$(PROJ).bin /media/$$USER/iCELink/"; \
		exit 1; \
	fi

clean:
	rm -rf $(BUILD)
