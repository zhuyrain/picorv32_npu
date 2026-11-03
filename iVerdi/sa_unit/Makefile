# Standalone Q1 SA verification. Does not compile the legacy SoC wrapper.
THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(THIS_DIR)/../..)
BUILD := $(THIS_DIR)/build
TOP ?= tb_sa
SEED ?= 1
SEEDS ?= 1 7 42
RUN_DIR := $(BUILD)/$(TOP)$(if $(filter 1,$(COV)),_cov)$(if $(filter 1,$(FSDB)),_fsdb)
VCS ?= $(if $(VCS_HOME),$(VCS_HOME)/bin/vcs,vcs)
VERDI ?= $(if $(VERDI_HOME),$(VERDI_HOME)/bin/verdi,verdi)
RTL := $(ROOT)/npu_rtl/pe.v $(ROOT)/npu_rtl/sa.v
TB := $(if $(filter tb_sa_shapes,$(TOP)),,$(THIS_DIR)/sa_test_driver.sv) \
      $(THIS_DIR)/$(TOP).sv
VCS_FLAGS := -full64 -sverilog -timescale=1ns/1ps +define+SA_CHECKS \
             -debug_access+all -kdb -lca +lint=all -j4
ifeq ($(COV),1)
VCS_FLAGS += -cm line+cond+branch+tgl
SIM_COV = -cm line+cond+branch+tgl -cm_name seed$(SEED)
endif
ifeq ($(FSDB),1)
VCS_FLAGS += +define+SA_FSDB
endif

.PHONY: all vectors compile sim test regress wave
all: test
vectors:
	python3 $(THIS_DIR)/gen_vectors.py
compile:
	@mkdir -p $(RUN_DIR)
	cd $(RUN_DIR) && $(VCS) $(VCS_FLAGS) -top $(TOP) \
	    +incdir+$(THIS_DIR) $(RTL) $(TB) -Mdir=csrc -o simv -l compile.log
sim: vectors
	cd $(RUN_DIR) && ./simv -no_save +ntb_random_seed=$(SEED) \
	    +HEX_DIR=$(BUILD)/hex $(SIM_COV) -l sim_seed$(SEED).log
# VCS $fatal exits nonzero; the testbench also has a watchdog.
# Recursive sim avoids a compile/sim race even with make -j.
test: compile
	$(MAKE) -C $(THIS_DIR) sim TOP=$(TOP) SEED=$(SEED)
regress:
	@set -e; for top in tb_sa tb_sa_protocol tb_sa_shapes; do \
	    $(MAKE) -C $(THIS_DIR) compile TOP=$$top; \
	    for seed in $(SEEDS); do \
	        $(MAKE) -C $(THIS_DIR) sim TOP=$$top SEED=$$seed; \
	    done; \
	done
wave:
	cd $(RUN_DIR) && $(VERDI) -dbdir simv.daidir -ssf sa.fsdb
