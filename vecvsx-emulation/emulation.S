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

	# VSCR bits (stored in high half of VRSAVE)
SAT	= 1
NJ	= 0x10000

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
	andi.	%r0,%r11,1			# LSB set => whole column is one op
	bne	1f
	lwzx	%r12,%r1,%r11
	cmpdi	%r12,0
	beq	illegal
	add	%r12,%r12,%r11
	andi.	%r0,%r12,1			# LSB set => use expanded opcode
	bne	2f
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mtctr	%r12
	bctr
1:	rlwinm	%r7,%r8,5+21,0x1f		# get C field from instruction
	addi	%r7,%r7,VR0
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mtctr	%r11
	bctr
2:	rlwinm	%r1,%r8,16+2,0x7c		# expanded opcode * 4
	clrrdi	%r12,%r12,1
	lwzx	%r11,%r1,%r12
	cmpdi	%r11,0
	beq	illegal
	add	%r11,%r11,%r12
	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
	mtctr	%r11
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

op4_table:
	.long	vcol0 - op4_table	# column 0
	.long	0
	.long	vcol2 - op4_table
	.long	vcol3 - op4_table
	.long	vcol4 - op4_table
	.long	0
	.long	vcol6 - op4_table
	.long	vcol7 - op4_table
	.long	0
	.long	0
	.long	0		# column 10
	.long	0
	.long	vcol12 - op4_table
	.long	0
	.long	vcol14 - op4_table
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# column 20
	.long	0
	.long	vcol22 - op4_table
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
	.long	do_vsel - op4_table + 1
	.long	do_vperm - op4_table + 1
	.long	do_vsldoi - op4_table + 1
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
	.long	do_vpermr - op4_table + 1
	.long	do_vaddeuqm - op4_table + 1		# column 60
	.long	do_vaddecuq - op4_table + 1
	.long	do_vsubeuqm - op4_table + 1
	.long	do_vsubecuq - op4_table + 1

vcol0:
	.long	do_vaddubm - vcol0		# row 0
	.long	do_vadduhm - vcol0
	.long	do_vadduwm - vcol0
	.long	do_vaddudm - vcol0
	.long	do_vadduqm - vcol0		# row 4
	.long	do_vaddcuq - vcol0
	.long	do_vaddcuw - vcol0
	.long	0
	.long	do_vaddubs - vcol0		# row 8
	.long	do_vadduhs - vcol0
	.long	do_vadduws - vcol0
	.long	0
	.long	do_vaddsbs - vcol0		# row 12
	.long	do_vaddshs - vcol0
	.long	do_vaddsws - vcol0
	.long	0
	.long	do_vsububm - vcol0		# row 16
	.long	do_vsubuhm - vcol0
	.long	do_vsubuwm - vcol0
	.long	do_vsubudm - vcol0
	.long	do_vsubuqm - vcol0		# row 20
	.long	do_vsubcuq - vcol0
	.long	do_vsubcuw - vcol0
	.long	0
	.long	do_vsububs - vcol0		# row 24
	.long	do_vsubuhs - vcol0
	.long	do_vsubuws - vcol0
	.long	0
	.long	do_vsubsbs - vcol0		# row 28
	.long	do_vsubshs - vcol0
	.long	do_vsubsws - vcol0
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
	.long	xpnd004_2 - vcol2 + 1
	.long	0
	.long	0
	.long	0
	.long	do_vclzb - vcol2
	.long	do_vclzh - vcol2
	.long	do_vclzw - vcol2		# row 30
	.long	do_vclzd - vcol2

vcol3:
	.long	0		# row 0
	.long	0
	.long	0
	.long	0
	.long	0		# row 4
	.long	0
	.long	0
	.long	0
	.long	0		# row 8
	.long	0
	.long	0
	.long	0
	.long	0		# row 12
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
	.long	do_vpopcntb - vcol3
	.long	do_vpopcnth - vcol3
	.long	do_vpopcntw - vcol3		# row 30
	.long	do_vpopcntd - vcol3

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
	.long	do_vclzdm - vcol4		# row 30
	.long	do_vctzdm - vcol4

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

vcol12:
	.long	do_vmrghb - vcol12		# row 0
	.long	do_vmrghh - vcol12
	.long	do_vmrghw - vcol12
	.long	0
	.long	do_vmrglb - vcol12
	.long	do_vmrglh - vcol12
	.long	do_vmrglw - vcol12
	.long	0
	.long	do_vspltb - vcol12
	.long	do_vsplth - vcol12
	.long	do_vspltw - vcol12		# row 10
	.long	0
	.long	do_vspltisb - vcol12
	.long	do_vspltish - vcol12
	.long	do_vspltisw - vcol12
	.long	0
	.long	do_vslo - vcol12
	.long	do_vsro - vcol12
	.long	0
	.long	0
	.long	do_vgbbd - vcol12		# row 20
	.long	do_vbpermq - vcol12
	.long	0
	.long	do_vbpermd - vcol12
	.long	0
	.long	0
	.long	do_vmrgow - vcol12
	.long	0
	.long	0
	.long	0
	.long	do_vmrgew - vcol12		# row 30
	.long	0

vcol14:
	.long	do_vpkuhum - vcol14		# row 0
	.long	do_vpkuwum - vcol14
	.long	do_vpkuhus - vcol14
	.long	do_vpkuwus - vcol14
	.long	do_vpkshus - vcol14
	.long	do_vpkswus - vcol14
	.long	do_vpkshss - vcol14
	.long	do_vpkswss - vcol14
	.long	do_vupkhsb - vcol14
	.long	do_vupkhsh - vcol14
	.long	do_vupklsb - vcol14		# row 10
	.long	do_vupklsh - vcol14
	.long	do_vpkpx - vcol14
	.long	do_vupkhpx - vcol14
	.long	0
	.long	do_vupklpx - vcol14
	.long	0
	.long	do_vpkudum - vcol14
	.long	0
	.long	do_vpkudus - vcol14
	.long	0		# row 20
	.long	do_vpksdus - vcol14
	.long	0
	.long	do_vpksdss - vcol14
	.long	0
	.long	do_vupkhsw - vcol14
	.long	0
	.long	do_vupklsw - vcol14
	.long	0
	.long	0
	.long	0		# row 30
	.long	0

