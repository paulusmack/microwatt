#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "console.h"

extern int test_exec(unsigned long addr, long testno);

static inline void do_tlbie(unsigned long rb, unsigned long rs)
{
	__asm__ volatile("tlbie %0,%1" : : "r" (rb), "r" (rs) : "memory");
}

static inline unsigned long mfspr(int sprnum)
{
	long val;

	__asm__ volatile("mfspr %0,%1" : "=r" (val) : "i" (sprnum));
	return val;
}

static inline void mtspr(int sprnum, unsigned long val)
{
	__asm__ volatile("mtspr %0,%1" : : "i" (sprnum), "r" (val));
}

void print_string(const char *str)
{
	for (; *str; ++str)
		putchar(*str);
}

void print_hex(unsigned long val)
{
	int i, x;

	for (i = 60; i >= 0; i -= 4) {
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

#define PERM_EX		0x001
#define PERM_WR		0x002
#define PERM_RD		0x004
#define PERM_PRIV	0x008
#define ATTR_NC		0x020
#define CHG		0x080
#define REF		0x100

#define DFLT_PERM	(PERM_EX | PERM_WR | PERM_RD | REF | CHG)
#define DFLT_PERM_NOX	(PERM_WR | PERM_RD | REF | CHG)

static void tlbwe(unsigned long ea, unsigned long pa, unsigned long perm_attr)
{
	do_tlbie(((unsigned long)ea & ~0xfff) | 0x100,
		 ((unsigned long)pa & ~0xfff) | perm_attr);
}

int itlb_test_1(void)
{
	unsigned long ptr = 0x123000;

	/* this should fail */
	if (test_exec(ptr, 0))
		return 1;
	/* SRR0 and SRR1 should be set correctly */
	if (mfspr(26) != (long) ptr || mfspr(27) != 0x40000020)
		return 2;
	return 0;
}

int itlb_test_2(void)
{
	unsigned long mem = 0x1000;
	unsigned long ptr = 0x124000;
	unsigned long ptr2 = 0x1124000;

	/* load a TLB entry */
	tlbwe(ptr, mem, DFLT_PERM);
	/* this should succeed and be a cache miss */
	if (!test_exec(ptr, 0))
		return 1;
	/* load a second TLB entry */
	tlbwe(ptr2, mem, DFLT_PERM);
	/* this should succeed and be a cache hit */
	if (!test_exec(ptr2, 0))
		return 2;
	return 0;
}

int itlb_test_3(void)
{
	unsigned long mem = 0x1000;
	unsigned long ptr = 0x149000;
	unsigned long ptr2 = 0x14a000;

	/* load a TLB entry */
	tlbwe(ptr, mem, DFLT_PERM);
	/* this should succeed */
	if (!test_exec(ptr, 1))
		return 1;
	/* invalidate the TLB entry */
	do_tlbie((long)ptr, 0);
	/* install a second TLB entry */
	tlbwe(ptr2, mem, DFLT_PERM);
	/* this should fail */
	if (test_exec(ptr, 1))
		return 2;
	/* SRR0 and SRR1 should be set correctly */
	if (mfspr(26) != (long) ptr || mfspr(27) != 0x40000020)
		return 3;
	return 0;
}

int itlb_test_4(void)
{
	unsigned long mem = 0x1000;
	unsigned long mem2 = 0x2000;
	unsigned long ptr = 0x10a000;
	unsigned long ptr2 = 0x10b000;

	/* load a TLB entry */
	tlbwe(ptr, mem, DFLT_PERM);
	/* this should fail due to second page not being mapped */
	if (test_exec(ptr, 2))
		return 1;
	/* SRR0 and SRR1 should be set correctly */
	if (mfspr(26) != ptr2 || mfspr(27) != 0x40000020)
		return 2;
	/* load a TLB entry for the second page */
	tlbwe(ptr2, mem2, DFLT_PERM);
	/* this should succeed */
	if (!test_exec(ptr, 2))
		return 3;
	return 0;
}

int fail = 0;

void do_test(int num, int (*test)(void))
{
	int ret;

	do_tlbie(0xc00, 0);	/* invalidate all TLB entries */
	mtspr(26, 0);
	mtspr(27, 0);
	print_test_number(num);
	ret = test();
	if (ret == 0) {
		print_string("PASS\r\n");
	} else {
		fail = 1;
		print_string("FAIL ");
		putchar(ret + '0');
		print_string(" SRR0=");
		print_hex(mfspr(26));
		print_string(" SRR1=");
		print_hex(mfspr(27));
		print_string("\r\n");
	}
}

int main(void)
{
	potato_uart_init();

	do_test(1, itlb_test_1);
	do_test(2, itlb_test_2);
	do_test(3, itlb_test_3);
	do_test(4, itlb_test_4);

	return fail;
}
