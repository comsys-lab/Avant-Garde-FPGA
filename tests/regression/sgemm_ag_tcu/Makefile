ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := sgemm_ag_tcu

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

# AG-TCU requires TCU + AG-TCU extensions, INT8 input, INT32 output
CONFIGS += -DEXT_TCU_ENABLE -DEXT_AG_TCU_ENABLE
CONFIGS += -DITYPE=int8 -DOTYPE=int32

SRCS := $(SRC_DIR)/main.cpp

VX_SRCS := $(SRC_DIR)/kernel.cpp

# Default: 32x32x32 matrix, neutral E8M0 scale (exp=0, same as plain INT8 matmul)
OPTS ?= -m32 -n32 -k32

include ../common.mk

# simx-rebuild: rebuild libsimx.so with AG-TCU support (run once before run-simx)
simx-rebuild:
	$(MAKE) -C $(ROOT_DIR)/runtime simx CONFIGS="-DEXT_TCU_ENABLE -DEXT_AG_TCU_ENABLE"