vcol22:
	.long	do_vsldbi - vcol22	# row 0
	.long	do_vsldbi - vcol22
	.long	do_vsldbi - vcol22
	.long	do_vsldbi - vcol22
	.long	do_vsldbi - vcol22
	.long	do_vsldbi - vcol22
	.long	do_vsldbi - vcol22
	.long	do_vsldbi - vcol22
	.long	0			# row 8
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	do_vsrdbi - vcol22	# row 16
	.long	do_vsrdbi - vcol22
	.long	do_vsrdbi - vcol22
	.long	do_vsrdbi - vcol22
	.long	do_vsrdbi - vcol22
	.long	do_vsrdbi - vcol22
	.long	do_vsrdbi - vcol22
	.long	do_vsrdbi - vcol22
	.long	0			# row 24
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0

xpnd004_2:
	.long	do_vclzlsbb - xpnd004_2		# row 0
	.long	do_vctzlsbb - xpnd004_2
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# row 8
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# row 16
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# row 24
	.long	0
	.long	0
	.long	0
	.long	do_vctzb - xpnd004_2
	.long	do_vctzh - xpnd004_2
	.long	do_vctzw - xpnd004_2
	.long	do_vctzd - xpnd004_2
	
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

do_vupklpx:
	addi	%r5,%r5,LO
do_vupkhpx:
	mfrin	1,5
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r1,%r1,16
	sldi	%r2,%r2,32
	rlwinm	%r0,%r1,9,0x1000000
	neg	%r0,%r0
	rlwimi	%r0,%r1,6,0x1f0000
	rlwimi	%r0,%r1,3,0x1f00
	rlwimi	%r0,%r1,0,0x1f
	rldimi	%r2,%r0,0,32
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	addi	%r6,%r6,LO
	beq	1b
	b	return

do_vmaxsb:
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
	mfspr	%r1,VRSAVE
	srdi	%r1,%r1,32
	lis	%r3,NJ@h		# NJ bit
	addi	%r3,%r3,SAT		# SAT bit
	and	%r1,%r1,%r3		# clear all other bits
	li	%r0,0
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return

do_mtvscr:
	addi	%r5,%r5,LO
	mfrin	1,5
	mfspr	%r0,VRSAVE
	rldimi	%r0,%r1,32,0
	mtspr	VRSAVE,%r0
	b	return

do_vcmpequb:
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

do_vmrglb:
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
do_vmrghb:
	mfrin	0,4
	mfrin	1,5
	li	%r11,4
1:	mtctr	%r11
2:	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	rotldi	%r2,%r2,16
	rldimi	%r2,%r0,8,48
	rldimi	%r2,%r1,0,56
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	addi	%r6,%r6,LO
	beq	1b
	b	return

do_vmrglh:
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
do_vmrghh:
	mfrin	0,4
	mfrin	1,5
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r2,%r2,32
	rldimi	%r2,%r0,16,32
	rldimi	%r2,%r1,0,48
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	addi	%r6,%r6,LO
	beq	1b
	b	return

do_vmrglw:
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
do_vmrghw:
	mfrin	0,4
	mfrin	1,5
1:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	rldimi	%r1,%r0,32,0
	mtrin	1,6
	andi.	%r0,%r6,LO
	addi	%r6,%r6,LO
	beq	1b
	b	return

do_vmrgew:
1:	mfrin	0,4
	mfrin	1,5
	rotldi	%r1,%r1,32
	rldimi	%r0,%r1,0,32
	mtrin	0,6
	andi.	%r0,%r4,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vmrgow:
1:	mfrin	0,4
	mfrin	1,5
	rldimi	%r1,%r0,32,0
	mtrin	1,6
	andi.	%r0,%r4,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vspltb:
	rlwimi	%r5,%r8,12-26+32,LO	# instr bit 12 (BE) -> LO bit
	rlwinm	%r1,%r8,15-28+32,0x38	# rest of UIM field -> bit shift count
	xori	%r1,%r1,0x38
	mfrin	0,5
	srd	%r0,%r0,%r1
	rlwimi	%r0,%r0,8,0xff00
	rlwimi	%r0,%r0,16,0xffff0000
	rldimi	%r0,%r0,32,0
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	0,6
	b	return

do_vsplth:
	rlwimi	%r5,%r8,13-26+32,LO	# instr bit 13 (BE) -> LO bit
	rlwinm	%r1,%r8,15-27+32,0x30	# rest of UIM field -> bit shift count
	xori	%r1,%r1,0x30
	mfrin	0,5
	rlwimi	%r0,%r0,16,0xffff0000
	rldimi	%r0,%r0,32,0
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	0,6
	b	return

do_vspltw:
	rlwimi	%r5,%r8,14-26+32,LO	# instr bit 14 (BE) -> LO bit
	rlwinm	%r1,%r8,15-26+32,0x20	# rest of UIM field -> bit shift count
	xori	%r1,%r1,0x20
	mfrin	0,5
	rldimi	%r0,%r0,32,0
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	0,6
	b	return

do_vspltisb:
	rlwinm	%r1,%r8,15-31+32,0xf	# extract the bottom 4 bits of SIM
	rlwinm	%r2,%r8,11-27+32,0x10	# extract the sign bit
	subf	%r0,%r2,%r1
	rlwimi	%r0,%r0,8,0xff00
	rlwimi	%r0,%r0,16,0xffff0000
	rldimi	%r0,%r0,32,0
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	0,6
	b	return

