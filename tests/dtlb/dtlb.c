#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "console.h"

extern int test_read(long *addr, long *ret, long init);
extern int test_write(long *addr, long val);

static inline void do_tlbie(unsigned long rb, unsigned long rs)
{
	__asm__ volatile("tlbie %0,%1" : : "r" (rb), "r" (rs) : "memory");
}

static inline unsigned long mfspr(int sprnum)
{
	long val;

	__asm__ volatile ("mfspr %0,%1" : "=r" (val) : "i" (sprnum));
	return val;
}

void print_string(const char *str)
{
	for (; *str; ++str)
		putchar(*str);
}

// i < 100
void print_test_number(int i)
{
	print_string("test ");
	putchar(48 + i/10);
	putchar(48 + i%10);
	putchar(':');
}

int dtlb_test_1(void)
{
	long *ptr = (long *) 0x123000;
	long val;

	/* this should fail */
	if (test_read(ptr, &val, 0xdeadbeefd00d))
		return 0;
	/* dest reg of load should be unchanged */
	if (val != 0xdeadbeefd00d)
		return 0;
	/* DAR and DSISR should be set correctly */
	if (mfspr(19) != (long) ptr || mfspr(18) != 0x40000000)
		return 0;
	return 1;
}

int dtlb_test_2(void)
{
	long *mem = (long *) 0x4000;
	long *ptr = (long *) 0x124000;
	long *ptr2 = (long *) 0x1124000;
	long val;

	/* load a TLB entry */
	do_tlbie((long)ptr | 0x200, (long)mem);
	/* initialize the memory content */
	mem[33] = 0xbadc0ffee;
	/* this should succeed and be a cache miss */
	if (!test_read(&ptr[33], &val, 0xdeadbeefd00d))
		return 0;
	/* dest reg of load should have the value written */
	if (val != 0xbadc0ffee)
		return 0;
	/* load a second TLB entry in the same set as the first */
	do_tlbie((long)ptr2 | 0x200, (long)mem);
	/* this should succeed and be a cache hit */
	if (!test_read(&ptr2[33], &val, 0xdeadbeefd00d))
		return 0;
	/* dest reg of load should have the value written */
	if (val != 0xbadc0ffee)
		return 0;
	/* check that the first entry still exists */
	/* (assumes TLB is 2-way associative or more) */
	if (!test_read(&ptr[33], &val, 0xdeadbeefd00d))
		return 0;
	if (val != 0xbadc0ffee)
		return 0;
	return 1;
}

int dtlb_test_3(void)
{
	long *mem = (long *) 0x5000;
	long *ptr = (long *) 0x149000;
	long val;

	/* load a TLB entry */
	do_tlbie((long)ptr | 0x200, (long)mem);
	/* initialize the memory content */
	mem[45] = 0xfee1800d4ea;
	/* this should succeed and be a cache miss */
	if (!test_read(&ptr[45], &val, 0xdeadbeefd0d0))
		return 0;
	/* dest reg of load should have the value written */
	if (val != 0xfee1800d4ea)
		return 0;
	/* invalidate the TLB entry */
	do_tlbie((long)ptr, 0);
	/* this should fail */
	if (test_read(&ptr[45], &val, 0xdeadbeefd0d0))
		return 0;
	/* dest reg of load should be unchanged */
	if (val != 0xdeadbeefd0d0)
		return 0;
	/* DAR and DSISR should be set correctly */
	if (mfspr(19) != (long) &ptr[45] || mfspr(18) != 0x40000000)
		return 0;
	return 1;
}

int dtlb_test_4(void)
{
	long *mem = (long *) 0x6000;
	long *ptr = (long *) 0x10a000;
	long *ptr2 = (long *) 0x110a000;
	long val;

	/* load a TLB entry */
	do_tlbie((long)ptr | 0x200, (long)mem);
	/* initialize the memory content */
	mem[27] = 0xf00f00f00f00;
	/* this should succeed and be a cache miss */
	if (!test_write(&ptr[27], 0xe44badc0ffee))
		return 0;
	/* memory should now have the value written */
	if (mem[27] != 0xe44badc0ffee)
		return 0;
	/* load a second TLB entry in the same set as the first */
	do_tlbie((long)ptr2 | 0x200, (long)mem);
	/* this should succeed and be a cache hit */
	if (!test_write(&ptr2[27], 0x6e11ae))
		return 0;
	/* memory should have the value written */
	if (mem[27] != 0x6e11ae)
		return 0;
	/* check that the first entry still exists */
	/* (assumes TLB is 2-way associative or more) */
	if (!test_read(&ptr[27], &val, 0xdeadbeefd00d))
		return 0;
	if (val != 0x6e11ae)
		return 0;
	return 1;
}

int dtlb_test_5(void)
{
	long *mem = (long *) 0x7ffd;
	long *ptr = (long *) 0x396ffd;
	long val;

	/* load a TLB entry */
	do_tlbie(((long)ptr & ~0xfff) | 0x200, (long)mem & ~0xfff);
	/* this should fail */
	if (test_read(ptr, &val, 0xdeadbeef0dd0))
		return 0;
	/* dest reg of load should be unchanged */
	if (val != 0xdeadbeef0dd0)
		return 0;
	/* DAR and DSISR should be set correctly */
	if (mfspr(19) != ((long)ptr & ~0xfff) + 0x1000 || mfspr(18) != 0x40000000)
		return 0;
	return 1;
}

int dtlb_test_6(void)
{
	long *mem = (long *) 0x7ffd;
	long *ptr = (long *) 0x396ffd;

	/* load a TLB entry */
	do_tlbie(((long)ptr & ~0xfff) | 0x200, (long)mem & ~0xfff);
	/* initialize memory */
	*mem = 0x123456789abcdef0;
	/* this should fail */
	if (test_write(ptr, 0xdeadbeef0dd0))
		return 0;
	/* DAR and DSISR should be set correctly */
	if (mfspr(19) != ((long)ptr & ~0xfff) + 0x1000 || mfspr(18) != 0x40000000)
		return 0;
	return 1;
}

int fail = 0;

void do_test(int num, int (*test)(void))
{
	do_tlbie(0xc00, 0);	/* invalidate all TLB entries */
	print_test_number(num);
	if (test() != 0) {
		fail = 1;
		print_string("PASS\r\n");
	} else
		print_string("FAIL\r\n");
}

int main(void)
{
	potato_uart_init();

	do_test(1, dtlb_test_1);
	do_test(2, dtlb_test_2);
	do_test(3, dtlb_test_3);
	do_test(4, dtlb_test_4);
	do_test(5, dtlb_test_5);
	do_test(6, dtlb_test_6);

	return fail;
}
