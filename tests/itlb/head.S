/* Copyright 2013-2014 IBM Corp.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * 	http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 * implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#define STACK_TOP 0x8000

/* Load an immediate 64-bit value into a register */
#define LOAD_IMM64(r, e)			\
	lis     r,(e)@highest;			\
	ori     r,r,(e)@higher;			\
	rldicr  r,r, 32, 31;			\
	oris    r,r, (e)@h;			\
	ori     r,r, (e)@l;

	.section ".head","ax"

	/*
	 * Microwatt currently enters in LE mode at 0x0, so we don't need to
	 * do any endian fix ups
	 */
	. = 0
.global _start
_start:
	b	boot_entry

.global boot_entry
boot_entry:
	/* setup stack */
	LOAD_IMM64(%r1, STACK_TOP - 0x100)
	LOAD_IMM64(%r12, main)
	mtctr	%r12
	bctrl
	attn // terminate on exit
	b .

	.globl	test_exec
test_exec:
	nop
	nop
	mtsrr0	%r3
	li	%r9,0x20		/* MSR_IR */
	mtsrr1	%r9
	mr	%r3,%r4
	rfid

#define EXCEPTION(nr)		\
	.= nr			;\
	b	.

	EXCEPTION(0x300)
	EXCEPTION(0x380)

	/*
	 * ISI vector - jump to LR to return from the test,
	 * with r3 cleared
	 */
	. = 0x400
	li	%r3,0
	blr

	/* More exception stubs */
	EXCEPTION(0x480)
	EXCEPTION(0x500)
	EXCEPTION(0x600)
	EXCEPTION(0x700)
	EXCEPTION(0x800)
	EXCEPTION(0x900)
	EXCEPTION(0x980)
	EXCEPTION(0xa00)
	EXCEPTION(0xb00)
	EXCEPTION(0xc00)
	EXCEPTION(0xd00)
	EXCEPTION(0xe00)
	EXCEPTION(0xe20)
	EXCEPTION(0xe40)
	EXCEPTION(0xe60)
	EXCEPTION(0xe80)
	EXCEPTION(0xf00)
	EXCEPTION(0xf20)
	EXCEPTION(0xf40)
	EXCEPTION(0xf60)
	EXCEPTION(0xf80)

	. = 0x1000
	/*
	 * This page gets mapped at various locations and
	 * the tests try to execute from it.
	 * r3 contains the test number.
	 */
	.globl	test_start
test_start:
	nop
	nop
	cmpdi	%r3,1
	beq	test_1
	cmpdi	%r3,2
	beq	test_2
test_return:
	mflr	%r10
	li	%r9,0
	mtsrr0	%r10
	mtsrr1	%r9
	li	%r3,1
	rfid

	. = 0x1ff8
	/* test a branch near the end of a page */
test_1:	b	test_return

	/* test flowing from one page to the next */
test_2:	nop
	b	test_return
