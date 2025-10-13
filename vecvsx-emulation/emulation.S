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

XER	= 1
SRR0	= 26
SRR1	= 27
VRSAVE	= 256
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
	.long	vcol4 - op4_table
	.long	0
	.long	vcol6 - op4_table
	.long	vcol7 - op4_table
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

vcol4:
	.long	do_vrlb - vcol4		# row 0
	.long	do_vrlh - vcol4
	.long	do_vrlw - vcol4
	.long	do_vrld - vcol4
	.long	do_vslb - vcol4		# row 4
	.long	do_vslh - vcol4
	.long	do_vslw - vcol4
	.long	do_vsl - vcol4
	.long	do_vsrb - vcol4		# row 8
	.long	do_vsrh - vcol4
	.long	do_vsrw - vcol4
	.long	do_vsr - vcol4
	.long	do_vsrab - vcol4	# row 12
	.long	do_vsrah - vcol4
	.long	do_vsraw - vcol4
	.long	do_vsrad - vcol4
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# row 20
	.long	0
	.long	0
	.long	do_vsld - vcol4
	.long	do_mfvscr - vcol4
	.long	do_mtvscr - vcol4
	.long	0
	.long	do_vsrd - vcol4
	.long	do_vsrv - vcol4
	.long	do_vslv - vcol4
	.long	0		# row 30
	.long	0

vcol6:
	.long	do_vcmpequb - vcol6		# row 0
	.long	do_vcmpequh - vcol6
	.long	do_vcmpequw - vcol6
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	do_vcmpgtub - vcol6
	.long	do_vcmpgtuh - vcol6
	.long	do_vcmpgtuw - vcol6		# row 10
	.long	0
	.long	do_vcmpgtsb - vcol6
	.long	do_vcmpgtsh - vcol6
	.long	do_vcmpgtsw - vcol6
	.long	0
	.long	do_vcmpequb - vcol6
	.long	do_vcmpequh - vcol6
	.long	do_vcmpequw - vcol6
	.long	0
	.long	0		# row 20
	.long	0
	.long	0
	.long	0
	.long	do_vcmpgtub - vcol6
	.long	do_vcmpgtuh - vcol6
	.long	do_vcmpgtuw - vcol6
	.long	0
	.long	do_vcmpgtsb - vcol6
	.long	do_vcmpgtsh - vcol6
	.long	do_vcmpgtsw - vcol6		# row 30
	.long	0

vcol7:
	.long	do_vcmpneb - vcol7		# row 0
	.long	do_vcmpneh - vcol7
	.long	do_vcmpnew - vcol7
	.long	do_vcmpequd - vcol7
	.long	do_vcmpnezb - vcol7
	.long	do_vcmpnezh - vcol7
	.long	do_vcmpnezw - vcol7
	.long	do_vcmpequq - vcol7
	.long	0
	.long	0
	.long	do_vcmpgtuq - vcol7		# row 10
	.long	do_vcmpgtud - vcol7
	.long	0
	.long	0
	.long	do_vcmpgtsq - vcol7
	.long	do_vcmpgtsd - vcol7
	.long	do_vcmpneb - vcol7
	.long	do_vcmpneh - vcol7
	.long	do_vcmpnew - vcol7
	.long	do_vcmpequd - vcol7
	.long	do_vcmpnezb - vcol7		# row 20
	.long	do_vcmpnezh - vcol7
	.long	do_vcmpnezw - vcol7
	.long	do_vcmpequq - vcol7
	.long	0
	.long	0
	.long	do_vcmpgtuq - vcol7
	.long	do_vcmpgtud - vcol7
	.long	0
	.long	0
	.long	do_vcmpgtsq - vcol7		# row 30
	.long	do_vcmpgtsd - vcol7

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

do_vrlb:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,8
	mtctr	%r11
2:	clrldi	%r8,%r1,61
	clrldi	%r9,%r0,56
	sld	%r9,%r9,%r8
	srdi	%r8,%r9,8
	or	%r9,%r8,%r9
	rlwimi	%r3,%r9,0,0xff
	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	rotldi	%r3,%r3,8
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vrlh:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,4
	mtctr	%r11
