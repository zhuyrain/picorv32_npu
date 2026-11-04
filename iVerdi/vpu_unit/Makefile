# Independent VPU validation; never changes the legacy PPU or SA RTL.
THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(THIS_DIR)/../..)
BUILD := $(THIS_DIR)/build
TOP ?= tb_vpu
SEED ?= 1
SEEDS ?= 1 7 42
RUN_DIR := $(BUILD)/$(TOP)$(if $(filter 1,$(COV)),_cov)$(if $(filter 1,$(FSDB)),_fsdb)
VCS ?= $(if $(VCS_HOME),$(VCS_HOME)/bin/vcs,vcs)
VERDI ?= $(if $(VERDI_HOME),$(VERDI_HOME)/bin/verdi,verdi)
RTL := $(ROOT)/npu_rtl/npu_vpu.v $(ROOT)/npu_rtl/sa_result_fifo.v
TB := $(THIS_DIR)/vpu_test_driver.sv $(THIS_DIR)/$(TOP).sv
VCS_FLAGS := -full64 -sverilog -timescale=1ns/1ps +define+VPU_CHECKS+SA_CHECKS \
             -debug_access+all -kdb -lca +lint=all -j4
ifeq ($(FSDB),1)
VCS_FLAGS += +define+VPU_FSDB
endif
ifeq ($(COV),1)
VCS_FLAGS += -cm line+cond+branch+tgl
endif
.PHONY: all vectors generate compile sim test regress wave
all: test
# Vectors are persistent deliverables, intentionally OUTSIDE ignored build/.
vectors:
	python3 $(THIS_DIR)/gen_vectors.py --check
generate:
	python3 $(THIS_DIR)/gen_vectors.py
compile:
	@mkdir -p $(RUN_DIR)
	cd $(RUN_DIR) && $(VCS) $(VCS_FLAGS) +incdir+$(THIS_DIR) -top $(TOP) \
	    $(RTL) $(TB) -Mdir=csrc -o simv -l compile.log
sim: vectors
	cd $(RUN_DIR) && python3 $(THIS_DIR)/run_sim.py --top $(TOP) --seed $(SEED) \
	    --vectors $(THIS_DIR)/vectors $(if $(filter 1,$(COV)),--coverage,)
test: compile
	$(MAKE) -C $(THIS_DIR) sim TOP=$(TOP) SEED=$(SEED)
regress:
	@set -e; for top in tb_vpu tb_vpu_params tb_vpu_fifo; do \
	    $(MAKE) -C $(THIS_DIR) compile TOP=$$top; \
	    for seed in $(SEEDS); do \
	        $(MAKE) -C $(THIS_DIR) sim TOP=$$top SEED=$$seed; \
	    done; \
	done
wave:
	cd $(RUN_DIR) && $(VERDI) -dbdir simv.daidir -ssf vpu.fsdb
