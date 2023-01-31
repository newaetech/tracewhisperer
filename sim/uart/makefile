LOGFILE=make.log
EXEFILE=a.out
WAVEFORMAT=fst
SEED=1
TIMEOUT_CYCLES=50000
DUMP=0
COCOTB_LOG_LEVEL=INFO
VIVADO_VERSION=2020.2
PERIOD=100
BAUD=115200
DATA_BITS=8
STOP_BITS=1
PARITY_BIT=1
PARITY_ENABLED=0
PARITY_IGNORED=0
REPS=10

all: compile run

ifeq ($(VIVADO_PATH),)
  ifeq ($(OS), Windows_NT)
    VIVADO_PATH=/mnt/c/Xilinx/Vivado/
  else
    UNAME_S := $(shell uname -s)
    ifeq ($(UNAME_S),Linux)
      VIVADO_PATH=/tools/Xilinx/Vivado/
    endif
    ifeq ($(UNAME_S),Darwin)
      VIVADO_PATH=$(HOME)/tools/Xilinx/Vivado/
    endif
  endif
endif

compile:
	iverilog -g2005-sv \
	-gsupported-assertions \
	-y/$(VIVADO_PATH)/$(VIVADO_VERSION)/ids_lite/ISE/verilog/src/unisims/ \
	-s uart_cocowrapper \
	-s glbl \
	-Wportbind \
	-Wselect-range \
	-DCOCOTB_SIM=1 \
	-P uart_cocowrapper.pDUMP=$(DUMP) \
	-o $(EXEFILE) \
	../../hdl/uart_core.v \
	$(VIVADO_PATH)/$(VIVADO_VERSION)/ids_lite/ISE/verilog/src/glbl.v \
	uart_cocowrapper.v \

lint:
	verilator --lint-only -Wall \
	--error-limit 0 \
	-Wno-PINCONNECTEMPTY \
	-Wno-MULTITOP \
	../../hdl/uart_core.v \
	-D__ICARUS__ \
	2>&1 | tee lint.out \

# note that -M and -m arguments must immediately follow vvp, otherwise Python doesn't start!
run:
	COCOTB_RESOLVE_X=RANDOM \
	TOPLEVEL=uart_cocowrapper \
	TOPLEVEL_LANG=verilog \
        PERIOD=$(PERIOD) \
        BAUD=$(BAUD) \
        STOP_BITS=$(STOP_BITS) \
        DATA_BITS=$(DATA_BITS) \
        PARITY_BIT=$(PARITY_BIT) \
        PARITY_ENABLED=$(PARITY_ENABLED) \
        PARITY_IGNORED=$(PARITY_IGNORED) \
        REPS=$(REPS) \
	MODULE=test_uart \
	COCOTB_LOG_LEVEL=$(COCOTB_LOG_LEVEL) \
	LIBPYTHON_LOC=$(shell cocotb-config --libpython) \
	vvp -M $(shell cocotb-config --lib-dir) \
	-m $(shell cocotb-config --lib-name vpi icarus) \
	-l$(LOGFILE) $(EXEFILE) -$(WAVEFORMAT) \

clean:
	rm -f a.out results/*.vvp