2:	clrldi	%r8,%r1,60
	clrldi	%r9,%r0,48
	sld	%r9,%r9,%r8
	srdi	%r8,%r9,16
	or	%r9,%r8,%r9
	rlwimi	%r3,%r9,0,0xffff
	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r3,%r3,16
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vrlw:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	rlwnm	%r3,%r0,%r1,0,31
	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	rlwnm	%r9,%r0,%r1,0,31
	rldimi	%r3,%r9,32,0
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vrld:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
2:	rotld	%r3,%r0,%r1
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vslb:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,8
	mtctr	%r11
2:	clrldi	%r8,%r1,61
	sld	%r9,%r0,%r8
	rlwimi	%r3,%r9,0,0xff
	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	rotldi	%r3,%r3,8
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vslh:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,4
	mtctr	%r11
2:	clrldi	%r8,%r1,60
	sld	%r9,%r0,%r8
	rlwimi	%r3,%r9,0,0xffff
	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r3,%r3,16
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vslw:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	clrldi	%r8,%r1,59
	slw	%r3,%r0,%r8
	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	clrldi	%r8,%r1,59
	slw	%r9,%r0,%r8
	rldimi	%r3,%r9,32,0
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vsld:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
2:	clrldi	%r8,%r1,58
	sld	%r3,%r0,%r8
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vsl:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	1,4
	mfrin	3,5
	clrldi	%r3,%r3,61
	li	%r7,-1
	sld	%r0,%r0,%r3
	rotld	%r1,%r1,%r3
	sld	%r7,%r7,%r3
	andc	%r8,%r1,%r7
	and	%r1,%r1,%r7
	or	%r0,%r0,%r8
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return

do_vsrb:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,8
	mtctr	%r11
2:	clrldi	%r8,%r1,61
	clrldi	%r9,%r0,56
	srd	%r9,%r9,%r8
	rlwimi	%r3,%r9,0,0xff
	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	rotldi	%r3,%r3,8
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vsrh:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,4
	mtctr	%r11
2:	clrldi	%r8,%r1,60
	clrldi	%r9,%r0,48
	srd	%r9,%r9,%r8
	rlwimi	%r3,%r9,0,0xffff
	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r3,%r3,16
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vsrw:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	clrldi	%r8,%r1,59
	srw	%r3,%r0,%r8
	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	clrldi	%r8,%r1,59
	slw	%r9,%r0,%r8
	rldimi	%r3,%r9,32,0
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vsrd:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
2:	clrldi	%r8,%r1,58
	srd	%r3,%r0,%r8
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vsr:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	1,4
	mfrin	3,5
	clrldi	%r3,%r3,61
	li	%r7,-1
	neg	%r9,%r3
	rotld	%r0,%r0,%r9
	srd	%r1,%r1,%r3
	srd	%r7,%r7,%r3
	andc	%r8,%r0,%r7
	and	%r0,%r0,%r7
	or	%r1,%r1,%r8
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return

do_vsrab:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,8
	mtctr	%r11
2:	clrldi	%r8,%r1,61
	extsb	%r9,%r0
	srd	%r9,%r9,%r8
	rlwimi	%r3,%r9,0,0xff
	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	rotldi	%r3,%r3,8
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vsrah:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,4
	mtctr	%r11
2:	clrldi	%r8,%r1,60
	extsh	%r9,%r0
	srd	%r9,%r9,%r8
	rlwimi	%r3,%r9,0,0xffff
	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r3,%r3,16
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	b	return

do_vsraw:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfspr	%r29,XER
1:	mfrin	0,4
	mfrin	1,5
	srad	%r0,%r0,%r1
	clrldi	%r8,%r1,59
	sraw	%r3,%r0,%r8
	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	clrldi	%r8,%r1,59
	sraw	%r9,%r0,%r8
	rldimi	%r3,%r9,32,0
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	mtspr	XER,%r29
	b	return

do_vsrad:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfspr	%r29,XER
1:	mfrin	0,4
	mfrin	1,5
	clrldi	%r8,%r1,58
	srad	%r3,%r0,%r8
	mtrin	3,6
	andi.	%r0,%r4,LO
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	beq	1b
	mtspr	XER,%r29
	b	return

do_vslv:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfrin	0,4
	mfrin	7,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	1,4
	mfrin	8,5
	li	%r11,16
	mtctr	%r11