do_vspltish:
	rlwinm	%r1,%r8,15-31+32,0xf	# extract the bottom 4 bits of SIM
	rlwinm	%r2,%r8,11-27+32,0x10	# extract the sign bit
	subf	%r0,%r2,%r1
	rlwimi	%r0,%r0,16,0xffff0000
	rldimi	%r0,%r0,32,0
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	0,6
	b	return

do_vspltisw:
	rlwinm	%r1,%r8,15-31+32,0xf	# extract the bottom 4 bits of SIM
	rlwinm	%r2,%r8,11-27+32,0x10	# extract the sign bit
	subf	%r0,%r2,%r1
	rldimi	%r0,%r0,32,0
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	0,6
	b	return

do_vslo:
	addi	%r5,%r5,LO
	mfrin	1,5
	andi.	%r2,%r1,0x38		# bit shift count within doubleword
	andi.	%r3,%r1,0x40		# high bit of shift count
	bne	1f
	mfrin	0,4			# shifting 0 - 63 bits left
	addi	%r4,%r4,LO
	mfrin	1,4
	rotld	%r1,%r1,%r2
	b	2f
1:	addi	%r4,%r4,LO		# shifting 64 - 127 bits left
	mfrin	0,4
	li	%r1,0
2:	sld	%r0,%r0,%r2
	li	%r3,-1
	sld	%r3,%r3,%r2
	andc	%r9,%r1,%r3
	or	%r0,%r0,%r9
	and	%r1,%r1,%r3
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return

do_vsro:
	addi	%r5,%r5,LO
	mfrin	1,5
	andi.	%r2,%r1,0x38		# bit shift count within doubleword
	andi.	%r9,%r1,0x40		# high bit of shift count
	bne	1f
	mfrin	0,4			# shifting 0 - 63 bits right
	addi	%r4,%r4,LO
	mfrin	1,4
	li	%r10,64
	subf	%r10,%r2,%r10		# right shift count -> left rotate count
	rotld	%r0,%r0,%r10
	b	2f
1:	mfrin	1,4			# shifting 64 - 127 bits right
	li	%r0,0
2:	srd	%r1,%r1,%r2
	li	%r3,-1
	srd	%r3,%r3,%r2
	andc	%r9,%r0,%r3
	or	%r1,%r1,%r9
	and	%r0,%r0,%r3
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return

do_vgbbd:
1:	mfrin	1,5
	# 8x8 transpose of the bits in r1 is done in 3 steps
	# 1: swap top-right (TR) and bottom-left (BL) 4x4 blocks
	li	%r2,0
	oris	%r2,%r2,0xf0f0
	ori	%r2,%r2,0xf0f0		# mask of BL bits
	srdi	%r0,%r1,28		# shift TR bits into BL positions
	xor	%r3,%r0,%r1		# bits that differ
	and	%r3,%r3,%r2
	sldi	%r0,%r3,28
	or	%r0,%r0,%r3		# change both TR and BL
	xor	%r1,%r1,%r0
	# 2: swap TR and BL 2x2 blocks in each 4x4 block
	li	%r2,0
	ori	%r2,%r2,0xcccc
	rldimi	%r2,%r2,32,0
	srdi	%r0,%r1,14
	xor	%r3,%r0,%r1
	and	%r3,%r3,%r2
	sldi	%r0,%r3,14
	or	%r0,%r0,%r3
	xor	%r1,%r1,%r0
	# 3: swap TR and BL 1x1 blocks in each 2x2 block
	li	%r2,0xaa
	ori	%r2,%r2,0xaa
	rldimi	%r2,%r2,32,0
	srdi	%r0,%r1,7
	xor	%r3,%r0,%r1
	and	%r3,%r3,%r2
	sldi	%r0,%r3,7
	or	%r0,%r0,%r3
	xor	%r1,%r1,%r0
	mtrin	1,6
	andi.	%r0,%r5,LO
	bne	return
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vbpermd:
	li	%r9,8
1:	mfrin	0,4
	mfrin	1,5
	rotldi	%r0,%r0,1
	li	%r2,0
	mtctr	%r9
2:	rotldi	%r1,%r1,8
	clrldi	%r3,%r1,56
	sldi	%r2,%r2,1
	cmpdi	%r3,64
	bge	3f
	rotld	%r3,%r0,%r3
	rldimi	%r2,%r3,0,63
3:	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r4,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vbpermq:
	li	%r9,8
	mfrin	1,4
	addi	%r4,%r4,LO
	mfrin	2,4
	rotldi	%r1,%r1,1
	rotldi	%r2,%r2,1
	li	%r3,0
1:	mfrin	0,5
	mtctr	%r9
2:	rotldi	%r0,%r0,8
	mtcrf	0x02,%r0
	sldi	%r3,%r3,1
	isel	%r8,%r2,%r1,25		# use r2 if 0x40 bit of r0 is set else r1
	isel	%r8,0,%r8,24		# use 0 if 0x80 bit of r0 is set
	rotld	%r8,%r8,%r0
	rldimi	%r3,%r8,0,63
	bdnz	2b
	andi.	%r0,%r5,LO
	ori	%r5,%r5,LO
	beq	1b
3:	mtrin	3,6
	addi	%r6,%r6,LO
	li	%r0,0
	mtrin	0,6
	b	return

do_vpkuhum:
	li	%r11,4
1:	li	%r2,0
	mfrin	0,4
	addi	%r4,%r4,LO
	mfrin	1,4
	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r2,%r2,8
	rldimi	%r2,%r0,32,24
	rldimi	%r2,%r1,0,56
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	mr	%r4,%r5
	ori	%r6,%r6,LO
	b	1b

do_vpkuhus:
	li	%r11,4
	li	%r7,255
	crclr	31
