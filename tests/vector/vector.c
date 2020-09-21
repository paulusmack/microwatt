#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "console.h"
#include "lfsr.h"

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

void print_buf(unsigned char *buf, unsigned long len, const char *what)
{
	unsigned long i;

	print_string(what);
	print_string(" =");
	for (i = 0; i < len; ++i) {
		print_string(" ");
		print_hex(buf[i], 2);
	}
	print_string("\r\n");
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

unsigned char a[16] __attribute__((__aligned__(16)));
unsigned char b[16] __attribute__((__aligned__(16)));
unsigned char c[16] __attribute__((__aligned__(16)));
unsigned char result[16] __attribute__((__aligned__(16)));

unsigned long do_vperm(unsigned long x, unsigned long y)
{
	switch (x) {
	case 0:
		asm("vperm 1,2,3,4");
		break;
	case 1:
		asm("lvx 0,0,%0; lvx 1,0,%1; lvx 2,0,%2; vperm 3,0,1,2; stvx 3,0,%3" : :
		    "r" (a), "r" (b), "r" (c), "r" (result) : "memory");
		break;
	case 2:
		asm("lvx 0,0,%0; lvx 1,0,%1; lvx 2,0,%2; vpermr 3,0,1,2; stvx 3,0,%3" : :
		    "r" (a), "r" (b), "r" (c), "r" (result) : "memory");
		break;
	case 3:
		asm("lvx 0,0,%0; lvx 1,0,%1; vpkuhum 3,0,1; stvx 3,0,%2" : :
		    "r" (a), "r" (b), "r" (result) : "memory");
		break;
	case 4:
		asm("lvx 0,0,%0; lvx 1,0,%1; vpkuwum 3,0,1; stvx 3,0,%2" : :
		    "r" (a), "r" (b), "r" (result) : "memory");
		break;
	case 5:
		asm("lvx 0,0,%0; lvx 1,0,%1; vpkudum 3,0,1; stvx 3,0,%2" : :
		    "r" (a), "r" (b), "r" (result) : "memory");
		break;
	default:
		return 0xff000 | x;
	}
	return 0;
}

/* test vperm, vpermr, vpku*um */
int vector_test_3(void)
{
	unsigned long ret, i, j, v;
	unsigned long lfsr = 1;

	for (i = 0; i < 16; ++i) {
		a[i] = 0xa0 + i;
		b[i] = 0xb0 + i;
	}
	disable_vec();
	ret = callit(0, 0, do_vperm);
	if (ret != 0xf20)
		return ret | 0x1000;
	enable_vec();
	for (j = 0; j < 10; ++j) {
		for (i = 0; i < 16; ++i) {
			lfsr = mylfsr(32, lfsr);
			c[i] = lfsr & 0x1f;
		}
		ret = callit(1, 0, do_vperm);
		if (ret)
			return ret | 0x2000;
		for (i = 0; i < 16; ++i) {
			if (c[i] & 0x10)
				v = b[~c[i] & 0xf];
			else
				v = a[~c[i] & 0xf];
			if (result[i] != v)
				return 0x100 | (j << 4) | i;
		}
		ret = callit(2, 0, do_vperm);
		if (ret)
			return ret | 0x3000;
		for (i = 0; i < 16; ++i) {
			if (c[i] & 0x10)
				v = a[c[i] & 0xf];
			else
				v = b[c[i] & 0xf];
			if (result[i] != v)
				return 0x200 | (j << 4) | i;
		}
	}
	ret = callit(3, 0, do_vperm);
	if (ret)
		return ret | 0x4000;
	for (i = 0; i < 8; ++i)
		if (result[i] != 0xb0 + (i * 2))
			return 1;
	for (; i < 16; ++i)
		if (result[i] != 0xa0 + ((i - 8) * 2))
			return 2;
	ret = callit(4, 0, do_vperm);
	if (ret)
		return ret | 0x5000;
	for (i = 0; i < 8; i += 2)
		if (result[i] != 0xb0 + (i * 2) || result[i+1] != 0xb0 + (i * 2) + 1)
			return 3;
	for (; i < 16; i += 2)
		if (result[i] != 0xa0 + ((i - 8) * 2) ||
		    result[i+1] != 0xa0 + ((i - 8) * 2) + 1)
			return 4;
	ret = callit(5, 0, do_vperm);
	if (ret)
		return ret | 0x6000;
	for (i = 0; i < 8; i += 4)
		if (result[i] != 0xb0 + (i * 2) ||
		    result[i+1] != 0xb0 + (i * 2) + 1 ||
		    result[i+2] != 0xb0 + (i * 2) + 2 ||
		    result[i+3] != 0xb0 + (i * 2) + 3)
			return 5;
	for (; i < 16; i += 4)
		if (result[i] != 0xa0 + ((i - 8) * 2) ||
		    result[i+1] != 0xa0 + ((i - 8) * 2) + 1 ||
		    result[i+2] != 0xa0 + ((i - 8) * 2) + 2 ||
		    result[i+3] != 0xa0 + ((i - 8) * 2) + 3)
			return 6;
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
	do_test(3, vector_test_3);

	return fail;
}