1:	rldicl	%r12,%r7,8,61
	sld	%r12,%r0,%r12
	srdi	%r12,%r12,56
	sldi	%r0,%r0,8
	sldi	%r7,%r7,8
	rotldi	%r1,%r1,8
	rotldi	%r8,%r8,8
	rldimi	%r0,%r1,0,56
	rldimi	%r7,%r8,0,56
	clrrdi	%r1,%r1,8
	sldi	%r9,%r9,8
	rotldi	%r10,%r10,8
	rldimi	%r9,%r10,0,56
	rldimi	%r10,%r12,0,56
	bdnz	1b
	mtrin	9,6
	addi	%r6,%r6,LO
	mtrin	10,6
	b	return

do_vsrv:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfrin	0,4
	mfrin	7,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	1,4
	mfrin	8,5
	li	%r11,16
	mtctr	%r11
1:	clrldi	%r12,%r8,61
	srd	%r12,%r1,%r12
	rldimi	%r1,%r0,0,56
	rotldi	%r1,%r1,56
	srdi	%r0,%r0,8
	rldimi	%r8,%r7,0,56
	rotldi	%r8,%r8,56
	srdi	%r7,%r7,8
	rldimi	%r10,%r9,0,56
	rldimi	%r9,%r12,0,56
	rotldi	%r9,%r9,56
	rotldi	%r10,%r10,56
	bdnz	1b
	mtrin	9,6
	addi	%r6,%r6,LO
	mtrin	10,6
	b	return

# Note: the high 32 bits of VRSAVE are used to store VSCR
do_mfvscr:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfspr	%r1,VRSAVE
	srdi	%r1,%r1,32
	lis	%r3,1			# NJ bit
	addi	%r3,%r3,1		# SAT bit
	and	%r1,%r1,%r3		# clear all other bits
	li	%r0,0
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return

do_mtvscr:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	addi	%r5,%r5,LO
	mfrin	1,5
	mfspr	%r0,VRSAVE
	rldimi	%r0,%r1,32,0
	mtspr	VRSAVE,%r0
	b	return

do_vcmpequb:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfrin	0,4
	mfrin	1,5
	cmpb	%r2,%r0,%r1
	mtrin	2,6
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	cmpb	%r3,%r0,%r1
	mtrin	3,6
	andi.	%r8,%r8,0x400		# Rc bit set?
	beq	return
	li	%r0,0xf0		# clear CR6 image in r30
	andc	%r30,%r30,%r0
	or.	%r0,%r2,%r3
	and	%r1,%r2,%r3
	cmpdi	%cr1,%r1,-1
	mfcr	%r0
	rlwimi	%r30,%r0,8,0x20		# cr0.eq -> cr6 bit 2 (BE numbering)
	rlwimi	%r30,%r0,14,0x80	# cr1.eq -> cr6 bit 0 (BE numbering)
	b	return

do_vcmpequh:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfrin	0,4
	mfrin	1,5
	lis	%r9,0xff
	addi	%r9,%r9,0xff
	rldimi	%r9,%r9,32,0
	cmpb	%r2,%r0,%r1
	srdi	%r10,%r2,8
	and	%r10,%r10,%r9
	and	%r2,%r2,%r10
	sldi	%r10,%r2,8
	or	%r2,%r2,%r10
	mtrin	2,6
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	cmpb	%r3,%r0,%r1
	srdi	%r10,%r3,8
	and	%r10,%r10,%r9
	and	%r3,%r3,%r10
	sldi	%r10,%r3,8
	or	%r3,%r3,%r10
	mtrin	3,6
	andi.	%r8,%r8,0x400		# Rc bit set?
	beq	return
	li	%r0,0xf0		# clear CR6 image in r30
	andc	%r30,%r30,%r0
	or.	%r0,%r2,%r3
	and	%r1,%r2,%r3
	cmpdi	%cr1,%r1,-1
	mfcr	%r0
	rlwimi	%r30,%r0,8,0x20		# cr0.eq -> cr6 bit 2 (BE numbering)
	rlwimi	%r30,%r0,14,0x80	# cr1.eq -> cr6 bit 0 (BE numbering)
	b	return

