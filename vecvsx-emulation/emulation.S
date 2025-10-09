/*
 * Copyright 2025 Paul Mackerras <paulus@ozlabs.org>
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

	.text
	.machine "power10"

SRR0	= 26
SRR1	= 27
HEIR	= 339
HSRR0	= 314
HSRR1	= 315
# emulation control SPR
EMUC	= 727

MSR_VSX = 0x800000
MSR_VEC = 0x2000000

	# Register file offsets
FR0	= 0x40
VSR0	= 0x40
VR0	= 0x80
LO	= 0x20		# offset to low half of VSR/VR

	# Condition register bits (big-endian numbering)
LT	= 0
GT	= 1
EQ	= 2
SO	= 3

	.macro	mfrin rt,ra		# move from register indirect, (RA)=reg index
	.long	0x58000000+(\rt<<21)+(\ra<<16)
	.endm
	.macro	mtrin rs,ra		# move to register indirect, (RA)=reg index
	.long	0x58000001+(\rs<<21)+(\ra<<16)
	.endm

entry:
	mfcr	%r31
	mfctr	%r30
	mfspr	%r8,HEIR
	mfspr	%r2,HSRR1
	rlwinm	%r4,%r8,5+11,0x1f		# A field
	rlwinm	%r5,%r8,5+16,0x1f		# B field
	rlwinm	%r6,%r8,5+6,0x1f		# T field
	# Since only primary opcodes 4 and 60 come here,
	# we can look at the MSB to distinguish
	andis.	%r0,%r8,0x8000
	bne	po60

	# Primary opcode 4, vector instructions
	rlwinm	%r1,%r8,32-6+2,0x7c		# extended opcode row * 4
	rlwinm	%r3,%r8,2,0xfc			# extended opcode column * 4
	addpcis	%r9,0
	addi	%r9,%r9,op4_table-.
	addi	%r4,%r4,VR0
	addi	%r5,%r5,VR0
	addi	%r6,%r6,VR0
	lwzx	%r11,%r3,%r9
	cmpdi	%r11,0
	beq	illegal
	add	%r11,%r11,%r9
	lwzx	%r12,%r1,%r11
	cmpdi	%r12,0
	beq	illegal
	add	%r12,%r12,%r11
	mtctr	%r12
	bctr

po60:	rlwinm	%r1,%r8,32-2,0x1ff		# extract extended opcode
	rlwimi	%r4,%r8,6-2,0x40		# insert AX field
	rlwimi	%r5,%r8,6-1,0x40		# insert BX field
	rlwimi	%r6,%r8,6-0,0x40		# insert TX field
	addi	%r4,%r4,VSR0
	addi	%r5,%r5,VSR0
	addi	%r6,%r6,VSR0
	andi.	%r0,%r1,0x13e			# mask off DM/SHW and AX fields
	cmpdi	%r0,20
	beq	do_xxpermdi
	cmpdi	%r0,4
	beq	do_xxsldwi
	b	illegal

illegal:
	# anything we don't recognize gets punted to e40
	mtcr	%r31
	li	%r0,0
	mtspr	EMUC,%r0
	isync
	ba	0xe40

op4_table:
	.long	0		# column 0
	.long	0
	.long	vcol2 - op4_table
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# column 10
	.long	0
	.long	0
	.long	0
	.long	vcol14 - op4_table
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# column 20
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# column 30
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# column 40
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# column 50
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# column 60
	.long	0
	.long	0
	.long	0

vcol2:
	.long	do_vmaxub - vcol2		# row 0
	.long	do_vmaxuh - vcol2
	.long	do_vmaxuw - vcol2
	.long	do_vmaxud - vcol2
	.long	do_vmaxsb - vcol2		# row 4
	.long	do_vmaxsh - vcol2
	.long	do_vmaxsw - vcol2
	.long	do_vmaxsd - vcol2
	.long	do_vminub - vcol2		# row 8
	.long	do_vminuh - vcol2
	.long	do_vminuw - vcol2
	.long	do_vminud - vcol2
	.long	do_vminsb - vcol2		# row 12
	.long	do_vminsh - vcol2
	.long	do_vminsw - vcol2
	.long	do_vminsd - vcol2
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# row 20
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# row 30
	.long	0

vcol14:
	.long	0		# row 0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# row 10
	.long	0
	.long	do_vpkpx - vcol14
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# row 20
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# row 30
	.long	0

do_xxpermdi:
	andis.	%r0,%r2,MSR_VSX@h
	beq	vsx_unavail
	rlwimi	%r4,%r8,5-9+32,LO		# insert bit 0 of DM
	rlwimi	%r5,%r8,5-8+32,LO		# insert bit 1 of DM
	mfrin	0,4				# fetch hi/lo half of XA
	mfrin	1,5				# fetch hi/lo half of XB
	mtrin	0,6				# put in hi half of XT
	addi	%r6,%r6,LO
	mtrin	1,6				# put in lo half of XT
	b	return

do_xxsldwi:
	andis.	%r0,%r2,MSR_VSX@h
	beq	vsx_unavail
	mtcrf	0x04,%r8			# put SHW field into CR5
	mfrin	0,4				# A hi
	addi	%r4,%r4,LO
	mfrin	2,5				# B hi
	addi	%r5,%r5,LO
	mfrin	1,4				# A lo
	mfrin	3,5				# B lo
	bc	4,22,1f				# branch if SHW MSB is 0
	mr	%r0,%r1
	mr	%r1,%r2
	mr	%r2,%r3
1:	bc	4,23,2f				# branch if SHW LSB is 0
	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	rotldi	%r2,%r2,32
	rldimi	%r0,%r1,0,32
	rldimi	%r1,%r2,0,32
2:	mtrin	0,6				# store result in XT
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return

do_vpkpx:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	li	%r12,1
2:	mr	%r9,%r10
	li	%r10,0
1:	mfrin	0,4
	rotldi	%r10,%r10,32
	rlwimi	%r10,%r0,15-24+32,0xfc00	# bits 24..19 -> bits 15..10
	rlwimi	%r10,%r0,9-15+32,0x03e0		# bits 15..10 -> bits 9..5
	rlwimi	%r10,%r0,4-7+32,0x001f		# bits 7..3 -> bits 4..0
	rotldi	%r0,%r0,32
	rlwimi	%r10,%r0,31-24,0xfc000000	# bits 24..19 -> bits 31..26
	rlwimi	%r10,%r0,25-15,0x03e00000	# bits 15..10 -> bits 25..21
	rlwimi	%r10,%r0,20-7,0x001f0000	# bits 7..3 -> bits 20..16
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	beq	1b
	mr	%r4,%r5
	cmpdi	%r12,0
	addi	%r12,%r12,-1
	bne	2b
	mtrin	9,6
	addi	%r6,%r6,LO
	mtrin	10,6
	b	return

do_vmaxsb:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,8
	mtctr	%r11
	li	%r7,0
3:	cmpd	%r1,%r0
	setnbc	%r3,GT
	clrrdi	%r3,%r3,56
	or	%r7,%r7,%r3
	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	rotldi	%r7,%r7,8
	bdnz	3b
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vmaxub:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,8
	mtctr	%r11
	li	%r7,0
3:	cmpld	%r1,%r0
	setnbc	%r3,GT
	clrrdi	%r3,%r3,56
	or	%r7,%r7,%r3
	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	rotldi	%r7,%r7,8
	bdnz	3b
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vmaxsh:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,4
	mtctr	%r11
	li	%r7,0
3:	cmpd	%r1,%r0
	setnbc	%r3,GT
	clrrdi	%r3,%r3,48
	or	%r7,%r7,%r3
	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r7,%r7,16
	bdnz	3b
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vmaxuh:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,4
	mtctr	%r11
	li	%r7,0
3:	cmpld	%r1,%r0
	setnbc	%r3,GT
	clrrdi	%r3,%r3,48
	or	%r7,%r7,%r3
	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r7,%r7,16
	bdnz	3b
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vmaxsw:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,2
	mtctr	%r11
	li	%r7,0
3:	cmpd	%r1,%r0
	setnbc	%r3,GT
	clrrdi	%r3,%r3,32
	or	%r7,%r7,%r3
	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	rotldi	%r7,%r7,32
	bdnz	3b
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vmaxuw:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,2
	mtctr	%r11
	li	%r7,0
3:	cmpld	%r1,%r0
	setnbc	%r3,GT
	clrrdi	%r3,%r3,32
	or	%r7,%r7,%r3
	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	rotldi	%r7,%r7,32
	bdnz	3b
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vmaxsd:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
3:	cmpd	%r1,%r0
	setnbc	%r7,GT
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vmaxud:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
3:	cmpld	%r1,%r0
	setnbc	%r7,GT
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vminsb:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,8
	mtctr	%r11
	li	%r7,0
3:	cmpd	%r1,%r0
	setnbc	%r3,LT
	clrrdi	%r3,%r3,56
	or	%r7,%r7,%r3
	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	rotldi	%r7,%r7,8
	bdnz	3b
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vminub:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,8
	mtctr	%r11
	li	%r7,0
3:	cmpld	%r1,%r0
	setnbc	%r3,LT
	clrrdi	%r3,%r3,56
	or	%r7,%r7,%r3
	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	rotldi	%r7,%r7,8
	bdnz	3b
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vminsh:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,4
	mtctr	%r11
	li	%r7,0
3:	cmpd	%r1,%r0
	setnbc	%r3,LT
	clrrdi	%r3,%r3,48
	or	%r7,%r7,%r3
	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r7,%r7,16
	bdnz	3b
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vminuh:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,4
	mtctr	%r11
	li	%r7,0
3:	cmpld	%r1,%r0
	setnbc	%r3,LT
	clrrdi	%r3,%r3,48
	or	%r7,%r7,%r3
	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r7,%r7,16
	bdnz	3b
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vminsw:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,2
	mtctr	%r11
	li	%r7,0
3:	cmpd	%r1,%r0
	setnbc	%r3,LT
	clrrdi	%r3,%r3,32
	or	%r7,%r7,%r3
	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	rotldi	%r7,%r7,32
	bdnz	3b
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vminuw:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,2
	mtctr	%r11
	li	%r7,0
3:	cmpld	%r1,%r0
	setnbc	%r3,LT
	clrrdi	%r3,%r3,32
	or	%r7,%r7,%r3
	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	rotldi	%r7,%r7,32
	bdnz	3b
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vminsd:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
3:	cmpd	%r1,%r0
	setnbc	%r7,LT
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vminud:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
3:	cmpld	%r1,%r0
	setnbc	%r7,LT
	xor	%r1,%r1,%r0
	and	%r1,%r1,%r7
	xor	%r0,%r0,%r1
	mtrin	0,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

return:
	mtctr	%r30
	mfspr	%r1,HSRR0
	addi	%r1,%r1,4
	mtspr	HSRR0,%r1
	mtcr	%r31
	li	%r0,0
	mtspr	EMUC,%r0
	hrfid

vec_unavail:
	mtctr	%r30
	mfspr	%r0,HSRR0
	mfspr	%r1,HSRR1
	mtspr	SRR0,%r0
	mtspr	SRR1,%r1
	mtcr	%r31
	li	%r0,0
	mtspr	EMUC,%r0
	isync
	ba	0xf20

vsx_unavail:
	mtctr	%r30
	mfspr	%r0,HSRR0
	mfspr	%r1,HSRR1
	mtspr	SRR0,%r0
	mtspr	SRR1,%r1
	mtcr	%r31
	li	%r0,0
	mtspr	EMUC,%r0
	isync
	ba	0xf40