1:	li	%r1,0
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mtctr	%r11
2:	rotldi	%r1,%r1,8
	rotldi	%r2,%r2,16
	andi.	%r8,%r2,0xff00
	crorc	31,31,EQ
	isel	%r8,%r2,%r7,EQ
	rldimi	%r1,%r8,32,24
	rotldi	%r3,%r3,16
	andi.	%r8,%r3,0xff00
	cror	31,31,EQ
	isel	%r8,%r3,%r7,EQ
	rldimi	%r1,%r3,0,56
	bdnz	2b
	mtrin	1,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	mr	%r4,%r5
	ori	%r6,%r6,LO
	b	1b

do_vpkuwum:
	li	%r11,2
1:	li	%r2,0
	mfrin	0,4
	addi	%r4,%r4,LO
	mfrin	1,4
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	rotldi	%r2,%r2,16
	rldimi	%r2,%r0,32,16
	rldimi	%r2,%r1,0,48
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	mr	%r4,%r5
	ori	%r6,%r6,LO
	b	1b

do_vpkuwus:
	li	%r11,2
	li	%r7,0
	ori	%r7,%r7,0xffff
	crclr	31
1:	li	%r1,0
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mtctr	%r11
2:	rotldi	%r1,%r1,16
	rotldi	%r2,%r2,32
	andis.	%r8,%r2,0xffff
	crorc	31,31,EQ
	isel	%r8,%r2,%r7,EQ
	rldimi	%r1,%r8,32,16
	rotldi	%r3,%r3,32
	andis.	%r8,%r3,0xffff
	crorc	31,31,EQ
	isel	%r8,%r3,%r7,EQ
	rldimi	%r1,%r3,0,48
	bdnz	2b
	mtrin	1,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	mr	%r4,%r5
	ori	%r6,%r6,LO
	b	1b

do_vpkshus:
	li	%r11,4
	li	%r12,255
	li	%r9,0
	crclr	31
1:	li	%r1,0
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mtctr	%r11
2:	rotldi	%r1,%r1,8
	rotldi	%r2,%r2,16
	extsh	%r0,%r2
	cmpdi	%r0,255
	cmpdi	%cr1,%r0,0
	cror	31,31,GT
	isel	%r8,%r12,%r2,GT
	cror	31,31,4*1+LT
	isel	%r8,0,%r8,4*1+LT
	rldimi	%r1,%r8,32,24
	rotldi	%r3,%r3,16
	extsh	%r0,%r3
	cmpdi	%r0,255
	cmpdi	%cr1,%r0,0
	cror	31,31,GT
	isel	%r8,%r12,%r3,GT
	cror	31,31,4*1+LT
	isel	%r8,0,%r8,4*1+LT
	rldimi	%r1,%r3,0,56
	bdnz	2b
	mtrin	1,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	mr	%r4,%r5
	ori	%r6,%r6,LO
	b	1b

do_vpkshss:
	li	%r11,4
	li	%r12,127
	li	%r13,-128
	li	%r9,0
	crclr	31
1:	li	%r1,0
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mtctr	%r11
2:	rotldi	%r1,%r1,8
	rotldi	%r2,%r2,16
	extsh	%r0,%r2
	cmpdi	%r0,127
	cmpdi	%cr1,%r0,-128
	cror	31,31,GT
	isel	%r8,%r12,%r2,GT
	cror	31,31,4*1+LT
	isel	%r8,%r13,%r8,4*1+LT
	rldimi	%r1,%r8,32,24
	rotldi	%r3,%r3,16
	extsh	%r0,%r3
	cmpdi	%r0,127
	cmpdi	%cr1,%r0,-128
	cror	31,31,GT
	isel	%r8,%r12,%r3,GT
	cror	31,31,4*1+LT
	isel	%r8,%r13,%r8,4*1+LT
	rldimi	%r1,%r3,0,56
	bdnz	2b
	mtrin	1,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	mr	%r4,%r5
	ori	%r6,%r6,LO
	b	1b

do_vpkswus:
	li	%r11,2
	li	%r12,0
	ori	%r12,%r12,65535
	li	%r9,0
	crclr	31
1:	li	%r1,0
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mtctr	%r11
2:	rotldi	%r1,%r1,16
	rotldi	%r2,%r2,32
	extsw	%r0,%r2
	cmpd	%r0,%r12
	cmpdi	%cr1,%r0,0
	cror	31,31,GT
	isel	%r8,%r12,%r2,GT
	cror	31,31,4*1+LT
	isel	%r8,0,%r8,4*1+LT
	rldimi	%r1,%r8,32,16
	rotldi	%r3,%r3,32
	extsw	%r0,%r3
	cmpd	%r0,%r12
	cmpdi	%cr1,%r0,0
	cror	31,31,GT
	isel	%r8,%r12,%r3,GT
	cror	31,31,4*1+LT
	isel	%r8,0,%r8,4*1+LT
	rldimi	%r1,%r3,0,48
	bdnz	2b
	mtrin	1,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	mr	%r4,%r5
	ori	%r6,%r6,LO
	b	1b

do_vpkswss:
	li	%r11,2
	ori	%r12,%r12,32767
	li	%r13,-32768
	li	%r9,0
	crclr	31
1:	li	%r1,0
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mtctr	%r11
2:	rotldi	%r1,%r1,16
	rotldi	%r2,%r2,32
	extsw	%r0,%r2
	cmpdi	%r0,32767
	cmpdi	%cr1,%r0,-32768
	cror	31,31,GT
	isel	%r8,%r12,%r2,GT
	cror	31,31,4*1+LT
	isel	%r8,%r13,%r8,4*1+LT
	rldimi	%r1,%r8,32,16
	rotldi	%r3,%r3,32
	extsw	%r0,%r3
	cmpdi	%r0,32767
	cmpdi	%cr1,%r0,-32768
	cror	31,31,GT
	isel	%r8,%r12,%r3,GT
	cror	31,31,4*1+LT
	isel	%r8,%r13,%r8,4*1+LT
	rldimi	%r1,%r3,0,48
	bdnz	2b
	mtrin	1,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	mr	%r4,%r5
	ori	%r6,%r6,LO
	b	1b

