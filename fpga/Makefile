# Build/test flow for the LoRa/FPGA vehicle control fork's RTL.
# Toolchain: yosys (synth) -> nextpnr-ice40 (place & route) -> icepack
# (bitstream). All three plus iverilog were confirmed installable and
# working in this project's dev environment; iceprog/openFPGALoader
# (flashing) could NOT be exercised here (no real hardware attached) --
# see fpga/README.md's "what's verified vs. not" section before trusting
# anything past `stat`.
#
# Usage:
#   make sim            # run every testbench, report pass/fail
#   make stat-vehicle    # yosys synth + LUT utilization report (no PnR,
#                          no .pcf needed -- this is how the 91% LUT
#                          finding in fpga/README.md was produced)
#   make stat-base
#   make vehicle.bin     # full synth -> PnR -> bitstream (needs a real
#                          .pcf -- see constraints/*.pcf's placeholder warning)
#   make base.bin
#   make flash-vehicle    # icepack .bin -> iceprog (UNVERIFIED, no hardware here)
#   make clean

YOSYS      := yosys
NEXTPNR    := nextpnr-ice40
ICEPACK    := icepack
ICEPROG    := iceprog
IVERILOG   := iverilog -g2012

COMMON_RTL := common/rtl
VEHICLE_RTL := vehicle/rtl
BASE_RTL   := base/rtl

.PHONY: sim stat-vehicle stat-base vehicle.bin base.bin flash-vehicle flash-base clean

sim:
	@set -e; \
	for tb in common/sim/tb_*.v vehicle/sim/tb_*.v base/sim/tb_*.v; do \
		echo "=== $$tb ==="; \
		out=$$(mktemp); \
		$(IVERILOG) -I $(COMMON_RTL) -I $(VEHICLE_RTL) -I $(BASE_RTL) \
			-I common/sim -I vehicle/sim -I base/sim \
			-o "$$out" "$$tb"; \
		vvp "$$out"; \
		rm -f "$$out"; \
	done

stat-vehicle:
	@echo "read_verilog -I $(COMMON_RTL) -I $(VEHICLE_RTL) $(VEHICLE_RTL)/top_vehicle.v" > /tmp/stat_vehicle.ys
	@echo "hierarchy -check -top top_vehicle" >> /tmp/stat_vehicle.ys
	@echo "synth_ice40 -top top_vehicle" >> /tmp/stat_vehicle.ys
	@echo "stat" >> /tmp/stat_vehicle.ys
	$(YOSYS) -s /tmp/stat_vehicle.ys

stat-base:
	@echo "read_verilog -I $(COMMON_RTL) -I $(BASE_RTL) $(BASE_RTL)/top_base.v" > /tmp/stat_base.ys
	@echo "hierarchy -check -top top_base" >> /tmp/stat_base.ys
	@echo "synth_ice40 -top top_base" >> /tmp/stat_base.ys
	@echo "stat" >> /tmp/stat_base.ys
	$(YOSYS) -s /tmp/stat_base.ys

vehicle.json: $(VEHICLE_RTL)/*.v $(COMMON_RTL)/*.v
	$(YOSYS) -p "read_verilog -I $(COMMON_RTL) -I $(VEHICLE_RTL) $(VEHICLE_RTL)/top_vehicle.v; synth_ice40 -top top_vehicle -json vehicle.json"

vehicle.asc: vehicle.json vehicle/constraints/alchitry_cu_v2_vehicle.pcf
	$(NEXTPNR) --hx8k --package cb132 --json vehicle.json --pcf vehicle/constraints/alchitry_cu_v2_vehicle.pcf --asc vehicle.asc

vehicle.bin: vehicle.asc
	$(ICEPACK) vehicle.asc vehicle.bin

base.json: $(BASE_RTL)/*.v $(COMMON_RTL)/*.v
	$(YOSYS) -p "read_verilog -I $(COMMON_RTL) -I $(BASE_RTL) $(BASE_RTL)/top_base.v; synth_ice40 -top top_base -json base.json"

base.asc: base.json base/constraints/alchitry_cu_v2_base.pcf
	$(NEXTPNR) --hx8k --package cb132 --json base.json --pcf base/constraints/alchitry_cu_v2_base.pcf --asc base.asc

base.bin: base.asc
	$(ICEPACK) base.asc base.bin

flash-vehicle: vehicle.bin
	$(ICEPROG) vehicle.bin

flash-base: base.bin
	$(ICEPROG) base.bin

clean:
	rm -f vehicle.json vehicle.asc vehicle.bin base.json base.asc base.bin
	find . -name '*.out' -delete
