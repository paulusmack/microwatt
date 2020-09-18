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
#define MSR_FP	0x2000
#define MSR_FE0	0x800
#define MSR_FE1	0x100
#define MSR_LE	1

unsigned long mfmsr(void)
{
	unsigned long msr;

	asm("mfmsr %0" : "=r" (msr));
	return msr;
}

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

void disable_vsx(void)
{
	unsigned long msr;

	asm("mfmsr %0" : "=r" (msr));
	msr &= ~MSR_VSX;
	asm("mtmsrd %0" : : "r" (msr));
}

void enable_vsx(void)
{
	unsigned long msr;

	asm("mfmsr %0" : "=r" (msr));
	msr |= MSR_VSX;
	asm("mtmsrd %0" : : "r" (msr));
}

#define SRR0	26
#define SRR1	27

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

unsigned char result[16] __attribute__((__aligned__(16)));

unsigned long do_scalar_load(unsigned long size, unsigned long addr)
{
	switch (size) {
	case 1:
		asm("lvx 1,0,%1; lxsibzx 33,0,%0; stvx 1,0,%1" : : "r" (addr), "r" (&result) : "memory");
		break;
	case 2:
		asm("lvx 1,0,%1; lxsihzx 33,0,%0; stvx 1,0,%1" : : "r" (addr), "r" (&result) : "memory");
		break;
	case 4:
		asm("lvx 1,0,%1; lxsiwzx 33,0,%0; stvx 1,0,%1" : : "r" (addr), "r" (&result) : "memory");
		break;
	case 5:
		asm("lvx 1,0,%1; lxsiwax 33,0,%0; stvx 1,0,%1" : : "r" (addr), "r" (&result) : "memory");
		break;
	case 8:
		asm("lvx 1,0,%1; lxsd 1,12(%0); stvx 1,0,%1" : : "b" (addr - 12), "r" (&result) : "memory");
		break;
	case 9:
		asm("lvx 1,0,%1; lxsdx 33,0,%0; stvx 1,0,%1" : : "r" (addr), "r" (&result) : "memory");
		break;
	case 10:
		asm("lvx 1,0,%1; lxssp 1,12(%0); stvx 1,0,%1" : : "b" (addr - 12), "r" (&result) : "memory");
		break;
	case 11:
		asm("lvx 1,0,%1; lxsspx 33,0,%0; stvx 1,0,%1" : : "r" (addr), "r" (&result) : "memory");
		break;
	default:
		return 0xff000 | size;
	}
	return 0;
}

unsigned int spval = 0x80201234;
unsigned long dpval = 0xb7f0091a00000000;

