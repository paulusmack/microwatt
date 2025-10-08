CROSS_COMPILE ?= powerpc64le-linux-gnu-

CC = $(CROSS_COMPILE)gcc
LD = $(CROSS_COMPILE)ld
OC = $(CROSS_COMPILE)objcopy

LDFLAGS = -T powerpc.lds

all: emulation.bin emulation.hex

emulation.o: emulation.S

emulation.elf: emulation.o
	$(LD) $(LDFLAGS) -o emulation.elf emulation.o

emulation.bin: emulation.elf
	$(OC) -O binary emulation.elf emulation.bin

emulation.hex: emulation.bin
	../scripts/bin2hex.py emulation.bin >emulation.hex

clean:
	rm emulation.o emulation.elf emulation.bin emulation.hex

install: all
	cp emulation.bin ..
	cp emulation.hex ../fpga