do_vpkudum:
1:	mfrin	0,4
	addi	%r4,%r4,LO
	mfrin	1,4
	rldimi	%r1,%r0,0,32
	mtrin	1,6
	andi.	%r0,%r6,LO
	bne	return
	mr	%r4,%r5
	ori	%r6,%r6,LO
	b	1b

do_vpkudus:
	li	%r12,-1
	clrldi	%r12,%r12,32
	crclr	31
1:	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	cmpld	%r2,%r12
	cror	31,31,GT
	isel	%r0,%r12,%r2,GT
	cmpld	%r3,%r12
	cror	31,31,GT
	isel	%r1,%r12,%r3,GT
	rldimi	%r1,%r0,32,0
	mtrin	1,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	mr	%r4,%r5
	ori	%r6,%r6,LO
	b	1b

do_vpksdus:
	li	%r12,-1
	clrldi	%r12,%r12,32
	crclr	31
1:	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	cmpd	%r2,%r12
	cmpdi	%cr1,%r2,0
	cror	31,31,GT
	isel	%r8,%r12,%r2,GT
	cror	31,31,4*1+LT
	isel	%r8,0,%r8,4*1+LT
	cmpd	%r3,%r12
	cmpdi	%cr1,%r3,0
	cror	31,31,GT
	isel	%r9,%r12,%r3,GT
	cror	31,31,4*1+LT
	isel	%r9,0,%r9,4*1+LT
	rldimi	%r9,%r8,32,0
	mtrin	9,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	mr	%r4,%r5
	ori	%r6,%r6,LO
	b	1b

do_vpksdss:
	lis	%r13,-32768
	not	%r12,%r13
	crclr	31
1:	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	cmpd	%r2,%r12
	cmpd	%cr1,%r2,%r13
	cror	31,31,GT
	isel	%r8,%r12,%r2,GT
	cror	31,31,4*1+LT
	isel	%r8,%r13,%r8,4*1+LT
	cmpd	%r3,%r12
	cmpd	%cr1,%r3,%r13
	cror	31,31,GT
	isel	%r9,%r12,%r3,GT
	cror	31,31,4*1+LT
	isel	%r9,%r13,%r9,4*1+LT
	rldimi	%r9,%r8,32,0
	mtrin	9,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	mr	%r4,%r5
	ori	%r6,%r6,LO
	b	1b

do_vupklsb:
	addi	%r5,%r5,LO
do_vupkhsb:
	li	%r11,4
1:	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r1,%r1,8
	rotldi	%r2,%r2,16
	extsb	%r0,%r1
	rldimi	%r2,%r0,0,48
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	addi	%r6,%r6,LO
	beq	1b
	b	return

do_vupklsh:
	addi	%r5,%r5,LO
do_vupkhsh:
	li	%r11,2
1:	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r1,%r1,16
	rotldi	%r2,%r2,32
	extsh	%r0,%r1
	rldimi	%r2,%r0,0,32
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	addi	%r6,%r6,LO
	beq	1b
	b	return

do_vupklsw:
	addi	%r5,%r5,LO
do_vupkhsw:
	mfrin	1,5
1:	rotldi	%r1,%r1,32
	extsw	%r0,%r1
	mtrin	0,6
	andi.	%r0,%r6,LO
	addi	%r6,%r6,LO
	beq	1b
	b	return

do_vsel:
1:	mfrin	0,4
	mfrin	1,5
	mfrin	2,7
	andc	%r0,%r0,%r2
	and	%r1,%r1,%r2
	or	%r0,%r1,%r0
	mtrin	0,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	addi	%r7,%r7,LO
	b	1b

do_vperm:
	mfrin	8,4
	mfrin	10,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	9,4
	mfrin	11,5
	li	%r3,8
1:	mfrin	1,7
	mtctr	%r3
	sldi	%r1,%r1,3
	li	%r2,0
2:	rldicr	%r1,%r1,8,60
	mtcrf	0x02,%r1
	isel	%r12,%r10,%r8,24
	isel	%r13,%r11,%r9,24
	isel	%r0,%r13,%r12,25
	rldcr	%r0,%r0,%r1,7
	or	%r2,%r2,%r0
	rotldi	%r2,%r2,8
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	addi	%r6,%r6,LO
	addi	%r7,%r7,LO
	beq	1b
	b	return

do_vpermr:
	mfrin	8,4
	mfrin	10,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	9,4
	mfrin	11,5
	li	%r3,8
1:	mfrin	1,7
	mtctr	%r3
	sldi	%r1,%r1,3
	li	%r2,0
2:	rldicr	%r1,%r1,8,60
	mtcrf	0x02,%r1
	isel	%r12,%r8,%r10,24
	isel	%r13,%r9,%r11,24
	isel	%r0,%r12,%r13,25
	srd	%r0,%r0,%r1
	rldimi	%r2,%r0,56,0
	rotldi	%r2,%r2,8
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	addi	%r6,%r6,LO
	addi	%r7,%r7,LO
	beq	1b
	b	return

do_vsldoi:
	andi.	%r0,%r8,0x200		# test MSB of SHB
	addi	%r7,%r4,LO
	bne	1f
	mfrin	0,4			# SHB <= 7, get left 3 dwords
	mfrin	1,7
	b	2f
1:	mfrin	0,7
	mfrin	1,5
	addi	%r5,%r5,LO
2:	rlwinm.	%r8,%r8,32-3,0x38	# extract SHB * 8
4:	beq	3f
	mfrin	2,5
	neg	%r3,%r8
	clrldi	%r3,%r3,58
	sld	%r0,%r0,%r8
	srd	%r9,%r1,%r3
	or	%r0,%r0,%r9
	sld	%r1,%r1,%r8
	srd	%r2,%r2,%r3
	or	%r1,%r1,%r2
3:	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return

do_vsldbi:
	mfrin	0,4
	addi	%r4,%r4,LO
	mfrin	1,4
	rlwinm.	%r8,%r8,32-6,7		# extract SH
	b	4b