/* test VSX scalar loads */
int vsx_test_1(void)
{
	unsigned char data[16] __attribute__((__aligned__(16)));
	unsigned long ret, i;
	unsigned char v;

	/* test lxsd, lxsdx */
	enable_vec();		/* for the lvx/stvx */
	disable_vsx();
	v = 0;
	for (i = 0; i < 16; ++i) {
		data[i] = (v += 23);
		result[i] = (v += 23);
	}
	++v;
	ret = callit(8, (unsigned long)&data[5], do_scalar_load);
	if (ret != 0xf40)
		return ret | 0x1000;
	enable_vec();		/* taking interrupt clears FP/VEC/VSX */
	ret = callit(9, (unsigned long)&data[2], do_scalar_load);
	if (ret != 0xf40)
		return ret | 0x2000;
	enable_vec();
	enable_vsx();
	ret = callit(8, (unsigned long)&data[5], do_scalar_load);
	if (ret)
		return ret | 0x3000;
	for (i = 0; i < 8; ++i) {
		if (result[i])
			return 3;
		if (result[i+8] != data[i+5])
			return 4;
	}
	for (i = 0; i < 16; ++i)
		result[i] = (v += 23);
	++v;
	ret = callit(9, (unsigned long)&data[2], do_scalar_load);
	if (ret)
		return ret | 0x4000;
	for (i = 0; i < 8; ++i) {
		if (result[i])
			return 5;
		if (result[i+8] != data[i+2])
			return 6;
	}
	/* test lxsibzx */
	for (i = 0; i < 16; ++i)
		result[i] = (v += 23);
	++v;
	ret = callit(1, (unsigned long)&data[9], do_scalar_load);
	if (ret)
		return ret | 0x5000;
	if (result[8] != data[9])
		return 7;
	for (i = 0; i < 16; ++i)
		if (i != 8 && result[i])
			return 8;
	/* test lxsihzx */
	for (i = 0; i < 16; ++i)
		result[i] = (v += 23);
	++v;
	ret = callit(2, (unsigned long)&data[11], do_scalar_load);
	if (ret)
		return ret | 0x6000;
	if (result[8] != data[11] || result[9] != data[12])
		return 9;
	for (i = 0; i < 16; ++i)
		if (i != 8 && i != 9 && result[i])
			return 10;
	/* test lxsiwzx */
	for (i = 0; i < 16; ++i)
		result[i] = (v += 23);
	++v;
	ret = callit(4, (unsigned long)&data[3], do_scalar_load);
	if (ret)
		return ret | 0x7000;
	for (i = 0; i < 4; ++i)
		if (result[i + 8] != data[i + 3])
			return 11;
	for (i = 0; i < 16; ++i)
		if ((i < 8 || i > 11) && result[i])
			return 12;
	/* test lxsiwax */
	for (i = 0; i < 16; ++i)
		result[i] = (v += 23);
	++v;
	data[5] |= 0x80;		/* make it negative */
	ret = callit(5, (unsigned long)&data[1], do_scalar_load);
	if (ret)
		return ret | 0x8000;
	for (i = 0; i < 4; ++i)
		if (result[i + 8] != data[i + 1])
			return 13;
	for (i = 0; i < 8; ++i)
		if (result[i])
			return 14;
	for (i = 12; i < 16; ++i)
		if (result[i] != 0xff)
			return 15;
	/* test lxssp and lxsspx */
	for (i = 0; i < 16; ++i)
		result[i] = (v += 23);
	++v;
	ret = callit(10, (unsigned long)&spval, do_scalar_load);
	if (ret)
		return ret | 0x9000;
	for (i = 0; i < 8; ++i)
		if (result[i])
			return 16;
	for (i = 0; i < 8; ++i)
		if (result[i + 8] != ((unsigned char *)&dpval)[i])
			return 17;
	for (i = 0; i < 16; ++i)
		result[i] = (v += 23);
	++v;
	ret = callit(11, (unsigned long)&spval, do_scalar_load);
	if (ret)
		return ret | 0x9000;
	for (i = 0; i < 8; ++i)
		if (result[i])
			return 18;
	for (i = 0; i < 8; ++i)
		if (result[i + 8] != ((unsigned char *)&dpval)[i])
			return 19;
	return 0;
}

unsigned long do_vector_load(unsigned long size, unsigned long addr)
{
	switch (size) {
	case 0x100:
		asm("lxv 2,0(%0)" : : "b" (addr));
		break;
	case 0x101:
		asm("lxv 34,0(%0)" : : "b" (addr));
		break;
	case 1:
		asm("lxvb16x 35,0,%0; stvx 3,0,%1" : : "r" (addr), "r" (result) : "memory");
		break;
	case 2:
		asm("lxvh8x 36,0,%0; stvx 4,0,%1" : : "r" (addr), "r" (result) : "memory");
		break;
	case 4:
		asm("lxvw4x 37,0,%0; stvx 5,0,%1" : : "r" (addr), "r" (result) : "memory");
		break;
	case 5:
		asm("lxvwsx 40,0,%0; stvx 8,0,%1" : : "r" (addr), "r" (result) : "memory");
		break;
	case 8:
		asm("lxvd2x 38,0,%0; stvx 6,0,%1" : : "r" (addr), "r" (result) : "memory");
		break;
	case 9:
		asm("lxvdsx 40,0,%0; stvx 8,0,%1" : : "r" (addr), "r" (result) : "memory");
		break;
	case 16:
		asm("lxv 33,0(%0); stvx 1,0,%1" : : "b" (addr), "r" (result) : "memory");
		break;
	case 17:
		/* it seems lxvx gets assembled as lxv2dx without the .machine power9 */
		asm(".machine \"power9\"; lxvx 33,%0,%1; stvx 1,0,%2" : :
		    "b" (addr - 23), "r" (23), "r" (result) : "memory");
		break;
	default:
		return 0xff000 | size;
	}
	return 0;
}

