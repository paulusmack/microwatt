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

#define STACK_TOP 0x2000

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

/* test illegal */
.global ill_test_1
ill_test_1:
	li	%r3, 1 // preload a failure
	.long	0x0 // illegal will be skipped + 1 more
	b	1f  // skipped

	li	%r3, 1 // preload a failure
	.long	0x0 // illegal will be skipped + 1 more
	b	1f  // skipped

	li	%r3, 0
	blr
1:
	li	%r3, 1
	blr

#define EXCEPTION(nr)		\
	.= nr			;\
	b	.

	/* More exception stubs */
	EXCEPTION(0x300)
	EXCEPTION(0x380)
	EXCEPTION(0x400)
	EXCEPTION(0x480)
	EXCEPTION(0x500)
	EXCEPTION(0x600)

	// We shouldn't get a Program interrupt at 700, so fail
	. = 0x700
	mtsprg0	%r3

	mfsrr0	%r3
	addi	%r3, %r3, 4 // skip one instruction, causing a fail
	mtsrr0  %r3

	mfsprg0	%r3
	rfid

	EXCEPTION(0x800)
	EXCEPTION(0x900)
	EXCEPTION(0x980)
	EXCEPTION(0xa00)
	EXCEPTION(0xb00)
	EXCEPTION(0xc00)
	EXCEPTION(0xd00)
	EXCEPTION(0xe00)
	EXCEPTION(0xe20)

	// We now expect a HEAI at e40 for illegal instructions
	. = 0xe40
	mthsprg0 %r3

	mfhsrr0	%r3
	addi	%r3, %r3, 8 // skip one instruction, causing success
	mthsrr0 %r3

	mfhsprg0 %r3
	hrfid

	EXCEPTION(0xe60)
	EXCEPTION(0xe80)
	EXCEPTION(0xf00)
	EXCEPTION(0xf20)
	EXCEPTION(0xf40)
	EXCEPTION(0xf60)
	EXCEPTION(0xf80)
#if 0
	EXCEPTION(0x1000)
	EXCEPTION(0x1100)
	EXCEPTION(0x1200)
	EXCEPTION(0x1300)
	EXCEPTION(0x1400)
	EXCEPTION(0x1500)
	EXCEPTION(0x1600)
#endif