do_vsrdbi:
	mfrin	0,5
	addi	%r5,%r5,LO
	mfrin	1,5
	rlwinm.	%r8,%r5,32-6,7		# extract SH
	beq	3f
	addi	%r4,%r4,LO
	mfrin	2,4
	neg	%r9,%r8
	clrldi	%r9,%r9,58
	srd	%r1,%r1,%r8
	sld	%r3,%r0,%r9
	or	%r1,%r1,%r3
	srd	%r0,%r0,%r8
	srd	%r2,%r2,%r9
	or	%r0,%r0,%r2
3:	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return

do_vaddubm:
	li	%r11,8
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	add	%r1,%r0,%r1
	rotldi	%r8,%r8,8
	rldimi	%r8,%r1,0,56
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vadduhm:
	li	%r11,4
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	add	%r1,%r0,%r1
	rotldi	%r8,%r8,16
	rldimi	%r8,%r1,0,48
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vadduwm:
	li	%r11,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	add	%r1,%r0,%r1
	rotldi	%r8,%r8,32
	rldimi	%r8,%r1,0,32
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vaddcuw:
	li	%r11,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	clrldi	%r0,%r0,32
	clrldi	%r1,%r1,32
	add	%r1,%r0,%r1
	srdi	%r1,%r1,32
	rotldi	%r8,%r8,32
	rldimi	%r8,%r1,0,32
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vaddudm:
	mfrin	0,4
	mfrin	1,5
	add	%r1,%r0,%r1
	mtrin	1,6
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	add	%r1,%r0,%r1
	mtrin	1,6
	b	return

do_vadduqm:
	mfrin	0,4
	mfrin	2,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	1,4
	mfrin	3,5
	mfxer	%r29
	addc	%r3,%r1,%r3
	adde	%r2,%r0,%r2
	mtrin	2,6
	addi	%r6,%r6,LO
	mtrin	3,6
	mtxer	%r29
	b	return

do_vaddcuq:
	mfrin	0,4
	mfrin	2,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	1,4
	mfrin	3,5
	mfxer	%r29
	li	%r8,0
	addc	%r3,%r1,%r3
	adde	%r2,%r0,%r2
	addze	%r9,%r8
	mtrin	8,6
	addi	%r6,%r6,LO
	mtrin	9,6
	mtxer	%r29
	b	return

do_vaddubs:
	crclr	31
	li	%r11,8
	li	%r12,255
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	clrldi	%r2,%r0,56
	clrldi	%r3,%r1,56
	add	%r1,%r0,%r1
	andi.	%r0,%r1,0x100
	rotldi	%r8,%r8,8
	isel	%r1,%r1,%r12,EQ
	rldimi	%r8,%r1,0,56
	crorc	31,31,EQ
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vadduhs:
	crclr	31
	li	%r11,4
	li	%r12,-1
	clrldi	%r12,%r12,48
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	clrldi	%r2,%r0,48
	clrldi	%r3,%r1,48
	add	%r1,%r0,%r1
	andis.	%r0,%r1,1
	rotldi	%r8,%r8,16
	isel	%r1,%r1,%r12,EQ
	rldimi	%r8,%r1,0,48
	crorc	31,31,EQ
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vadduws:
	crclr	31
	li	%r11,2
	li	%r12,-1
	clrldi	%r12,%r12,32
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	clrldi	%r2,%r0,32
	clrldi	%r3,%r1,32
	add	%r1,%r0,%r1
	andis.	%r0,%r1,1
	rotldi	%r8,%r8,32
	isel	%r1,%r1,%r12,EQ
	rldimi	%r8,%r1,0,32
	crorc	31,31,EQ
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vaddsbs:
	crclr	31
	li	%r11,8
	li	%r12,127
	li	%r13,-128
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	clrldi	%r2,%r0,56
	clrldi	%r3,%r1,56
	add	%r1,%r0,%r1
	cmpd	%r1,%r12
	cmpd	%cr1,%r1,%r13
	rotldi	%r8,%r8,8
	isel	%r1,%r12,%r1,GT
	isel	%r1,%r13,%r1,4*1+LT
	rldimi	%r8,%r1,0,56
	cror	31,31,GT
	cror	31,31,4*1+LT
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vaddshs:
	crclr	31
	li	%r11,4
	li	%r12,32767
	li	%r13,-32768
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	clrldi	%r2,%r0,48
	clrldi	%r3,%r1,48
	add	%r1,%r0,%r1
	cmpd	%r1,%r12
	cmpd	%cr1,%r1,%r13
	rotldi	%r8,%r8,16
	isel	%r1,%r12,%r1,GT
	isel	%r1,%r13,%r1,4*1+LT
	rldimi	%r8,%r1,0,48
	cror	31,31,GT
	cror	31,31,4*1+LT
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vaddsws:
	crclr	31
	li	%r11,2
	lis	%r12,32767
	lis	%r13,-32768
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	clrldi	%r2,%r0,32
	clrldi	%r3,%r1,32
	add	%r1,%r0,%r1
	cmpd	%r1,%r12
	cmpd	%cr1,%r1,%r13
	rotldi	%r8,%r8,32
	isel	%r1,%r12,%r1,GT
	isel	%r1,%r13,%r1,4*1+LT
	rldimi	%r8,%r1,0,32
	cror	31,31,GT
	cror	31,31,4*1+LT
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vaddeuqm:
	mfrin	0,4
	mfrin	2,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r7,%r7,LO
	mfrin	1,4
	mfrin	3,5
	mfrin	8,7
	mfxer	%r29
	rlwinm	%r8,%r8,29,29,29	# get LSB of VRC into XER[CA]
	mtxer	%r8
	add	%r3,%r3,%r1
	add	%r2,%r2,%r0
	mtrin	2,6
	addi	%r6,%r6,LO
	mtrin	3,6
	mtxer	%r29
	b	return