/* test VSX vector loads */
int vsx_test_2(void)
{
	unsigned char data[32] __attribute__((__aligned__(16)));
	unsigned long ret, i;
	unsigned char v;

	/* test lxv, lxvx */
	disable_vec();
	disable_vsx();
	ret = callit(0x100, (unsigned long)data, do_vector_load);
	if (ret != 0xf40)
		return ret | 0x1000;
	ret = callit(0x101, (unsigned long)data, do_vector_load);
	if (ret != 0xf20)
		return ret | 0x2000;
	v = 1;
	for (i = 0; i < 32; ++i)
		data[i] = (v += 23);
	for (i = 0; i < 16; ++i)
		result[i] = (v += 23);
	++v;
	enable_vec();
	enable_vsx();
	ret = callit(16, (unsigned long)data + 5, do_vector_load);
	if (ret)
		return ret | 0x3000;
	for (i = 0; i < 16; ++i)
		if (result[i] != data[i + 5])
			return 1;
	ret = callit(17, (unsigned long)data + 4, do_vector_load);
	if (ret)
		return ret | 0x4000;
	for (i = 0; i < 16; ++i)
		if (result[i] != data[i + 4])
			return 2;
	ret = callit(1, (unsigned long)data + 2, do_vector_load);
	if (ret)
		return ret | 0x5000;
	for (i = 0; i < 16; ++i)
		if (result[i ^ 15] != data[i + 2])
			return 3;
	ret = callit(2, (unsigned long)data + 1, do_vector_load);
	if (ret)
		return ret | 0x6000;
	for (i = 0; i < 16; ++i)
		if (result[i ^ 14] != data[i + 1])
			return 4;
	ret = callit(4, (unsigned long)data + 7, do_vector_load);
	if (ret)
		return ret | 0x7000;
	for (i = 0; i < 16; ++i)
		if (result[i ^ 12] != data[i + 7])
			return 5;
	ret = callit(8, (unsigned long)data + 9, do_vector_load);
	if (ret)
		return ret | 0x8000;
	for (i = 0; i < 16; ++i)
		if (result[i ^ 8] != data[i + 9])
			return 6;
	ret = callit(5, (unsigned long)data + 9, do_vector_load);
	if (ret)
		return ret | 0x9000;
	for (i = 0; i < 16; ++i)
		if (result[i] != data[(i & 3) + 9])
			return 7;
	ret = callit(9, (unsigned long)data + 6, do_vector_load);
	if (ret)
		return ret | 0xa000;
	for (i = 0; i < 16; ++i)
		if (result[i] != data[(i & 7) + 6])
			return 8;
	return 0;
}

unsigned long do_scalar_store(unsigned long size, unsigned long addr)
{
	switch (size) {
	case 0x100:
		asm("stxsd 0,0(%0)" : : "b" (addr) : "memory");
		break;
	case 0x101:
		asm("stxsdx 0,0,%0" : : "r" (addr) : "memory");
		break;
	case 1:
		asm("lxv 7,0(%1); stxsibx 7,0,%0" : : "b" (addr), "r" (result) : "memory");
		break;
	case 2:
		asm("lxv 7,0(%1); stxsihx 7,0,%0" : : "b" (addr), "r" (result) : "memory");
		break;
	case 4:
		asm("lxv 7,0(%1); stxsiwx 7,0,%0" : : "b" (addr), "r" (result) : "memory");
		break;
	case 8:
		asm("lxv 34,0(%1); stxsd 2,-4(%0)" : : "b" (addr + 4), "b" (result) : "memory");
		break;
	case 9:
		asm("lxv 2,0(%1); stxsdx 2,%0,%2" : : "b" (addr + 4), "b" (result), "r" (-4) : "memory");
		break;
	case 10:
		asm("lxv 63,0(%1); stxssp 31,-20(%0)" : : "b" (addr + 20), "b" (result) : "memory");
		break;
	case 11:
		asm("lxv 63,0(%1); stxsspx 63,%0,%2" : : "b" (addr + 20), "b" (result), "r" (-20) : "memory");
		break;
	default:
		return 0xff000 | size;
	}
	return 0;
}