do_vcmpequw:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfrin	0,4
	mfrin	1,5
	cmpw	%r0,%r1
	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	setnbc	%r2,EQ
	cmpw	%r0,%r1
	setnbc	%r9,EQ
	rldimi	%r2,%r9,32,0
	mtrin	2,6
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	cmpw	%r0,%r1
	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	setnbc	%r3,EQ
	cmpw	%r0,%r1
	setnbc	%r9,EQ
	rldimi	%r3,%r9,32,0
	mtrin	3,6
	andi.	%r8,%r8,0x400		# Rc bit set?
	beq	return
	li	%r0,0xf0		# clear CR6 image in r30
	andc	%r30,%r30,%r0
	or.	%r0,%r2,%r3
	and	%r1,%r2,%r3
	cmpdi	%cr1,%r1,-1
	mfcr	%r0
	rlwimi	%r30,%r0,8,0x20		# cr0.eq -> cr6 bit 2 (BE numbering)
	rlwimi	%r30,%r0,14,0x80	# cr1.eq -> cr6 bit 0 (BE numbering)
	b	return

do_vcmpequd:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfrin	0,4
	mfrin	1,5
	cmpd	%r0,%r1
	setnbc	%r2,EQ
	mtrin	2,6
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	cmpd	%r0,%r1
	setnbc	%r3,EQ
	mtrin	3,6
	andi.	%r8,%r8,0x400		# Rc bit set?
	beq	return
	li	%r0,0xf0		# clear CR6 image in r30
	andc	%r30,%r30,%r0
	or.	%r0,%r2,%r3
	and	%r1,%r2,%r3
	cmpdi	%cr1,%r1,-1
	mfcr	%r0
	rlwimi	%r30,%r0,8,0x20		# cr0.eq -> cr6 bit 2 (BE numbering)
	rlwimi	%r30,%r0,14,0x80	# cr1.eq -> cr6 bit 0 (BE numbering)
	b	return

do_vcmpequq:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfrin	0,4
	mfrin	1,5
	cmpd	%r0,%r1
	bne	2f
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	mfrin	0,4
	mfrin	1,5
	cmpd	%r0,%r1
2:	setnbc	%r7,EQ
	mtrin	7,6
	b	return

do_vcmpgtub:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,8
	mtctr	%r11
2:	clrrdi	%r2,%r0,56
	clrrdi	%r3,%r1,56
	cmpld	%r2,%r3
	sldi	%r0,%r0,8
	sldi	%r1,%r1,8
	sldi	%r7,%r7,8
	setnbc	%r3,GT
	rldimi	%r7,%r3,0,56
	bdnz	2b
	mtrin	7,6
	andi.	%r0,%r4,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtsb:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,8
	mtctr	%r11
2:	clrrdi	%r2,%r0,56
	clrrdi	%r3,%r1,56
	cmpd	%r2,%r3
	sldi	%r0,%r0,8
	sldi	%r1,%r1,8
	sldi	%r7,%r7,8
	setnbc	%r3,GT
	rldimi	%r7,%r3,0,56
	bdnz	2b
	mtrin	7,6
	andi.	%r0,%r4,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtuh:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,4
	mtctr	%r11
2:	clrrdi	%r2,%r0,48
	clrrdi	%r3,%r1,48
	cmpld	%r2,%r3
	sldi	%r0,%r0,16
	sldi	%r1,%r1,16
	sldi	%r7,%r7,16
	setnbc	%r3,GT
	rldimi	%r7,%r3,0,48
	bdnz	2b
	mtrin	7,6
	andi.	%r0,%r4,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtsh:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,4
	mtctr	%r11
2:	clrrdi	%r2,%r0,48
	clrrdi	%r3,%r1,48
	cmpd	%r2,%r3
	sldi	%r0,%r0,16
	sldi	%r1,%r1,16
	sldi	%r7,%r7,16
	setnbc	%r3,GT
	rldimi	%r7,%r3,0,48
	bdnz	2b
	mtrin	7,6
	andi.	%r0,%r4,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtuw:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,2
	mtctr	%r11
2:	clrrdi	%r2,%r0,32
	clrrdi	%r3,%r1,32
	cmpld	%r2,%r3
	sldi	%r0,%r0,32
	sldi	%r1,%r1,32
	sldi	%r7,%r7,32
	setnbc	%r3,GT
	rldimi	%r7,%r3,0,32
	bdnz	2b
	mtrin	7,6
	andi.	%r0,%r4,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtsw:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,2
	mtctr	%r11