do_vaddecuq:
	mfrin	0,4
	mfrin	2,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r7,%r7,LO
	mfrin	1,4
	mfrin	3,5
	mfrin	8,7
	mfxer	%r29
	rlwinm	%r8,%r8,29,29,29	# get LSB of VRC into XER[CA]
	mtxer	%r8
	li	%r8,0
	add	%r3,%r3,%r1
	add	%r2,%r2,%r0
	addze	%r9,%r8
	mtrin	8,6
	addi	%r6,%r6,LO
	mtrin	9,6
	mtxer	%r29
	b	return

do_vsububm:
	li	%r11,8
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	subf	%r1,%r1,%r0
	rotldi	%r8,%r8,8
	rldimi	%r8,%r1,0,56
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vsubuhm:
	li	%r11,4
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	subf	%r1,%r1,%r0
	rotldi	%r8,%r8,16
	rldimi	%r8,%r1,0,48
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vsubuwm:
	li	%r11,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	subf	%r1,%r1,%r0
	rotldi	%r8,%r8,32
	rldimi	%r8,%r1,0,32
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vsubcuw:
	li	%r11,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	clrldi	%r0,%r0,32
	clrldi	%r1,%r1,32
	subf	%r1,%r1,%r0
	srdi	%r1,%r1,32
	addi	%r1,%r1,1
	rotldi	%r8,%r8,32
	rldimi	%r8,%r1,0,32
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vsubudm:
	mfrin	0,4
	mfrin	1,5
	subf	%r1,%r1,%r0
	mtrin	1,6
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	subf	%r1,%r1,%r0
	mtrin	1,6
	b	return

do_vsubuqm:
	mfrin	0,4
	mfrin	2,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	1,4
	mfrin	3,5
	mfxer	%r29
	subfc	%r3,%r3,%r1
	subfe	%r2,%r2,%r0
	mtrin	2,6
	addi	%r6,%r6,LO
	mtrin	3,6
	mtxer	%r29
	b	return

do_vsubcuq:
	mfrin	0,4
	mfrin	2,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	1,4
	mfrin	3,5
	mfxer	%r29
	li	%r8,0
	subfc	%r3,%r3,%r1
	subfe	%r2,%r2,%r0
	addze	%r9,%r8
	mtrin	8,6
	addi	%r6,%r6,LO
	mtrin	9,6
	mtxer	%r29
	b	return

do_vsububs:
	crclr	31
	li	%r11,8
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	clrldi	%r2,%r0,56
	clrldi	%r3,%r1,56
	subf.	%r1,%r1,%r0
	rotldi	%r8,%r8,8
	isel	%r1,0,%r1,LT
	rldimi	%r8,%r1,0,56
	cror	31,31,LT
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vsubuhs:
	crclr	31
	li	%r11,4
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	clrldi	%r2,%r0,48
	clrldi	%r3,%r1,48
	subf.	%r1,%r1,%r0
	rotldi	%r8,%r8,16
	isel	%r1,0,%r1,LT
	rldimi	%r8,%r1,0,48
	cror	31,31,LT
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vsubuws:
	crclr	31
	li	%r11,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	clrldi	%r2,%r0,32
	clrldi	%r3,%r1,32
	subf.	%r1,%r1,%r0
	rotldi	%r8,%r8,32
	isel	%r1,0,%r1,LT
	rldimi	%r8,%r1,0,32
	cror	31,31,LT
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vsubsbs:
	crclr	31
	li	%r11,8
	li	%r12,127
	li	%r13,-128
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	clrldi	%r2,%r0,56
	clrldi	%r3,%r1,56
	subf	%r1,%r1,%r0
	cmpd	%r1,%r12
	cmpd	%cr1,%r1,%r13
	rotldi	%r8,%r8,8
	isel	%r1,%r12,%r1,GT
	isel	%r1,%r13,%r1,4*1+LT
	rldimi	%r8,%r1,0,56
	cror	31,31,GT
	cror	31,31,4*1+LT
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vsubshs:
	crclr	31
	li	%r11,4
	li	%r12,32767
	li	%r13,-32768
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	clrldi	%r2,%r0,48
	clrldi	%r3,%r1,48
	subf	%r1,%r1,%r0
	cmpd	%r1,%r12
	cmpd	%cr1,%r1,%r13
	rotldi	%r8,%r8,16
	isel	%r1,%r12,%r1,GT
	isel	%r1,%r13,%r1,4*1+LT
	rldimi	%r8,%r1,0,48
	cror	31,31,GT
	cror	31,31,4*1+LT
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vsubsws:
	crclr	31
	li	%r11,2
	lis	%r12,32767
	lis	%r13,-32768
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	clrldi	%r2,%r0,32
	clrldi	%r3,%r1,32
	subf	%r1,%r1,%r0
	cmpd	%r1,%r12
	cmpd	%cr1,%r1,%r13
	rotldi	%r8,%r8,32
	isel	%r1,%r12,%r1,GT
	isel	%r1,%r13,%r1,4*1+LT
	rldimi	%r8,%r1,0,32
	cror	31,31,GT
	cror	31,31,4*1+LT
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vsubeuqm:
	mfrin	0,4
	mfrin	2,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r7,%r7,LO
	mfrin	1,4
	mfrin	3,5
	mfrin	8,7
	mfxer	%r29
	rlwinm	%r8,%r8,29,29,29	# get LSB of VRC into XER[CA]
	mtxer	%r8
	subfe	%r3,%r3,%r1
	subfe	%r2,%r2,%r0
	mtrin	2,6
	addi	%r6,%r6,LO
	mtrin	3,6
	mtxer	%r29
	b	return