/* test VSX scalar stores */
int vsx_test_3(void)
{
	unsigned char data[16] __attribute__((__aligned__(16)));
	unsigned long ret, i;
	unsigned char v, v0;

	/* test stxsd, stxsdx */
	disable_vec();
	disable_vsx();
	ret = callit(0x100, (unsigned long)data, do_scalar_store);
	if (ret != 0xf20)
		return ret | 0x1000;
	ret = callit(0x101, (unsigned long)data, do_scalar_store);
	if (ret != 0xf40)
		return ret | 0x2000;
	v = 0;
	for (i = 0; i < 16; ++i)
		result[i] = (v += 29);
	++v;
	v0 = v;
	for (i = 0; i < 16; ++i)
		data[i] = (v += 29);
	++v;
	enable_vec();
	enable_vsx();
	ret = callit(8, (unsigned long)&data[5], do_scalar_store);
	if (ret)
		return ret | 0x3000;
	for (i = 0; i < 16; ++i) {
		v0 += 29;
		if (i >= 5 && i < 13) {
			if (data[i] != result[i + 3])
				return 1;
		} else if (data[i] != v0)
			return 2;
	}
	v0 = v;
	for (i = 0; i < 16; ++i)
		data[i] = (v += 29);
	++v;
	ret = callit(9, (unsigned long)&data[3], do_scalar_store);
	if (ret)
		return ret | 0x4000;
	for (i = 0; i < 16; ++i) {
		v0 += 29;
		if (i >= 3 && i < 11) {
			if (data[i] != result[i + 5])
				return 3;
		} else if (data[i] != v0)
			return 4;
	}
	/* test stxsibx */
	v0 = v;
	for (i = 0; i < 16; ++i)
		data[i] = (v += 29);
	++v;
	ret = callit(1, (unsigned long)&data[8], do_scalar_store);
	if (ret)
		return ret | 0x5000;
	if (data[8] != result[8])
		return 5;
	for (i = 0; i < 16; ++i) {
		v0 += 29;
		if (i != 8 && data[i] != v0)
			return 6;
	}
	/* test stxsihx */
	v0 = v;
	for (i = 0; i < 16; ++i)
		data[i] = (v += 29);
	++v;
	ret = callit(2, (unsigned long)&data[13], do_scalar_store);
	if (ret)
		return ret | 0x6000;
	if (data[13] != result[8] || data[14] != result[9])
		return 7;
	for (i = 0; i < 16; ++i) {
		v0 += 29;
		if (i != 13 && i != 14 && data[i] != v0)
			return 8;
	}
	/* test stxsiwx */
	v0 = v;
	for (i = 0; i < 16; ++i)
		data[i] = (v += 29);
	++v;
	ret = callit(4, (unsigned long)&data[2], do_scalar_store);
	if (ret)
		return ret | 0x7000;
	for (i = 0; i < 16; ++i) {
		v0 += 29;
		if (i >= 2 && i < 6) {
			if (data[i] != result[i + 6])
				return 9;
		} else if (data[i] != v0)
			return 10;
	}
	/* test stxssp and stxsspx */
	for (i = 0; i < 8; ++i)
		result[i + 8] = ((unsigned char *)&dpval)[i];
	v0 = v;
	for (i = 0; i < 16; ++i)
		data[i] = (v += 29);
	++v;
	ret = callit(10, (unsigned long)&data[3], do_scalar_store);
	if (ret)
		return ret | 0x8000;
	for (i = 0; i < 16; ++i) {
		v0 += 29;
		if (i >= 3 && i < 7) {
			if (data[i] != ((unsigned char *)&spval)[i - 3])
				return 11;
		} else if (data[i] != v0)
			return 12;
	}
	v0 = v;
	for (i = 0; i < 16; ++i)
		data[i] = (v += 29);
	++v;
	ret = callit(11, (unsigned long)&data[9], do_scalar_store);
	if (ret)
		return ret | 0x9000;
	for (i = 0; i < 16; ++i) {
		v0 += 29;
		if (i >= 9 && i < 13) {
			if (data[i] != ((unsigned char *)&spval)[i - 9])
				return 13;
		} else if (data[i] != v0)
			return 14;
	}
	return 0;
}

unsigned long do_vector_store(unsigned long size, unsigned long addr)
{
	asm(".machine \"power9\"");
	switch (size) {
	case 0x100:
		asm("stxv 0,0(%0)" : : "b" (addr));
		break;
	case 0x101:
		asm("stxv 32,0(%0)" : : "b" (addr));
		break;
	case 1:
		asm("lxv 5,0(%1); stxvb16x 5,0,%0" : : "r" (addr), "b" (result) : "memory");
		break;
	case 2:
		asm("lxv 5,0(%1); stxvh8x 5,0,%0" : : "r" (addr), "b" (result) : "memory");
		break;
	case 4:
		asm("lxv 5,0(%1); stxvw4x 5,0,%0" : : "r" (addr), "b" (result) : "memory");
		break;
	case 8:
		asm("lxv 5,0(%1); stxvd2x 5,0,%0" : : "r" (addr), "b" (result) : "memory");
		break;
	case 16:
		asm("lxv 5,0(%1); stxv 5,32(%0)" : : "b" (addr - 32), "b" (result) : "memory");
		break;
	case 17:
		asm("lxv 5,0(%1); stxvx 5,%0,%2" : : "b" (addr - 32), "b" (result), "r" (32) : "memory");
		break;
	default:
		return 0xff000 | size;
	}
	return 0;
}