2:	clrrdi	%r2,%r0,32
	clrrdi	%r3,%r1,32
	cmpd	%r2,%r3
	sldi	%r0,%r0,32
	sldi	%r1,%r1,32
	sldi	%r7,%r7,32
	setnbc	%r3,GT
	rldimi	%r7,%r3,0,32
	bdnz	2b
	mtrin	7,6
	andi.	%r0,%r4,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtud:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	cmpld	%r0,%r1
	setnbc	%r7,GT
	mtrin	7,6
	andi.	%r0,%r4,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtsd:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	cmpd	%r0,%r1
	setnbc	%r7,GT
	mtrin	7,6
	andi.	%r0,%r4,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtuq:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfrin	0,4
	mfrin	1,5
	cmpld	%r0,%r1
	bne	2f
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	mfrin	0,4
	mfrin	1,5
	cmpld	%r0,%r1
2:	setnbc	%r7,GT
	mtrin	7,6
	b	return

do_vcmpgtsq:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfrin	0,4
	mfrin	1,5
	cmpd	%r0,%r1
	bne	2f
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	mfrin	0,4
	mfrin	1,5
	cmpld	%r0,%r1
2:	setnbc	%r7,GT
	mtrin	7,6
	b	return

do_vcmpneb:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfrin	0,4
	mfrin	1,5
	cmpb	%r2,%r0,%r1
	not	%r2,%r2
	mtrin	2,6
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	cmpb	%r3,%r0,%r1
	not	%r3,%r3
	mtrin	3,6
	andi.	%r8,%r8,0x400		# Rc bit set?
	beq	return
	li	%r0,0xf0		# clear CR6 image in r30
	andc	%r30,%r30,%r0
	or.	%r0,%r2,%r3
	and	%r1,%r2,%r3
	cmpdi	%cr1,%r1,-1
	mfcr	%r0
	rlwimi	%r30,%r0,8,0x20		# cr0.eq -> cr6 bit 2 (BE numbering)
	cmpb	%r3,%r1,%r9
	rlwimi	%r30,%r0,14,0x80	# cr1.eq -> cr6 bit 0 (BE numbering)
	b	return

do_vcmpnezb:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfrin	0,4
	mfrin	1,5
	li	%r9,0
	cmpb	%r7,%r0,%r1
	cmpb	%r2,%r0,%r9
	cmpb	%r10,%r1,%r9
	or	%r2,%r2,%r10
	orc	%r2,%r2,%r7
	mtrin	2,6
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	cmpb	%r7,%r0,%r1
	cmpb	%r3,%r0,%r9
	cmpb	%r10,%r1,%r9
	or	%r3,%r3,%r10
	orc	%r3,%r3,%r7
	mtrin	3,6
	andi.	%r8,%r8,0x400		# Rc bit set?
	beq	return
	li	%r0,0xf0		# clear CR6 image in r30
	andc	%r30,%r30,%r0
	or.	%r0,%r2,%r3
	and	%r1,%r2,%r3
	cmpdi	%cr1,%r1,-1
	mfcr	%r0
	rlwimi	%r30,%r0,8,0x20		# cr0.eq -> cr6 bit 2 (BE numbering)
	rlwimi	%r30,%r0,14,0x80	# cr1.eq -> cr6 bit 0 (BE numbering)
	b	return

do_vcmpneh:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mfrin	0,4
	mfrin	1,5
	lis	%r9,0xff
	addi	%r9,%r9,0xff
	rldimi	%r9,%r9,32,0
	cmpb	%r2,%r0,%r1
	srdi	%r10,%r2,8
	and	%r10,%r10,%r9
	and	%r2,%r2,%r10
	sldi	%r10,%r2,8
	nor	%r2,%r2,%r10
	mtrin	2,6
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	cmpb	%r3,%r0,%r1
	srdi	%r10,%r3,8
	and	%r10,%r10,%r9
	and	%r3,%r3,%r10
	sldi	%r10,%r3,8
	nor	%r3,%r3,%r10
	mtrin	3,6
	andi.	%r8,%r8,0x400		# Rc bit set?
	beq	return
	li	%r0,0xf0		# clear CR6 image in r30
	andc	%r30,%r30,%r0
	or.	%r0,%r2,%r3
	and	%r1,%r2,%r3
	cmpdi	%cr1,%r1,-1
	mfcr	%r0
	rlwimi	%r30,%r0,8,0x20		# cr0.eq -> cr6 bit 2 (BE numbering)
	rlwimi	%r30,%r0,14,0x80	# cr1.eq -> cr6 bit 0 (BE numbering)
	b	return