do_vsubecuq:
	mfrin	0,4
	mfrin	2,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r7,%r7,LO
	mfrin	1,4
	mfrin	3,5
	mfrin	8,7
	mfxer	%r29
	rlwinm	%r8,%r8,29,29,29	# get LSB of VRC into XER[CA]
	mtxer	%r8
	li	%r8,0
	subfe	%r3,%r3,%r1
	subfe	%r2,%r2,%r0
	addze	%r9,%r8
	mtrin	8,6
	addi	%r6,%r6,LO
	mtrin	9,6
	mtxer	%r29
	b	return

setsatif31:
	bf+	31,return
setsat:
	mfspr	%r12,VRSAVE
	li	%r9,SAT
	sldi	%r9,%r9,32
	or	%r12,%r12,%r9
	mtspr	VRSAVE,%r12
return:
	mtctr	%r30
	mfspr	%r1,HSRR0
	addi	%r1,%r1,4
	mtspr	HSRR0,%r1
	mtcr	%r31
	li	%r0,0
	mtspr	EMUC,%r0
	hrfid

do_vclzb:
	li	%r11,8
	li	%r12,1
	sldi	%r12,%r12,56
1:	mfrin	1,5
	li	%r2,0
	mtctr	%r11
2:	or	%r0,%r1,%r12
	cntlzd	%r0,%r0
	rotldi	%r1,%r1,8
	rotldi	%r2,%r2,8
	rldimi	%r2,%r0,0,56
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vclzh:
	li	%r11,4
	li	%r12,1
	sldi	%r12,%r12,48
1:	mfrin	1,5
	li	%r2,0
	mtctr	%r11
2:	or	%r0,%r1,%r12
	cntlzd	%r0,%r0
	rotldi	%r1,%r1,16
	rotldi	%r2,%r2,16
	rldimi	%r2,%r0,0,48
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vclzw:
1:	mfrin	1,5
	cntlzw	%r2,%r1
	rotldi	%r1,%r1,32
	cntlzw	%r0,%r1
	rldimi	%r2,%r0,0,32
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vclzd:
	mfrin	1,5
	cntlzd	%r2,%r1
	mtrin	2,6
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	1,5
	cntlzd	%r2,%r1
	mtrin	2,6
	b	return

do_vclzdm:
	mfrin	0,4
	mfrin	1,5
	cntlzdm	%r2,%r0,%r1
	mtrin	2,6
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	cntlzdm	%r2,%r0,%r1
	mtrin	2,6
	b	return

do_vctzb:
	li	%r11,8
	li	%r12,0x100
1:	mfrin	1,5
	li	%r2,0
	mtctr	%r11
2:	rotldi	%r1,%r1,8
	or	%r0,%r1,%r12
	cnttzd	%r0,%r0
	rotldi	%r2,%r2,8
	rldimi	%r2,%r0,0,56
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vctzh:
	li	%r11,4
	lis	%r12,1
1:	mfrin	1,5
	li	%r2,0
	mtctr	%r11
2:	rotldi	%r1,%r1,16
	or	%r0,%r1,%r12
	cnttzd	%r0,%r0
	rotldi	%r2,%r2,16
	rldimi	%r2,%r0,0,48
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vctzw:
1:	mfrin	1,5
	cnttzw	%r2,%r1
	rotldi	%r1,%r1,32
	cnttzw	%r0,%r1
	rldimi	%r2,%r0,0,32
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vctzd:
	mfrin	1,5
	cnttzd	%r2,%r1
	mtrin	2,6
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	1,5
	cnttzd	%r2,%r1
	mtrin	2,6
	b	return

do_vctzdm:
	mfrin	0,4
	mfrin	1,5
	cnttzdm	%r2,%r0,%r1
	mtrin	2,6
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	cnttzdm	%r2,%r0,%r1
	mtrin	2,6
	b	return

do_vpopcntb:
	mfrin	1,5
	popcntb	%r1,%r1
	mtrin	1,6
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	1,5
	popcntb	%r1,%r1
	mtrin	1,6
	b	return

do_vpopcnth:
	mfrin	1,5
	popcntb	%r1,%r1			# there is no popcnth instruction
	li	%r2,0x1f
	addis	%r2,%r2,0x1f
	rldimi	%r2,%r2,32,0
	srdi	%r0,%r1,8
	add	%r1,%r1,%r0
	and	%r1,%r1,%r2
	mtrin	1,6
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	1,5
	popcntb	%r1,%r1
	srdi	%r0,%r1,8
	add	%r1,%r1,%r0
	and	%r1,%r1,%r2
	mtrin	1,6
	b	return

do_vpopcntw:
	mfrin	1,5
	popcntw	%r1,%r1
	mtrin	1,6
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	1,5
	popcntw	%r1,%r1
	mtrin	1,6
	b	return

do_vpopcntd:
	mfrin	1,5
	popcntd	%r1,%r1
	mtrin	1,6
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	1,5
	popcntd	%r1,%r1
	mtrin	1,6
	b	return

do_vclzlsbb:
	li	%r11,8
	li	%r3,8
1:	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r1,%r1,8
	andi.	%r0,%r1,1
	bne	3f
	bdnz	2b
	andi.	%r0,%r5,LO
	bne	3f
	addi	%r5,%r5,LO
	addi	%r3,%r3,8
	b	1b
3:	mfctr	%r0
	subf	%r3,%r0,%r3
	li	%r2,0
	mtrin	2,6
	addi	%r6,%r6,LO
	mtrin	3,6
	b	return

do_vctzlsbb:
	li	%r11,8
	li	%r3,8
	addi	%r5,%r5,LO
1:	mfrin	1,5
	mtctr	%r11
2:	andi.	%r0,%r1,1
	bne	3f
	rotldi	%r1,%r1,56
	bdnz	2b
	andi.	%r0,%r5,LO
	beq	3f
	subi	%r5,%r5,LO
	addi	%r3,%r3,8
	b	1b
3:	mfctr	%r0
	subf	%r3,%r0,%r3
	li	%r2,0
	mtrin	2,6
	addi	%r6,%r6,LO
	mtrin	3,6
	b	return
