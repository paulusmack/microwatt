#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "console.h"

extern unsigned long callit(unsigned long arg1, unsigned long arg2,
			    unsigned long (*fn)(unsigned long, unsigned long));

#define asm	__asm__ volatile

#define MSR_SF	(1ul << 63)
#define MSR_VEC (1ul << 25)
#define MSR_VSX	(1ul << 23)
#define MSR_LE	1

void disable_vec(void)
{
	unsigned long msr;

	asm("mfmsr %0" : "=r" (msr));
	msr &= ~MSR_VEC;
	asm("mtmsrd %0" : : "r" (msr));
}

void enable_vec(void)
{
	unsigned long msr;

	asm("mfmsr %0" : "=r" (msr));
	msr |= MSR_VEC;
	asm("mtmsrd %0" : : "r" (msr));
}

#define DSISR	18
#define DAR	19
#define SRR0	26
#define SRR1	27
#define PID	48
#define SPRG0	272
#define SPRG1	273
#define PRTBL	720

static inline unsigned long mfspr(int sprnum)
{
	long val;

	asm("mfspr %0,%1" : "=r" (val) : "i" (sprnum));
	return val;
}

static inline void mtspr(int sprnum, unsigned long val)
{
	asm("mtspr %0,%1" : : "i" (sprnum), "r" (val));
}

void print_string(const char *str)
{
	for (; *str; ++str)
		putchar(*str);
}

void print_hex(unsigned long val, int ndigits)
{
	int i, x;

	for (i = (ndigits - 1) * 4; i >= 0; i -= 4) {
		x = (val >> i) & 0xf;
		if (x >= 10)
			putchar(x + 'a' - 10);
		else
			putchar(x + '0');
	}
}

// i < 100
void print_test_number(int i)
{
	print_string("test ");
	putchar(48 + i/10);
	putchar(48 + i%10);
	putchar(':');
}

#define DO_LSTVX(instr, vr, addr)	asm(instr " %%v%0,0,%1" : : "i" (vr), "r" (addr) : "memory")

unsigned char lvx_result[16] __attribute__((__aligned__(16)));

unsigned long do_lvx(unsigned long size, unsigned long addr)
{
	switch (size) {
	case 1:
		DO_LSTVX("lvebx", 23, addr);
		DO_LSTVX("stvx", 23, &lvx_result);
		break;
	case 2:
		DO_LSTVX("lvehx", 24, addr);
		DO_LSTVX("stvx", 24, &lvx_result);
		break;
	case 4:
		DO_LSTVX("lvewx", 15, addr);
		DO_LSTVX("stvx", 15, &lvx_result);
		break;
	default:
		DO_LSTVX("lvx", 0, addr);
		DO_LSTVX("stvx", 0, &lvx_result);
		break;
	}
	return 0;
}

unsigned long do_stvx(unsigned long size, unsigned long addr)
{
	switch (size) {
	case 1:
		DO_LSTVX("lvx", 23, &lvx_result);
		DO_LSTVX("stvebx", 23, addr);
		break;
	case 2:
		DO_LSTVX("lvx", 24, &lvx_result);
		DO_LSTVX("stvehx", 24, addr);
		break;
	case 4:
		DO_LSTVX("lvx", 15, &lvx_result);
		DO_LSTVX("stvewx", 15, addr);
		break;
	default:
		DO_LSTVX("lvx", 0, &lvx_result);
		DO_LSTVX("stvx", 0, addr);
		break;
	}
	return 0;
}

int sizes[4] = { 1, 2, 4, 16 };

int vector_test_1(void)
{
	int n;
	unsigned long ret;
	unsigned char x[16] __attribute__((__aligned__(16)));

	/* check that we get vector unavailable interrupts iff MSR[VEC] = 0 */
	for (n = 0; n < 4; ++n) {
		disable_vec();
		ret = callit(sizes[n], (unsigned long)&x, do_lvx);
		if (ret != 0xf20)
			return n;
		ret = callit(sizes[n], (unsigned long)&x, do_stvx);
		if (ret != 0xf20)
			return n + 0x1000;
		enable_vec();
		ret = callit(sizes[n], (unsigned long)&x, do_lvx);
		if (ret) {
			unsigned long msr;
			asm("mfmsr %0" : "=r" (msr));
			print_hex(msr, 16);
			return ret + n + 0x2000;
		}
		ret = callit(sizes[n], (unsigned long)&x, do_stvx);
		if (ret)
			return ret + n + 0x3000;
	}
	disable_vec();
	return 0;
}

unsigned long offsets[5] = { 0, 1, 2, 11, 15 };

int vector_test_2(void)
{
	int m, n, i, j;
	unsigned char v, v0;
	unsigned long offset, size, ret;
	unsigned char x[32] __attribute__((__aligned__(16)));

	enable_vec();
	v = 0;
	for (n = 0; n < 4; ++n) {
		size = sizes[n];
		for (m = 0; m < 5; ++m) {
			offset = offsets[m];
			for (i = 0; i < 32; ++i)
				x[i] = (v += 19);
			v++;
			for (i = 0; i < 16; ++i)
				lvx_result[i] = (v += 19);
			v++;
			ret = callit(size, (unsigned long)&x + offset, do_lvx);
			if (ret)
				return ret + 0x1000;
			j = offset & -size;
			for (i = 0; i < size; ++i)
				if (lvx_result[i + j] != x[i + j])
					return 1;
			v0 = v;
			for (i = 0; i < 32; ++i)
				x[i] = (v += 19);
			v++;
			for (i = 0; i < 16; ++i)
				lvx_result[i] = (v += 19);
			v++;
			ret = callit(size, (unsigned long)&x + offset, do_stvx);
			if (ret)
				return ret + 0x2000;
			j = offset & -size;
			for (i = 0; i < 32; ++i) {
				v0 += 19;
				if (i >= j && i < j + size) {
					if (x[i] != lvx_result[i])
						return 2;
				} else {
					if (x[i] != v0)
						return 3;
				}
			}
		}
	}
	disable_vec();
	return 0;
}

int fail = 0;

void do_test(int num, int (*test)(void))
{
	int ret;

	print_test_number(num);
	ret = test();
	if (ret == 0) {
		print_string("PASS\r\n");
	} else {
		fail = 1;
		print_string("FAIL ");
		print_hex(ret, 4);
		print_string("\r\n");
	}
}

int main(void)
{
	console_init();

	do_test(1, vector_test_1);
	do_test(2, vector_test_2);

	return fail;
}
