# SPL-G1 EDA工具链 Makefile
# 用法: make <target>

PYTHON ?= python
IVERILOG ?= iverilog
VVP ?= vvp
GTKWAVE ?= gtkwave

# 默认目标
.PHONY: all
all: help

# 帮助信息
.PHONY: help
help:
	@echo "SPL-G1 EDA工具链可用命令:"
	@echo "  make demo-causal       # 运行因果链演示用例"
	@echo "  make demo-audit        # 运行认知审计用例(低功耗优化)"
	@echo "  make demo-optical      # 运行光子工艺演示用例"
	@echo "  make demo-full         # 运行完整流水线(含COMPUTE算子 + params消费)"
	@echo "  make build DESC=<json> # 编译指定因果设计"
	@echo "  make sim               # 运行RTL仿真并生成波形"
	@echo "  make wave              # 打开波形查看器"
	@echo "  make clean             # 清理输出文件和临时文件"
	@echo ""
	@echo "示例: make build DESC=examples/causal_chain_demo.json STRATEGY=min_delay"

# 运行因果链演示
.PHONY: demo-causal
demo-causal:
	$(PYTHON) eda_cli.py --desc examples/causal_chain_demo.json \
		--pdk pdk/silicon_cim_v1.json \
		--strategy min_delay \
		--output outputs/netlist_demo.json

# 运行认知审计演示
.PHONY: demo-audit
demo-audit:
	$(PYTHON) eda_cli.py --desc examples/cognitive_audit_demo.json \
		--pdk pdk/silicon_cim_v1.json \
		--strategy min_power \
		--output outputs/netlist_cognitive_silicon.json

# 运行光子工艺演示
.PHONY: demo-optical
demo-optical:
	$(PYTHON) eda_cli.py --desc examples/causal_chain_demo.json \
		--pdk pdk/optical_mzi_photonics_v1.json \
		--strategy min_power \
		--output outputs/netlist_optical.json

# 运行完整流水线演示 (含 COMPUTE 算子 + params 消费)
.PHONY: demo-full
demo-full:
	$(PYTHON) eda_cli.py --desc examples/full_pipeline_demo.json \
		--pdk pdk/silicon_cim_v1.json \
		--strategy min_power \
		--output outputs/netlist_full_pipeline.json

# 编译自定义设计
# 用法: make build DESC=<desc.json> [PDK=<pdk.json>] [STRATEGY=<strategy>] [OUTPUT=<output.json>]
PDK ?= pdk/silicon_cim_v1.json
STRATEGY ?= min_delay
OUTPUT ?= outputs/netlist.json
.PHONY: build
build:
	@if [ -z "$(DESC)" ]; then \
		echo "错误: 请指定DESC参数，例如: make build DESC=examples/causal_chain_demo.json"; \
		exit 1; \
	fi
	$(PYTHON) eda_cli.py --desc $(DESC) \
		--pdk $(PDK) \
		--strategy $(STRATEGY) \
		--output $(OUTPUT)

# RTL仿真
SIM_BIN = g1_sim
WAVE_FILE = g1_integrated_wave.vcd
.PHONY: sim
sim:
	$(IVERILOG) -g2012 -o $(SIM_BIN) rtl/G1_Top_Integrated.sv rtl/ra_bus_arbiter.sv rtl/spl_pim_sequencer.sv rtl/spl_pim_cell.sv rtl/spl_pim_compute_array.sv rtl/spl_cim_causal_unit.sv rtl/ext_mem_controller.sv rtl/materica_compliance_unit.sv rtl/tb_G1_Integrated.sv
	$(VVP) $(SIM_BIN)
	@echo "仿真完成，波形文件: $(WAVE_FILE)"

# 打开波形
.PHONY: wave
wave:
	@if [ ! -f $(WAVE_FILE) ]; then \
		echo "波形文件不存在，请先运行 make sim"; \
		exit 1; \
	fi
	$(GTKWAVE) $(WAVE_FILE)

# 清理
.PHONY: clean
clean:
	rm -f $(SIM_BIN) $(WAVE_FILE)
	rm -f outputs/*.json
	@echo "清理完成"