/* test VSX vector stores */
int vsx_test_4(void)
{
	unsigned char data[32] __attribute__((__aligned__(16)));
	unsigned long ret, i;
	unsigned char v, v0;

	/* test stxv, stxvx */
	disable_vec();
	disable_vsx();
	ret = callit(0x100, (unsigned long)data, do_vector_store);
	if (ret != 0xf40)
		return ret | 0x1000;
	ret = callit(0x101, (unsigned long)data, do_vector_store);
	if (ret != 0xf20)
		return ret | 0x2000;
	v = v0 = 3;
	for (i = 0; i < 32; ++i)
		data[i] = (v += 37);
	++v;
	for (i = 0; i < 16; ++i)
		result[i] = (v += 37);
	++v;
	enable_vec();
	enable_vsx();
	ret = callit(16, (unsigned long)data + 5, do_vector_store);
	if (ret)
		return ret | 0x3000;
	for (i = 0; i < 32; ++i) {
		v0 += 37;
		if (i >= 5 && i < 21) {
			if (data[i] != result[i - 5])
				return 1;
		} else if (data[i] != v0)
			return 2;
	}
	v0 = v;
	for (i = 0; i < 32; ++i)
		data[i] = (v += 37);
	++v;
	ret = callit(17, (unsigned long)data + 12, do_vector_store);
	if (ret)
		return ret | 0x4000;
	for (i = 0; i < 32; ++i) {
		v0 += 37;
		if (i >= 12 && i < 28) {
			if (data[i] != result[i - 12])
				return 3;
		} else if (data[i] != v0)
			return 4;
	}
	/* test stxvb16x */
	v0 = v;
	for (i = 0; i < 32; ++i)
		data[i] = (v += 37);
	++v;
	ret = callit(1, (unsigned long)data + 15, do_vector_store);
	if (ret)
		return ret | 0x5000;
	for (i = 0; i < 32; ++i) {
		v0 += 37;
		if (i >= 15 && i < 31) {
			if (data[i] != result[(i - 15) ^ 15])
				return 5;
		} else if (data[i] != v0)
			return 6;
	}
	/* test stxvh8x */
	v0 = v;
	for (i = 0; i < 32; ++i)
		data[i] = (v += 37);
	++v;
	ret = callit(2, (unsigned long)data, do_vector_store);
	if (ret)
		return ret | 0x6000;
	for (i = 0; i < 32; ++i) {
		v0 += 37;
		if (i < 16) {
			if (data[i] != result[i ^ 14])
				return 7;
		} else if (data[i] != v0)
			return 8;
	}
	/* test stxvw4x */
	v0 = v;
	for (i = 0; i < 32; ++i)
		data[i] = (v += 37);
	++v;
	ret = callit(4, (unsigned long)data + 7, do_vector_store);
	if (ret)
		return ret | 0x7000;
	for (i = 0; i < 32; ++i) {
		v0 += 37;
		if (i >= 7 && i < 23) {
			if (data[i] != result[(i - 7) ^ 12])
				return 9;
		} else if (data[i] != v0)
			return 10;
	}
	/* test stxvd2x */
	v0 = v;
	for (i = 0; i < 32; ++i)
		data[i] = (v += 37);
	++v;
	ret = callit(8, (unsigned long)data + 8, do_vector_store);
	if (ret)
		return ret | 0x8000;
	for (i = 0; i < 32; ++i) {
		v0 += 37;
		if (i >= 8 && i < 24) {
			if (data[i] != result[(i - 8) ^ 8])
				return 11;
		} else if (data[i] != v0)
			return 12;
	}
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
		print_hex(ret, 5);
		if (ret >= 0x1000) {
			print_string(" SRR0=");
			print_hex(mfspr(SRR0), 16);
			print_string(" SRR1=");
			print_hex(mfspr(SRR1), 16);
		}
		print_string("\r\n");
	}
}

int main(void)
{
	console_init();

	do_test(1, vsx_test_1);
	do_test(2, vsx_test_2);
	do_test(3, vsx_test_3);
	do_test(4, vsx_test_4);

	return fail;
}
