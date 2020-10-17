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

unsigned char d1[16] __attribute__((__aligned__(16))) =
	{ 0x01, 0x80, 0x10, 0x60, 0x11, 0x12, 0xff, 0xff, 0x19, 0xaa, 0x69, 0x1a, 0xfa, 0xfa, 0xee, 0xed };
unsigned char d2[16] __attribute__((__aligned__(16))) =
	{ 0xe7, 0x80, 0x10, 0xd0, 0x11, 0x99, 0x00, 0xff, 0x26, 0x25, 0x24, 0xbb, 0x77, 0x66, 0x55, 0x44 };

unsigned long test4(unsigned long size, unsigned long t)
{
	switch (size) {
	case 0x1:
		asm("lvx 5,0,%1; lvx 6,0,%2; vmaxsb 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x2:
		asm("lvx 5,0,%1; lvx 6,0,%2; vmaxsh 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x4:
		asm("lvx 5,0,%1; lvx 6,0,%2; vmaxsw 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x8:
		asm("lvx 5,0,%1; lvx 6,0,%2; vmaxsd 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x11:
		asm("lvx 5,0,%1; lvx 6,0,%2; vmaxub 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x12:
		asm("lvx 5,0,%1; lvx 6,0,%2; vmaxuh 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x14:
		asm("lvx 5,0,%1; lvx 6,0,%2; vmaxuw 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x18:
		asm("lvx 5,0,%1; lvx 6,0,%2; vmaxud 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x21:
		asm("lvx 5,0,%1; lvx 6,0,%2; vminsb 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x22:
		asm("lvx 5,0,%1; lvx 6,0,%2; vminsh 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x24:
		asm("lvx 5,0,%1; lvx 6,0,%2; vminsw 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x28:
		asm("lvx 5,0,%1; lvx 6,0,%2; vminsd 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x31:
		asm("lvx 5,0,%1; lvx 6,0,%2; vminub 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x32:
		asm("lvx 5,0,%1; lvx 6,0,%2; vminuh 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x34:
		asm("lvx 5,0,%1; lvx 6,0,%2; vminuw 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	case 0x38:
		asm("lvx 5,0,%1; lvx 6,0,%2; vminud 7,5,6; stvx 7,0,%0" : :
		    "r" (result), "r" (d1), "r" (d2) : "memory");
		break;
	default:
		return size | 0xff000;
	}
	return 0;
}

#define max(a, b)	(a > b? a : b)
#define min(a, b)	(a < b? a : b)

int vector_test_4(void)
{
	unsigned long ret, i;
	signed long v;
	union u {
		signed char sb[16];
		signed short sh[8];
		signed int sw[4];
		signed long sd[2];
		unsigned char ub[16];
		unsigned short uh[8];
		unsigned int uw[4];
		unsigned long ud[2];
	} *a, *b, *r;

	a = (union u *)d1;
	b = (union u *)d2;
	r = (union u *)result;

	enable_vec();

	ret = callit(1, 0, test4);
	if (ret)
		return ret | 0x1000;
	for (i = 0; i < 16; ++i) {
		v = max(a->sb[i], b->sb[i]);
		if (v != r->sb[i])
			return 1;
	}
	ret = callit(2, 0, test4);
	if (ret)
		return ret | 0x2000;
	for (i = 0; i < 8; ++i) {
		v = max(a->sh[i], b->sh[i]);
		if (v != r->sh[i])
			return 2;
	}
	ret = callit(4, 0, test4);
	if (ret)
		return ret | 0x3000;
	for (i = 0; i < 4; ++i) {
		v = max(a->sw[i], b->sw[i]);
		if (v != r->sw[i])
			return 3;
	}
	ret = callit(8, 0, test4);
	if (ret)
		return ret | 0x4000;
	for (i = 0; i < 2; ++i) {
		v = max(a->sd[i], b->sd[i]);
		if (v != r->sd[i])
			return 4;
	}
	ret = callit(0x11, 0, test4);
	if (ret)
		return ret | 0x5000;
	for (i = 0; i < 16; ++i) {
		v = max(a->ub[i], b->ub[i]);
		if (v != r->ub[i])
			return 5;
	}
	ret = callit(0x12, 0, test4);
	if (ret)
		return ret | 0x6000;
	for (i = 0; i < 8; ++i) {
		v = max(a->uh[i], b->uh[i]);
		if (v != r->uh[i])
			return 6;
	}
	ret = callit(0x14, 0, test4);
	if (ret)
		return ret | 0x7000;
	for (i = 0; i < 4; ++i) {
		v = max(a->uw[i], b->uw[i]);
		if (v != r->uw[i])
			return 7;
	}
	ret = callit(0x18, 0, test4);
	if (ret)
		return ret | 0x8000;
	for (i = 0; i < 2; ++i) {
		v = max(a->ud[i], b->ud[i]);
		if (v != r->ud[i])
			return 8;
	}
	ret = callit(0x21, 0, test4);
	if (ret)
		return ret | 0x9000;
	for (i = 0; i < 16; ++i) {
		v = min(a->sb[i], b->sb[i]);
		if (v != r->sb[i])
			return 9;
	}
	ret = callit(0x22, 0, test4);
	if (ret)
		return ret | 0xa000;
	for (i = 0; i < 8; ++i) {
		v = min(a->sh[i], b->sh[i]);
		if (v != r->sh[i])
			return 10;
	}
	ret = callit(0x24, 0, test4);
	if (ret)
		return ret | 0xb000;
	for (i = 0; i < 4; ++i) {
		v = min(a->sw[i], b->sw[i]);
		if (v != r->sw[i])
			return 11;
	}
	ret = callit(0x28, 0, test4);
	if (ret)
		return ret | 0xc000;
	for (i = 0; i < 2; ++i) {
		v = min(a->sd[i], b->sd[i]);
		if (v != r->sd[i])
			return 12;
	}
	ret = callit(0x31, 0, test4);
	if (ret)
		return ret | 0xd000;
	for (i = 0; i < 16; ++i) {
		v = min(a->ub[i], b->ub[i]);
		if (v != r->ub[i])
			return 13;
	}
	ret = callit(0x32, 0, test4);
	if (ret)
		return ret | 0xe000;
	for (i = 0; i < 8; ++i) {
		v = min(a->uh[i], b->uh[i]);
		if (v != r->uh[i])
			return 14;
	}
	ret = callit(0x34, 0, test4);
	if (ret)
		return ret | 0xf000;
	for (i = 0; i < 4; ++i) {
		v = min(a->uw[i], b->uw[i]);
		if (v != r->uw[i])
			return 15;
	}
	ret = callit(0x38, 0, test4);
	if (ret)
		return ret | 0x10000;
	for (i = 0; i < 2; ++i) {
		v = min(a->ud[i], b->ud[i]);
		if (v != r->ud[i])
			return 16;
	}
	return 0;
}

unsigned char c1[16] __attribute__((__aligned__(16))) =
	{ 0x00, 0x00, 0x10, 0x60, 0x11, 0x12, 0xff, 0xff, 0x19, 0xaa, 0x69, 0x1a, 0x77, 0x66, 0x55, 0x44 };
unsigned char c2[16] __attribute__((__aligned__(16))) =
	{ 0x00, 0x00, 0x10, 0xd0, 0x11, 0x99, 0x00, 0xff, 0x26, 0x25, 0x24, 0xbb, 0x77, 0x66, 0x55, 0x44 };

unsigned long test5(unsigned long size, unsigned long t)
{
	switch (size) {
	case 0x1:
		asm("lvx 7,0,%1; lvx 4,0,%2; vcmpequb 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (c1), "r" (c2) : "memory");
		break;
	case 0x2:
		asm("lvx 7,0,%1; lvx 4,0,%2; vcmpequh 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (c1), "r" (c2) : "memory");
		break;
	case 0x4:
		asm("lvx 7,0,%1; lvx 4,0,%2; vcmpequw 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (c1), "r" (c2) : "memory");
		break;
	case 0x8:
		asm("lvx 7,0,%1; lvx 4,0,%2; vcmpequd 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (c1), "r" (c2) : "memory");
		break;
	case 0x11:
		asm("lvx 7,0,%1; lvx 4,0,%2; vcmpgtsb 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (c1), "r" (c2) : "memory");
		break;
	case 0x12:
		asm("lvx 7,0,%1; lvx 4,0,%2; vcmpgtsh 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (c1), "r" (c2) : "memory");
		break;
	case 0x14:
		asm("lvx 7,0,%1; lvx 4,0,%2; vcmpgtsw 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (c1), "r" (c2) : "memory");
		break;
	case 0x18:
		asm("lvx 7,0,%1; lvx 4,0,%2; vcmpgtsd 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (c1), "r" (c2) : "memory");
		break;
	case 0x21:
		asm("lvx 7,0,%1; lvx 4,0,%2; vcmpgtub 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (c1), "r" (c2) : "memory");
		break;
	case 0x22:
		asm("lvx 7,0,%1; lvx 4,0,%2; vcmpgtuh 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (c1), "r" (c2) : "memory");
		break;
	case 0x24:
		asm("lvx 7,0,%1; lvx 4,0,%2; vcmpgtuw 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (c1), "r" (c2) : "memory");
		break;
	case 0x28:
		asm("lvx 7,0,%1; lvx 4,0,%2; vcmpgtud 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (c1), "r" (c2) : "memory");
		break;
	default:
		return size | 0xff000;
	}
	return 0;
}

int vector_test_5(void)
{
	unsigned long ret, i;
	signed long v;
	union u {
		signed char sb[16];
		signed short sh[8];
		signed int sw[4];
		signed long sd[2];
		unsigned char ub[16];
		unsigned short uh[8];
		unsigned int uw[4];
		unsigned long ud[2];
	} *a, *b, *r;

	a = (union u *)c1;
	b = (union u *)c2;
	r = (union u *)result;

	enable_vec();

	ret = callit(1, 0, test5);
	if (ret)
		return ret | 0x1000;
	for (i = 0; i < 16; ++i) {
		v = a->ub[i] == b->ub[i]? 0xff: 0;
		if (v != r->ub[i])
			return 1;
	}
	ret = callit(2, 0, test5);
	if (ret)
		return ret | 0x2000;
	for (i = 0; i < 8; ++i) {
		v = a->uh[i] == b->uh[i]? 0xffff: 0;
		if (v != r->uh[i])
			return 2;
	}
	ret = callit(4, 0, test5);
	if (ret)
		return ret | 0x3000;
	for (i = 0; i < 4; ++i) {
		v = a->uw[i] == b->uw[i]? 0xffffffff: 0;
		if (v != r->uw[i])
			return 3;
	}
	ret = callit(8, 0, test5);
	if (ret)
		return ret | 0x4000;
	for (i = 0; i < 2; ++i) {
		v = a->ud[i] == b->ud[i]? ~0ul: 0;
		if (v != r->ud[i])
			return 4;
	}
	ret = callit(0x11, 0, test5);
	if (ret)
		return ret | 0x5000;
	for (i = 0; i < 16; ++i) {
		v = a->sb[i] > b->sb[i]? 0xff: 0;
		if (v != r->ub[i])
			return 5;
	}
	ret = callit(0x12, 0, test5);
	if (ret)
		return ret | 0x6000;
	for (i = 0; i < 8; ++i) {
		v = a->sh[i] > b->sh[i]? 0xffff: 0;
		if (v != r->uh[i])
			return 6;
	}
	ret = callit(0x14, 0, test5);
	if (ret)
		return ret | 0x7000;
	for (i = 0; i < 4; ++i) {
		v = a->sw[i] > b->sw[i]? 0xffffffff: 0;
		if (v != r->uw[i])
			return 7;
	}
	ret = callit(0x18, 0, test5);
	if (ret)
		return ret | 0x8000;
	for (i = 0; i < 2; ++i) {
		v = a->sd[i] > b->sd[i]? ~0ul: 0;
		if (v != r->ud[i])
			return 8;
	}
	ret = callit(0x21, 0, test5);
	if (ret)
		return ret | 0x9000;
	for (i = 0; i < 16; ++i) {
		v = a->ub[i] > b->ub[i]? 0xff: 0;
		if (v != r->ub[i])
			return 9;
	}
	ret = callit(0x22, 0, test5);
	if (ret)
		return ret | 0xa000;
	for (i = 0; i < 8; ++i) {
		v = a->uh[i] > b->uh[i]? 0xffff: 0;
		if (v != r->uh[i])
			return 10;
	}
	ret = callit(0x24, 0, test5);
	if (ret)
		return ret | 0xb000;
	for (i = 0; i < 4; ++i) {
		v = a->uw[i] > b->uw[i]? 0xffffffff: 0;
		if (v != r->uw[i])
			return 11;
	}
	ret = callit(0x28, 0, test5);
	if (ret)
		return ret | 0xc000;
	for (i = 0; i < 2; ++i) {
		v = a->ud[i] > b->ud[i]? ~0ul: 0;
		if (v != r->ud[i])
			return 12;
	}
	return 0;
}

unsigned char p1[16] __attribute__((__aligned__(16))) =
	{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xdb, 0x7f };
unsigned char p2[16] __attribute__((__aligned__(16))) =
	{ 0x6d, 0x70, 0x7c, 0x65, 0x6d, 0x65, 0x6e, 0x74, 0x65, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
unsigned char p3[16] __attribute__((__aligned__(16))) =
	{ 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
unsigned char p4[16] __attribute__((__aligned__(16))) =
	{ 0xff, 0x7f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff };
unsigned char r4[16] =
	{ 0x80, 0x7f, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
unsigned char p5[16] __attribute__((__aligned__(16))) =
	{ 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00 };
unsigned char p6[16] __attribute__((__aligned__(16))) =
	{ 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5, 0xa5 };
unsigned char r6[16] =
	{ 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x1f, 0x00, 0x00, 0x00 };

unsigned long test6(unsigned long size, unsigned long t)
{
	switch (size) {
	case 0x1:
		asm("lvx 7,0,%1; lvx 4,0,%2; vbpermq 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (p1), "r" (p2) : "memory");
		break;
	case 0x2:
		asm("lvx 7,0,%1; lvx 4,0,%2; vrlh 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (p3), "r" (p4) : "memory");
		break;
	case 0x3:
		asm("lvx 7,0,%1; lvx 4,0,%2; vslv 8,7,4; stvx 8,0,%0" : :
		    "r" (result), "r" (p5), "r" (p6) : "memory");
		break;
	default:
		return size | 0xff000;
	}
	return 0;
}

int vector_test_6(void)
{
	unsigned long ret, i;

	enable_vec();

	ret = callit(1, 0, test6);
	if (ret)
		return ret | 0x1000;
	if (result[8] != 0xff || result[9] != 0x03)
		return 1;
	for (i = 0; i < 16; ++i) {
		if (i != 8 && i != 9 && result[i])
			return 2;
	}
	ret = callit(2, 0, test6);
	if (ret)
		return ret | 0x2000;
	for (i = 0; i < 16; ++i) {
		if (result[i] != r4[i])
			return 3;
	}
	ret = callit(3, 0, test6);
	if (ret)
		return ret | 0x3000;
	for (i = 0; i < 16; ++i) {
		if (result[i] != r6[i])
			return 4;
	}
	return 0;
}

unsigned long test7(unsigned long n, unsigned long t)
{
	unsigned long ret = 0;

	switch (n) {
	case 1:
		asm("mtvsrws 55,%1; mtvscr 23; mfvscr 0; mfvsrld %0,32" :
		    "=r" (ret) : "r" (t));
		break;
	case 2:
		asm("mtvsrws 55,%1; mtvscr 23; vor 0,1,2; mfvscr 0; mfvsrld %0,32" :
		    "=r" (ret) : "r" (t));
		break;
	case 3:
		asm("mtvsrws 55,%1; vspltisw 1,0; mtvscr 1; vsumsws 2,23,23; mfvscr 0; mfvsrld %0,32" :
		    "=r" (ret) : "r" (t));
		break;
	default:
		return n | 0xff000;
	}
	return ret;
}

int vector_test_7(void)
{
	unsigned long ret;

	enable_vec();

	ret = callit(1, 0, test7);
	if (ret)
		return ret | 0x1000;
	ret = callit(1, 0x10001, test7);
	if (ret != 0x10001)
		return ret | 0x2000;
	ret = callit(2, 0x10000, test7);
	if (ret != 0x10000)
		return ret | 0x3000;
	ret = callit(2, 1, test7);
	if (ret != 1)
		return ret | 0x4000;
	ret = callit(3, 1, test7);
	if (ret)
		return ret | 0x5000;
	ret = callit(3, 0x7fffffff, test7);
	if (ret != 1)
		return ret | 0x6000;
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
	do_test(4, vector_test_4);
	do_test(5, vector_test_5);
	do_test(6, vector_test_6);
	do_test(7, vector_test_7);

	return fail;
}