do_vcmpnezh:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	li	%r11,0
	lis	%r9,0xff
	addi	%r9,%r9,0xff
	rldimi	%r9,%r9,32,0
1:	mfrin	0,4
	mfrin	1,5
	cmpb	%r2,%r0,%r1
	cmpb	%r14,%r0,%r11
	cmpb	%r15,%r1,%r11
	srdi	%r10,%r14,8
	and	%r14,%r14,%r10
	srdi	%r10,%r15,8
	and	%r15,%r15,%r10
	srdi	%r10,%r2,8
	or	%r14,%r14,%r15
	orc	%r2,%r14,%r2
	and	%r2,%r2,%r9
	sldi	%r10,%r2,8
	or	%r2,%r2,%r10
	mtrin	2,6
	andi.	%r0,%r4,LO
	bne	2f
	mr	%r3,%r2
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b
	andi.	%r8,%r8,0x400		# Rc bit set?
	beq	return
	li	%r0,0xf0		# clear CR6 image in r30
	andc	%r30,%r30,%r0
	or.	%r0,%r2,%r3
	and	%r1,%r2,%r3
	cmpdi	%cr1,%r1,-1
	mfcr	%r0
	rlwimi	%r30,%r0,8,0x20		# cr0.eq -> cr6 bit 2 (BE numbering)
	rlwimi	%r30,%r0,14,0x80	# cr1.eq -> cr6 bit 0 (BE numbering)
	b	return

do_vcmpnew:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
1:	mfrin	0,4
	mfrin	1,5
	cmpw	%r0,%r1
	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	setnbcr	%r2,EQ
	cmpw	%r0,%r1
	setnbcr	%r9,EQ
	rldimi	%r2,%r9,32,0
	mtrin	2,6
	andi.	%r0,%r4,LO
	beq	2f
	mr	%r3,%r2
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b
2:	andi.	%r8,%r8,0x400		# Rc bit set?
	beq	return
	li	%r0,0xf0		# clear CR6 image in r30
	andc	%r30,%r30,%r0
	or.	%r0,%r2,%r3
	and	%r1,%r2,%r3
	cmpdi	%cr1,%r1,-1
	mfcr	%r0
	rlwimi	%r30,%r0,8,0x20		# cr0.eq -> cr6 bit 2 (BE numbering)
	rlwimi	%r30,%r0,14,0x80	# cr1.eq -> cr6 bit 0 (BE numbering)
	b	return

do_vcmpnezw:
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	li	%r11,0
1:	mfrin	0,4
	mfrin	1,5
	cmpw	%r0,%r1
	cmpw	%cr1,%r0,%r11
	cmpw	%cr2,%r1,%r11
	cror	1*4+EQ,1*4+EQ,2*4+EQ
	crorc	EQ,1*4+EQ,EQ
	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	setnbc	%r2,EQ
	cmpw	%r0,%r1
	cmpw	%cr1,%r0,%r11
	cmpw	%cr2,%r1,%r11
	cror	1*4+EQ,1*4+EQ,2*4+EQ
	crorc	EQ,1*4+EQ,EQ
	setnbc	%r9,EQ
	rldimi	%r2,%r9,32,0
	mtrin	2,6
	andi.	%r0,%r4,LO
	beq	2f
	mr	%r3,%r2
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b
2:	andi.	%r8,%r8,0x400		# Rc bit set?
	beq	return
	li	%r0,0xf0		# clear CR6 image in r30
	andc	%r30,%r30,%r0
	or.	%r0,%r2,%r3
	and	%r1,%r2,%r3
	cmpdi	%cr1,%r1,-1
	mfcr	%r0
	rlwimi	%r30,%r0,8,0x20		# cr0.eq -> cr6 bit 2 (BE numbering)
	rlwimi	%r30,%r0,14,0x80	# cr1.eq -> cr6 bit 0 (BE numbering)
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
