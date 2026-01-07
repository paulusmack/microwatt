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

	# MSR bits
MSR_FP	= 0x2000
MSR_VSX = 0x800000
MSR_VEC = 0x2000000

	# Register file offsets
FR0	= 0x40
VSR0	= 0x40
VR0	= 0x60
LO	= 0x80		# offset to low half of VSR/VR
LOBIT	= 7		# log_2(LO)

	# Condition register bits (big-endian numbering)
LT	= 0
GT	= 1
EQ	= 2
SO	= 3

	# VSCR bits (stored in high half of VRSAVE)
SAT	= 1
NJ	= 0x10000

	# FPSCR bits
FPS_FX		= 0x80000000
FPS_FEX 	= 0x40000000
FPS_VX		= 0x20000000
FPS_OX		= 0x10000000
FPS_UX		= 0x08000000
FPS_ZX		= 0x04000000
FPS_XX		= 0x02000000
FPS_VXSNAN	= 0x01000000
FPS_VXISI	= 0x00800000
FPS_VXIDI	= 0x00400000
FPS_VXZDZ	= 0x00200000
FPS_VXIMZ	= 0x00100000
FPS_VXVC	= 0x00080000
FPS_FR		= 0x00040000
FPS_FI		= 0x00020000
FPS_FPRF	= 0x0001f000
FPS_VXSOFT	= 0x00000400
FPS_VXSQRT	= 0x00000200
FPS_VXCVI	= 0x00000100
FPS_VE		= 0x00000080
FPS_OE		= 0x00000040
FPS_UE		= 0x00000020
FPS_ZE		= 0x00000010
FPS_XE		= 0x00000008
FPS_RN		= 0x00000003
FPS_ALLVX	= 0x01f80700		# OR of all FPS_VX*
FPS_ALLX	= (FPS_ALLVX|FPS_OX|FPS_UX|FPS_ZX|FPS_XX)

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
	rlwinm	%r0,%r8,6,0x3f			# primary opcode field
	srdi.	%r7,%r8,32			# prefix
	bne	prefixed
	cmpdi	%r0,60
	beq	po60
	cmpdi	%r0,31
	beq	po31
	cmpdi	%r0,4
	bne	illegal

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

po60:	rlwinm	%r1,%r8,32-2,0x1ff		# extract extended opcode/2
	rlwimi	%r4,%r8,5-2,0x20		# insert AX field
	rlwimi	%r5,%r8,5-1,0x20		# insert BX field
	rlwimi	%r6,%r8,5-0,0x20		# insert TX field
	addi	%r4,%r4,VSR0
	addi	%r5,%r5,VSR0
	addi	%r6,%r6,VSR0
	rlwinm	%r0,%r8,0,0x3c			# column number/2*4
	rlwinm	%r3,%r8,32-6+2,0x7c		# row number * 4
	cmpdi	%r0,48
	bge	do_xxsel
	addpcis	%r9,0
	addi	%r9,%r9,op60_table-.
	lwzx	%r11,%r9,%r0
	cmpdi	%r11,0
	beq	illegal
	add	%r11,%r11,%r9
	lwzx	%r12,%r11,%r3
	cmpdi	%r12,0
	beq	illegal
	add	%r12,%r12,%r11
	andi.	%r0,%r12,1
	bne	2f
	andis.	%r0,%r2,MSR_VSX@h
	beq	vsx_unavail
	mtctr	%r12
	bctr
2:	rlwinm	%r3,%r8,16+2,0x7c		# expanded opcode * 4
	clrrdi	%r12,%r12,1
	lwzx	%r11,%r3,%r12
	cmpdi	%r11,0
	beq	illegal
	add	%r11,%r11,%r12
	andis.	%r0,%r2,MSR_VSX@h
	beq	vsx_unavail
	mtctr	%r11
	bctr

po31:	rlwinm	%r1,%r8,32-1,0x3ff		# extract extended opcode
	cmpdi	%r1,6
	beq	do_lvsl
	cmpdi	%r1,38
	beq	do_lvsr
	b	illegal

prefixed:
	srdi	%r1,%r7,21
	cmpdi	%r1,0x28			# is it prefix opcode with 8RR form?
	bne	illegal
	cmpdi	%r0,32
	bne	illegal
ext132:	cmpdi	%r4,8
	bge	illegal
	andis.	%r0,%r2,MSR_VSX@h
	beq	vsx_unavail
	ori	%r6,%r6,VSR0
	rlwimi	%r6,%r4,5-0,0x20		# insert TX bit
	clrldi	%r1,%r8,48			# form immediate value
	rldimi	%r1,%r7,16,32
	cmpdi	%r4,4
	blt	do_xxsplti32dx
	cmpdi	%r4,6
	blt	do_xxspltidp
	b	do_xxspltiw

illegal:
	# save the instruction word in memory
	mfspr	%r0,HEIR
	pstw	%r0,ill_inst-.
	# anything we don't recognize gets punted to e40
	mtcr	%r31
	li	%r0,0
	mtspr	EMUC,%r0
	isync
	ba	0xe40
ill_inst:
	.long	0

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
	.long	vcol8 - op4_table
	.long	vcol9 - op4_table
	.long	0		# column 10
	.long	0
	.long	vcol12 - op4_table
	.long	vcol13 - op4_table
	.long	vcol14 - op4_table
	.long	0
	.long	0
	.long	0
	.long	0
	.long	do_vmsumcud - op4_table + 1
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
	.long	do_vmhaddshs - op4_table + 1
	.long	do_vmhraddshs - op4_table + 1
	.long	do_vmladduhm - op4_table + 1
	.long	do_vmsumudm - op4_table + 1
	.long	do_vmsumubm - op4_table + 1
	.long	do_vmsummbm - op4_table + 1
	.long	do_vmsumuhm - op4_table + 1
	.long	do_vmsumuhs - op4_table + 1
	.long	do_vmsumshm - op4_table + 1		# column 40
	.long	do_vmsumshs - op4_table + 1
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
	.long	xpnd004_3 - vcol2 + 1
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
vcol8:
	.long	do_vmuloub - vcol8		# row 0
	.long	do_vmulouh - vcol8
	.long	do_vmulouw - vcol8
	.long	do_vmuloud - vcol8
	.long	do_vmulosb - vcol8		# row 4
	.long	do_vmulosh - vcol8
	.long	do_vmulosw - vcol8
	.long	do_vmulosd - vcol8
	.long	do_vmuleub - vcol8		# row 8
	.long	do_vmuleuh - vcol8
	.long	do_vmuleuw - vcol8
	.long	do_vmuleud - vcol8
	.long	do_vmulesb - vcol8		# row 12
	.long	do_vmulesh - vcol8
	.long	do_vmulesw - vcol8
	.long	do_vmulesd - vcol8
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# row 20
	.long	0
	.long	0
	.long	0
	.long	do_vsum4ubs - vcol8
	.long	do_vsum4shs - vcol8
	.long	do_vsum2sws - vcol8
	.long	0
	.long	do_vsum4sbs - vcol8
	.long	0
	.long	do_vsumsws - vcol8		# row 30
	.long	0

vcol9:
	.long	0		# row 0
	.long	0
	.long	do_vmuluwm - vcol9
	.long	0
	.long	0		# row 4
	.long	0
	.long	0
	.long	do_vmulld - vcol9
	.long	0		# row 8
	.long	0
	.long	do_vmulhuw - vcol9
	.long	do_vmulhud - vcol9
	.long	0		# row 12
	.long	0
	.long	do_vmulhsw - vcol9
	.long	do_vmulhsd - vcol9
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

vcol13:
	.long	0		# row 0
	.long	0
	.long	0
	.long	0
	.long	0		# row 4
	.long	0
	.long	0
	.long	0
	.long	do_vextractub - vcol13		# row 8
	.long	do_vextractuh - vcol13
	.long	do_vextractuw - vcol13
	.long	do_vextractd - vcol13
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
	.long	do_vextublx - vcol13
	.long	do_vextuhlx - vcol13
	.long	do_vextuwlx - vcol13
	.long	0
	.long	do_vextubrx - vcol13
	.long	do_vextuhrx - vcol13
	.long	do_vextuwrx - vcol13		# row 30
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
	.long	do_vnegw - xpnd004_2
	.long	do_vnegd - xpnd004_2
	.long	do_vprtybw - xpnd004_2		# row 8
	.long	do_vprtybd - xpnd004_2
	.long	do_vprtybq - xpnd004_2
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	do_vextsb2w - xpnd004_2		# row 16
	.long	do_vextsh2w - xpnd004_2
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	do_vextsb2d - xpnd004_2		# row 24
	.long	do_vextsh2d - xpnd004_2
	.long	do_vextsw2d - xpnd004_2
	.long	do_vextsd2q - xpnd004_2
	.long	do_vctzb - xpnd004_2
	.long	do_vctzh - xpnd004_2
	.long	do_vctzw - xpnd004_2
	.long	do_vctzd - xpnd004_2

xpnd004_3:
	.long	0		# row 0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	do_vextractbm - xpnd004_3		# row 8
	.long	do_vextracthm - xpnd004_3
	.long	do_vextractwm - xpnd004_3
	.long	do_vextractdm - xpnd004_3
	.long	do_vextractqm - xpnd004_3
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
	.long	0
	.long	0
	.long	0
	.long	0

op60_table:
	.long	xcol0 - op60_table	# column 0,1
	.long	xcol0 - op60_table
	.long	0
	.long	0
	.long	xcol8 - op60_table
	.long	xcol8 - op60_table
	.long	xcol12 - op60_table
	.long	xcol12 - op60_table
	.long	0			# column 16,17
	.long	0
	.long	xcol20 - op60_table
	.long	xcol22 - op60_table

xcol0:
	.long	0		# row 0
	.long	0
	.long	0
	.long	0
	.long	0		# row 4
	.long	0
	.long	0
	.long	0
	.long	do_xvaddsp - xcol0		# row 8
	.long	do_xvsubsp - xcol0
	.long	do_xvmulsp - xcol0
	.long	do_xvdivsp - xcol0
	.long	do_xvadddp - xcol0		# row 12
	.long	do_xvsubdp - xcol0
	.long	do_xvmuldp - xcol0
	.long	do_xvdivdp - xcol0
	.long	do_xsmaxcdp - xcol0
	.long	do_xsmincdp - xcol0
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

xcol8:
	.long	do_xxsldwi - xcol8		# row 0
	.long	do_xxpermdi - xcol8
	.long	do_xxmrghw - xcol8
	.long	do_xxperm - xcol8
	.long	do_xxsldwi - xcol8		# row 4
	.long	do_xxpermdi - xcol8
	.long	do_xxmrglw - xcol8
	.long	do_xxperm - xcol8
	.long	do_xxsldwi - xcol8		# row 8
	.long	do_xxpermdi - xcol8
	.long	do_xxspltex - xcol8
	.long	do_xxpndins - xcol8 + 1
	.long	do_xxsldwi - xcol8		# row 12
	.long	do_xxpermdi - xcol8
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

xcol12:
	.long	do_xscmpeqdp - xcol12		# row 0
	.long	do_xscmpgtdp - xcol12
	.long	do_xscmpgedp - xcol12
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
	.long	0
	.long	0
	.long	0		# row 30
	.long	0

xcol20:
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
	.long	0
	.long	0
	.long	0		# row 30
	.long	0

xcol22:
	.long	0		# row 0
	.long	0
	.long	0
	.long	0
	.long	0		# row 4
	.long	0
	.long	0
	.long	0
	.long	do_xvsqrtsp - xcol22		# row 8
	.long	0
	.long	0
	.long	0
	.long	do_xvsqrtdp - xcol22		# row 12
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
	.long	xpnd060_3 - xcol22 + 1
	.long	0		# row 30
	.long	0

xpnd060_3:
	.long	0		# row 0
	.long	0
	.long	0
	.long	0
	.long	0		# row 4
	.long	0
	.long	0
	.long	do_xxbrh - xpnd060_3
	.long	0		# row 8
	.long	0
	.long	0
	.long	0
	.long	0		# row 12
	.long	0
	.long	0
	.long	do_xxbrw - xpnd060_3
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# row 20
	.long	0
	.long	0
	.long	do_xxbrd - xpnd060_3
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# row 30
	.long	do_xxbrq - xpnd060_3

do_xxsplti32dx:
	andi.	%r0,%r4,2
	ori	%r7,%r6,LO
	bne	1f				# if changing low words
	mfrin	0,6
	rldimi	%r0,%r1,32,0			# put immediate in high word
	mtrin	0,6
	mfrin	0,7
	rldimi	%r0,%r1,32,0
	mtrin	0,7
	b	preturn
1:	mfrin	0,6
	rldimi	%r0,%r1,0,32			# put immediate in low word
	mtrin	0,6
	mfrin	0,7
	rldimi	%r0,%r1,0,32
	mtrin	0,7
	b	preturn

do_xxspltidp:
	# convert immediate value in r1 from single to double precision
	rldicr	%r2,%r1,32,0			# extract sign bit
	rlwinm.	%r3,%r1,9,0xff			# extract exponent
	beq	9f				# if zero or denorm, flush to 0
	rldimi	%r2,%r1,52-23,12		# insert mantissa into result
	cmpdi	%r3,0xff			# infinity or NaN?
	bne	2f
	addi	%r3,%r3,0x380			# ff + 700 -> 7ff
2:	addi	%r3,%r3,0x380			# add 1023 - 127 extra exponent bias
	rldimi	%r2,%r3,52,1			# insert exponent
9:	mtrin	2,6
	ori	%r6,%r6,LO
	mtrin	2,6
	b	preturn

do_xxspltiw:
	rldimi	%r1,%r1,32,0
	mtrin	1,6
	ori	%r6,%r6,LO
	mtrin	1,6
	b	preturn

do_xxpermdi:
	rlwimi	%r4,%r8,LOBIT-9+32,LO		# insert bit 0 of DM
	rlwimi	%r5,%r8,LOBIT-8+32,LO		# insert bit 1 of DM
	mfrin	0,4				# fetch hi/lo half of XA
	mfrin	1,5				# fetch hi/lo half of XB
	mtrin	0,6				# put in hi half of XT
	addi	%r6,%r6,LO
	mtrin	1,6				# put in lo half of XT
	b	return

do_xxsldwi:
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

do_xxmrglw:
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
do_xxmrghw:
	mfrin	0,4
	mfrin	1,5
	srdi	%r2,%r1,32			# B0
	rldimi	%r1,%r0,32,0			# A1 || B1
	rldimi	%r0,%r2,0,32			# A0 || B0
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return

do_xxperm:
	mtcrf	0x4,%r8
	mfrin	8,4				# A_hi
	addi	%r4,%r4,LO
	mfrin	9,4				# A_lo
	mfrin	10,6				# T_hi
	addi	%r7,%r6,LO
	mfrin	11,7				# T_lo
	li	%r12,8
1:	mtctr	%r12
	mfrin	4,5				# B (hi or lo)
	bt	23,2f				# branch if xxpermr
	not	%r4,%r4				# invert B if xxperm
2:	rotldi	%r4,%r4,8			# next byte of B
	mtcrf	0x3,%r4
	isel	%r2,%r8,%r10,27
	isel	%r3,%r9,%r11,27
	isel	%r0,%r2,%r3,28
	rlwinm	%r2,%r4,3,0x38			# 3 LSB of index -> shift count
	srd	%r0,%r0,%r2
	rotldi	%r1,%r1,8
	rldimi	%r1,%r0,0,56
	bdnz	2b
	mtrin	1,6
	andi.	%r0,%r6,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	beq	1b
	b	return

do_xxspltex:	# xxspltw and xxextractuw
	andi.	%r0,%r1,1
	bne	do_xxextractuw
	# xxspltw
	rlwimi	%r5,%r8,32-17+LOBIT,LO		# select B_lo if UIM(0)(BE) = 1
	rlwinm	%r4,%r8,32-16+5,0x20		# UIM(1)(BE) -> rotate count (0 or 32)
	xori	%r4,%r4,0x20
	mfrin	0,5
	rotld	%r0,%r0,%r4
	rldimi	%r0,%r0,32,0
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	0,6
	b	return

do_xxextractuw:
	andis.	%r0,%r8,8			# is UIM >= 8?
	rlwinm	%r9,%r8,32-16+3,0x78		# get UIM(1:3) * 8
	addi	%r4,%r5,LO
	mfrin	0,4
	li	%r1,0
	bne	1f
	mr	%r1,%r0
	mfrin	0,5
	li	%r2,-1
	sld	%r2,%r2,%r9
	rotld	%r1,%r1,%r9
	andc	%r1,%r1,%r2
1:	sld	%r0,%r0,%r9
	or	%r0,%r0,%r1
	srdi	%r0,%r0,32
	mtrin	0,6
	addi	%r6,%r6,LO
	li	%r1,0
	mtrin	1,6
	b	return

do_xxpndins:	# XPND060-1 and xxinsertw
	andi.	%r0,%r1,1
	bne	do_xxinsertw
	andi.	%r0,%r8,2
	bne	illegal
	# XPND060-1
	rlwinm	%r0,%r8,16,0x1f			# expanded opcode
	cmpdi	%r0,7
	ble	do_xxspltib
	b	illegal

do_xxinsertw:
	andis.	%r0,%r2,MSR_VSX@h
	beq	vsx_unavail
	mfrin	1,5
	sldi	%r1,%r1,32
	addi	%r7,%r6,LO
	andis.	%r0,%r8,8			# is UIM >= 8?
	rlwinm	%r9,%r8,32-16+3,0x78		# get UIM(1:3) * 8
	xori	%r10,%r9,0x78
	addi	%r10,%r10,8			# convert to rotate left count
	rotld	%r1,%r1,%r10
	li	%r11,0
	li	%r12,-1
	clrrdi	%r12,%r12,32
	srd	%r11,%r12,%r9
	beq	1f
	mfrin	2,6
	and	%r0,%r1,%r11
	andc	%r2,%r2,%r11
	or	%r2,%r2,%r0
	mtrin	2,6
	sld	%r11,%r12,%r10
1:	mfrin	3,7
	and	%r1,%r1,%r11
	andc	%r3,%r3,%r11
	or	%r3,%r3,%r1
	mtrin	3,7
	b	return

do_xxspltib:
	andi.	%r0,%r8,1
	bne	1f
	andis.	%r0,%r2,MSR_VSX@h
	beq	vsx_unavail
	b	2f
1:	andis.	%r0,%r2,MSR_VEC@h
	beq	vec_unavail
2:	rlwinm	%r0,%r8,21,0xff
	rlwimi	%r0,%r0,8,0xff00
	rlwimi	%r0,%r0,16,0xffff0000
	rldimi	%r0,%r0,32,0
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	0,6
	b	return

do_xxsel:
	andis.	%r0,%r2,MSR_VSX@h
	beq	vsx_unavail
	rlwinm	%r7,%r8,5+21,0x1f		# get C field
	rlwimi	%r7,%r8,5-3,0x20		# insert CX field
	addi	%r7,%r7,VSR0
	mfrin	0,4
	mfrin	1,5
	mfrin	2,7
	andc	%r0,%r0,%r2
	and	%r1,%r1,%r2
	or	%r0,%r0,%r1
	mtrin	0,6
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	addi	%r7,%r7,LO
	mfrin	0,4
	mfrin	1,5
	mfrin	2,7
	andc	%r0,%r0,%r2
	and	%r1,%r1,%r2
	or	%r0,%r0,%r1
	mtrin	0,6
	b	return

do_lvsl:
	cmpdi	%r4,0
	beq	1f
	mfrin	4,4
1:	mfrin	5,5
	add	%r4,%r4,%r5
	clrldi	%r4,%r4,60
4:	li	%r8,8
	addi	%r6,%r6,VR0
2:	mtctr	%r8
3:	sldi	%r0,%r0,8
	rldimi	%r0,%r4,0,56
	addi	%r4,%r4,1
	bdnz	3b
	mtrin	0,6
	andi.	%r0,%r6,LO
	ori	%r6,%r6,LO
	beq	2b
	b	return

do_lvsr:
	cmpdi	%r4,0
	beq	1f
	mfrin	4,4
1:	mfrin	5,5
	add	%r5,%r4,%r5
	clrldi	%r5,%r5,60
	li	%r4,16
	subf	%r4,%r5,%r4
	b	4b

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
	# Follow P9 behaviour in the undefined case
	# (where not all bytes of VRB specify the same shift amount)
	mfrin	0,4
	addi	%r4,%r4,LO
	mfrin	1,4
	li	%r11,8
1:	mfrin	2,5
	mtctr	%r11
2:	rotldi	%r2,%r2,8
	clrldi	%r9,%r2,61
	sld	%r9,%r0,%r9
	rotldi	%r9,%r9,8
	rotldi	%r3,%r3,8
	rldimi	%r3,%r9,0,56
	rotldi	%r0,%r0,8
	rotldi	%r1,%r1,8
	rldimi	%r0,%r1,0,56
	bdnz	2b
	mtrin	3,6
	andi.	%r9,%r6,LO
	bne	return
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	li	%r1,0
	b	1b

# The following is faster but has different behaviour from P9 in the undefined case
#	mfrin	0,4
#	addi	%r4,%r4,LO
#	addi	%r5,%r5,LO
#	mfrin	1,4
#	mfrin	3,5
#	clrldi	%r3,%r3,61
#	li	%r7,-1
#	sld	%r0,%r0,%r3
#	rotld	%r1,%r1,%r3
#	sld	%r7,%r7,%r3
#	andc	%r8,%r1,%r7
#	and	%r1,%r1,%r7
#	or	%r0,%r0,%r8
#	mtrin	0,6
#	addi	%r6,%r6,LO
#	mtrin	1,6
#	b	return

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
	srdi	%r0,%r0,32
	rldicl	%r1,%r1,32,59
	srw	%r9,%r0,%r1
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
	# Follow P9 behaviour in the undefined case
	# (where not all bytes of VRB specify the same shift amount)
	li	%r11,8
	li	%r3,0
1:	mfrin	0,4
	mfrin	2,5
	mtctr	%r11
2:	sldi	%r3,%r3,8
	rotldi	%r0,%r0,8
	rldimi	%r3,%r0,0,56
	rotldi	%r2,%r2,8
	clrldi	%r9,%r2,61
	srd	%r9,%r3,%r9
	rotldi	%r10,%r10,8
	rldimi	%r10,%r9,0,56
	bdnz	2b
	mtrin	10,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

# The following is faster but has different behaviour from P9 in the undefined case
#	mfrin	0,4
#	addi	%r4,%r4,LO
#	mfrin	1,4
#	addi	%r5,%r5,LO
#	mfrin	3,5
#	clrldi	%r3,%r3,61
#	li	%r7,-1
#	neg	%r9,%r3
#	rotld	%r0,%r0,%r9
#	srd	%r1,%r1,%r3
#	srd	%r7,%r7,%r3
#	andc	%r8,%r0,%r7
#	and	%r0,%r0,%r7
#	or	%r1,%r1,%r8
#	mtrin	0,6
#	addi	%r6,%r6,LO
#	mtrin	1,6
#	b	return

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
	rldicl	%r2,%r1,32,59
	srad	%r3,%r0,%r2
	clrldi	%r2,%r1,59
	sraw	%r0,%r0,%r2
	rldimi	%r3,%r0,0,32
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
cmp_rc:
	andi.	%r8,%r8,0x400		# Rc bit set?
	beq	return
	li	%r0,0xf0		# clear CR6 image in r31
	andc	%r31,%r31,%r0
	or.	%r0,%r2,%r3
	and	%r1,%r2,%r3
	cmpdi	%cr1,%r1,-1
	mfcr	%r0
	rlwimi	%r31,%r0,8,0x20		# cr0.eq -> cr6 bit 2 (BE numbering)
	rlwimi	%r31,%r0,14,0x80	# cr1.eq -> cr6 bit 0 (BE numbering)
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
	b	cmp_rc

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
	b	cmp_rc

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
	b	cmp_rc

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
2:	setnbc	%r2,EQ
	mr	%r3,%r2
	mtrin	2,6
	addi	%r6,%r6,LO
	mtrin	3,6
	b	cmp_rc

do_vcmpgtub:
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,8
	mtctr	%r11
2:	clrrdi	%r9,%r0,56
	clrrdi	%r10,%r1,56
	cmpld	%r9,%r10
	sldi	%r0,%r0,8
	sldi	%r1,%r1,8
	sldi	%r3,%r3,8
	setnbc	%r7,GT
	rldimi	%r3,%r7,0,56
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	bne	cmp_rc
	mr	%r2,%r3
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtsb:
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,8
	mtctr	%r11
2:	clrrdi	%r9,%r0,56
	clrrdi	%r10,%r1,56
	cmpd	%r9,%r10
	sldi	%r0,%r0,8
	sldi	%r1,%r1,8
	sldi	%r3,%r3,8
	setnbc	%r7,GT
	rldimi	%r3,%r7,0,56
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	bne	cmp_rc
	mr	%r2,%r3
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtuh:
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,4
	mtctr	%r11
2:	clrrdi	%r9,%r0,48
	clrrdi	%r10,%r1,48
	cmpld	%r9,%r10
	sldi	%r0,%r0,16
	sldi	%r1,%r1,16
	sldi	%r3,%r3,16
	setnbc	%r7,GT
	rldimi	%r3,%r7,0,48
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	bne	cmp_rc
	mr	%r2,%r3
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtsh:
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,4
	mtctr	%r11
2:	clrrdi	%r9,%r0,48
	clrrdi	%r10,%r1,48
	cmpd	%r9,%r10
	sldi	%r0,%r0,16
	sldi	%r1,%r1,16
	sldi	%r3,%r3,16
	setnbc	%r7,GT
	rldimi	%r3,%r7,0,48
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	bne	cmp_rc
	mr	%r2,%r3
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtuw:
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,2
	mtctr	%r11
2:	clrrdi	%r9,%r0,32
	clrrdi	%r10,%r1,32
	cmpld	%r9,%r10
	sldi	%r0,%r0,32
	sldi	%r1,%r1,32
	sldi	%r3,%r3,32
	setnbc	%r7,GT
	rldimi	%r3,%r7,0,32
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	bne	cmp_rc
	mr	%r2,%r3
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtsw:
1:	mfrin	0,4
	mfrin	1,5
	li	%r11,2
	mtctr	%r11
2:	clrrdi	%r9,%r0,32
	clrrdi	%r10,%r1,32
	cmpd	%r9,%r10
	sldi	%r0,%r0,32
	sldi	%r1,%r1,32
	sldi	%r3,%r3,32
	setnbc	%r7,GT
	rldimi	%r3,%r7,0,32
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r4,LO
	bne	cmp_rc
	mr	%r2,%r3
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtud:
1:	mfrin	0,4
	mfrin	1,5
	cmpld	%r0,%r1
	setnbc	%r3,GT
	mtrin	3,6
	andi.	%r0,%r4,LO
	bne	cmp_rc
	mr	%r2,%r3
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vcmpgtsd:
1:	mfrin	0,4
	mfrin	1,5
	cmpd	%r0,%r1
	setnbc	%r3,GT
	mtrin	3,6
	andi.	%r0,%r4,LO
	bne	cmp_rc
	mr	%r2,%r3
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
2:	setnbc	%r3,GT
	mr	%r2,%r3
	mtrin	3,6
	ori	%r6,%r6,LO
	mtrin	3,6
	b	cmp_rc

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
2:	setnbc	%r3,GT
	mr	%r2,%r3
	mtrin	3,6
	ori	%r6,%r6,LO
	mtrin	3,6
	b	cmp_rc

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
	b	cmp_rc

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
	b	cmp_rc

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
	b	cmp_rc

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
	and	%r2,%r2,%r10
	or	%r14,%r14,%r15
	orc	%r2,%r14,%r2
	and	%r2,%r2,%r9
	sldi	%r10,%r2,8
	or	%r2,%r2,%r10
	mtrin	2,6
	andi.	%r0,%r4,LO
	bne	cmp_rc
	mr	%r3,%r2
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

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
	bne	cmp_rc
	mr	%r3,%r2
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

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
	bne	cmp_rc
	mr	%r3,%r2
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

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
	andi.	%r8,%r6,LO
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
	andi.	%r8,%r6,LO
	addi	%r6,%r6,LO
	beq	1b
	b	return

do_vmrglw:
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
do_vmrghw:
	mfrin	2,4
	mfrin	3,5
	rotldi	%r1,%r3,32
	rldimi	%r3,%r2,32,0
	rldimi	%r2,%r1,0,32
	mtrin	2,6
	addi	%r6,%r6,LO
	mtrin	3,6
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
	rlwimi	%r5,%r8,12+LOBIT+1,LO	# instr bit 12 (BE) -> LO bit
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
	rlwimi	%r5,%r8,13+LOBIT+1,LO	# instr bit 13 (BE) -> LO bit
	rlwinm	%r1,%r8,15-27+32,0x30	# rest of UIM field -> bit shift count
	xori	%r1,%r1,0x30
	mfrin	0,5
	srd	%r0,%r0,%r1
	rlwimi	%r0,%r0,16,0xffff0000
	rldimi	%r0,%r0,32,0
	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	0,6
	b	return

do_vspltw:
	rlwimi	%r5,%r8,14+LOBIT+1,LO	# instr bit 14 (BE) -> LO bit
	rlwinm	%r1,%r8,15-26+32,0x20	# rest of UIM field -> bit shift count
	xori	%r1,%r1,0x20
	mfrin	0,5
	srd	%r0,%r0,%r1
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
	lis	%r2,0xaa
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
	li	%r2,0
	mfrin	0,4
	addi	%r4,%r4,LO
	mfrin	1,4
	mfrin	9,5
	addi	%r5,%r5,LO
	mfrin	10,5
1:	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r2,%r2,8
	rldimi	%r2,%r0,32,24
	rldimi	%r2,%r1,0,56
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	mr	%r0,%r9
	mr	%r1,%r10
	ori	%r6,%r6,LO
	b	1b

do_vpkuhus:
	li	%r11,4
	li	%r7,255
	crclr	31
	li	%r1,0
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mfrin	9,5
	addi	%r5,%r5,LO
	mfrin	10,5
1:	mtctr	%r11
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
	mr	%r2,%r9
	mr	%r3,%r10
	ori	%r6,%r6,LO
	b	1b

do_vpkuwum:
	li	%r11,2
	mfrin	0,4
	addi	%r4,%r4,LO
	mfrin	1,4
	mfrin	9,5
	addi	%r5,%r5,LO
	mfrin	10,5
1:	li	%r2,0
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
	mr	%r0,%r9
	mr	%r1,%r10
	ori	%r6,%r6,LO
	b	1b

do_vpkuwus:
	li	%r11,2
	li	%r7,0
	ori	%r7,%r7,0xffff
	crclr	31
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mfrin	9,5
	addi	%r5,%r5,LO
	mfrin	10,5
1:	li	%r1,0
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
	mr	%r2,%r9
	mr	%r3,%r10
	ori	%r6,%r6,LO
	b	1b

do_vpkshus:
	li	%r11,4
	li	%r12,255
	li	%r9,0
	crclr	31
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mfrin	9,5
	addi	%r5,%r5,LO
	mfrin	10,5
1:	li	%r1,0
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
	mr	%r2,%r9
	mr	%r3,%r10
	ori	%r6,%r6,LO
	b	1b

do_vpkshss:
	li	%r11,4
	li	%r12,127
	li	%r13,-128
	li	%r9,0
	crclr	31
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mfrin	13,5
	addi	%r5,%r5,LO
	mfrin	14,5
1:	li	%r1,0
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
	mr	%r2,%r13
	mr	%r3,%r14
	ori	%r6,%r6,LO
	b	1b

do_vpkswus:
	li	%r11,2
	li	%r12,0
	ori	%r12,%r12,65535
	li	%r9,0
	crclr	31
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mfrin	9,5
	addi	%r5,%r5,LO
	mfrin	10,5
1:	li	%r1,0
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
	mr	%r2,%r9
	mr	%r3,%r10
	ori	%r6,%r6,LO
	b	1b

do_vpkswss:
	li	%r11,2
	ori	%r12,%r12,32767
	li	%r13,-32768
	li	%r9,0
	crclr	31
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mfrin	9,5
	addi	%r5,%r5,LO
	mfrin	10,5
1:	li	%r1,0
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
	mr	%r2,%r9
	mr	%r3,%r10
	ori	%r6,%r6,LO
	b	1b

do_vpkudum:
	mfrin	0,4
	addi	%r4,%r4,LO
	mfrin	1,4
	mfrin	9,5
	addi	%r5,%r5,LO
	mfrin	10,5
1:	rotldi	%r0,%r0,32
	rldimi	%r0,%r1,0,32
	mtrin	0,6
	andi.	%r0,%r6,LO
	bne	return
	mr	%r0,%r9
	mr	%r1,%r10
	ori	%r6,%r6,LO
	b	1b

do_vpkudus:
	li	%r12,-1
	clrldi	%r12,%r12,32
	crclr	31
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mfrin	9,5
	addi	%r5,%r5,LO
	mfrin	10,5
1:	cmpld	%r2,%r12
	cror	31,31,GT
	isel	%r0,%r12,%r2,GT
	cmpld	%r3,%r12
	cror	31,31,GT
	isel	%r1,%r12,%r3,GT
	rldimi	%r1,%r0,32,0
	mtrin	1,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	mr	%r0,%r9
	mr	%r1,%r10
	ori	%r6,%r6,LO
	b	1b

do_vpksdus:
	li	%r12,-1
	clrldi	%r12,%r12,32
	crclr	31
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mfrin	13,5
	addi	%r5,%r5,LO
	mfrin	14,5
1:	cmpd	%r2,%r12
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
	mr	%r2,%r13
	mr	%r3,%r14
	ori	%r6,%r6,LO
	b	1b

do_vpksdss:
	lis	%r13,-32768
	not	%r12,%r13
	crclr	31
	mfrin	2,4
	addi	%r4,%r4,LO
	mfrin	3,4
	mfrin	13,5
	addi	%r5,%r5,LO
	mfrin	14,5
1:	cmpd	%r2,%r12
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
	mr	%r2,%r13
	mr	%r3,%r14
	ori	%r6,%r6,LO
	b	1b

do_vupklsb:
	addi	%r5,%r5,LO
do_vupkhsb:
	li	%r11,4
	mfrin	1,5
1:	mtctr	%r11
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
	mfrin	1,5
1:	mtctr	%r11
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
	clrldi	%r12,%r1,58
	srd	%r0,%r0,%r12
	rotldi	%r2,%r2,8
	rldimi	%r2,%r0,0,56
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
	add	%r3,%r0,%r1
	rotldi	%r8,%r8,8
	rldimi	%r8,%r3,0,56
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
	add	%r3,%r0,%r1
	rotldi	%r8,%r8,16
	rldimi	%r8,%r3,0,48
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
	add	%r3,%r0,%r1
	rotldi	%r8,%r8,32
	rldimi	%r8,%r3,0,32
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
	add	%r3,%r2,%r3
	andi.	%r2,%r3,0x100
	rotldi	%r8,%r8,8
	isel	%r3,%r3,%r12,EQ
	rldimi	%r8,%r3,0,56
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
	add	%r3,%r2,%r3
	andis.	%r2,%r3,1
	rotldi	%r8,%r8,16
	isel	%r3,%r3,%r12,EQ
	rldimi	%r8,%r3,0,48
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
	add	%r3,%r2,%r3
	andc.	%r2,%r3,%r12
	rotldi	%r8,%r8,32
	isel	%r3,%r3,%r12,EQ
	rldimi	%r8,%r3,0,32
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
	extsb	%r2,%r0
	extsb	%r3,%r1
	add	%r3,%r2,%r3
	cmpd	%r3,%r12
	cmpd	%cr1,%r3,%r13
	rotldi	%r8,%r8,8
	isel	%r3,%r12,%r3,GT
	isel	%r3,%r13,%r3,4*1+LT
	rldimi	%r8,%r3,0,56
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
	extsh	%r2,%r0
	extsh	%r3,%r1
	add	%r3,%r2,%r3
	cmpd	%r3,%r12
	cmpd	%cr1,%r3,%r13
	rotldi	%r8,%r8,16
	isel	%r3,%r12,%r3,GT
	isel	%r3,%r13,%r3,4*1+LT
	rldimi	%r8,%r3,0,48
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
	ori	%r12,%r12,0xffff
	lis	%r13,-32768
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	extsw	%r2,%r0
	extsw	%r3,%r1
	add	%r2,%r2,%r3
	cmpd	%r2,%r12
	cmpd	%cr1,%r2,%r13
	rotldi	%r8,%r8,32
	isel	%r2,%r12,%r2,GT
	isel	%r2,%r13,%r2,4*1+LT
	rldimi	%r8,%r2,0,32
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
	subf	%r3,%r1,%r0
	rotldi	%r8,%r8,8
	rldimi	%r8,%r3,0,56
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
	subf	%r3,%r1,%r0
	rotldi	%r8,%r8,16
	rldimi	%r8,%r3,0,48
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
	subf	%r3,%r1,%r0
	rotldi	%r8,%r8,32
	rldimi	%r8,%r3,0,32
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
	subf.	%r3,%r3,%r2
	rotldi	%r8,%r8,8
	isel	%r3,0,%r3,LT
	rldimi	%r8,%r3,0,56
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
	subf.	%r3,%r3,%r2
	rotldi	%r8,%r8,16
	isel	%r3,0,%r3,LT
	rldimi	%r8,%r3,0,48
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
	subf.	%r3,%r3,%r2
	rotldi	%r8,%r8,32
	isel	%r3,0,%r3,LT
	rldimi	%r8,%r3,0,32
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
	extsb	%r2,%r0
	extsb	%r3,%r1
	subf	%r3,%r3,%r2
	cmpd	%r3,%r12
	cmpd	%cr1,%r3,%r13
	rotldi	%r8,%r8,8
	isel	%r3,%r12,%r3,GT
	isel	%r3,%r13,%r3,4*1+LT
	rldimi	%r8,%r3,0,56
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
	extsh	%r2,%r0
	extsh	%r3,%r1
	subf	%r3,%r3,%r2
	cmpd	%r3,%r12
	cmpd	%cr1,%r3,%r13
	rotldi	%r8,%r8,16
	isel	%r3,%r12,%r3,GT
	isel	%r3,%r13,%r3,4*1+LT
	rldimi	%r8,%r3,0,48
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
	ori	%r12,%r12,0xffff
	lis	%r13,-32768
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	extsw	%r2,%r0
	extsw	%r3,%r1
	subf	%r3,%r3,%r2
	cmpd	%r3,%r12
	cmpd	%cr1,%r3,%r13
	rotldi	%r8,%r8,32
	isel	%r3,%r12,%r3,GT
	isel	%r3,%r13,%r3,4*1+LT
	rldimi	%r8,%r3,0,32
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

do_vmhaddshs:
	crclr	31
	mfxer	%r29
	li	%r11,4
	li	%r12,32767
	li	%r13,-32768
1:	mfrin	0,4
	mfrin	1,5
	mfrin	2,7
	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r2,%r2,16
	extsh	%r8,%r0
	extsh	%r9,%r1
	mullw	%r8,%r8,%r9
	extsh	%r10,%r2
	srawi	%r8,%r8,15
	add	%r8,%r8,%r10
	cmpd	%r8,%r12
	cmpd	%cr1,%r8,%r13
	rotldi	%r3,%r3,16
	isel	%r8,%r12,%r8,GT
	isel	%r8,%r13,%r8,4*1+LT
	rldimi	%r3,%r8,0,48
	cror	31,31,GT
	cror	31,31,4*1+LT
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r6,LO
	bne	setsatif31x
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	addi	%r7,%r7,LO
	b	1b

do_vmhraddshs:
	crclr	31
	mfxer	%r29
	li	%r11,4
	li	%r12,32767
	li	%r13,-32768
1:	mfrin	0,4
	mfrin	1,5
	mfrin	2,7
	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r2,%r2,16
	extsh	%r8,%r0
	extsh	%r9,%r1
	mullw	%r8,%r8,%r9
	extsh	%r10,%r2
	addi	%r8,%r8,0x4000
	srawi	%r8,%r8,15
	add	%r8,%r8,%r10
	cmpd	%r8,%r12
	cmpd	%cr1,%r8,%r13
	rotldi	%r3,%r3,16
	isel	%r8,%r12,%r8,GT
	isel	%r8,%r13,%r8,4*1+LT
	rldimi	%r3,%r8,0,48
	cror	31,31,GT
	cror	31,31,4*1+LT
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r6,LO
	bne	setsatif31x
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	addi	%r7,%r7,LO
	b	1b

do_vmladduhm:
	li	%r11,4
1:	mfrin	0,4
	mfrin	1,5
	mfrin	2,7
	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	rotldi	%r2,%r2,16
	clrldi	%r8,%r0,48
	clrldi	%r9,%r1,48
	mullw	%r8,%r8,%r9
	clrldi	%r10,%r2,48
	add	%r8,%r8,%r10
	rotldi	%r3,%r3,16
	rldimi	%r3,%r8,0,48
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	addi	%r7,%r7,LO
	b	1b

do_vmsumshm:
	li	%r11,2
	mfxer	%r29
1:	mfrin	0,4
	mfrin	1,5
	mfrin	2,7
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	rotldi	%r2,%r2,32
	extsh	%r8,%r0
	extsh	%r9,%r1
	mullw	%r10,%r8,%r9
	srawi	%r8,%r0,16
	srawi	%r9,%r1,16
	mullw	%r8,%r8,%r9
	add	%r8,%r8,%r10
	add	%r8,%r8,%r2
	rotldi	%r3,%r3,32
	rldimi	%r3,%r8,0,32
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r6,LO
	bne	3f
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	addi	%r7,%r7,LO
	b	1b
3:	mtxer	%r29
	b	return

do_vmsumuhm:
	li	%r11,2
1:	mfrin	0,4
	mfrin	1,5
	mfrin	2,7
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	rotldi	%r2,%r2,32
	clrldi	%r8,%r0,48
	clrldi	%r9,%r1,48
	mullw	%r10,%r8,%r9
	rldicl	%r8,%r0,48,48
	rldicl	%r9,%r1,48,48
	mullw	%r8,%r8,%r9
	rotldi	%r3,%r3,32
	add	%r8,%r8,%r10
	add	%r8,%r8,%r2
	rldimi	%r3,%r8,0,32
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	addi	%r7,%r7,LO
	b	1b

do_vmsumshs:
	crclr	31
	li	%r11,2
	mfxer	%r29
	lis	%r12,32767
	ori	%r12,%r12,0xffff
	lis	%r13,-32768
1:	mfrin	0,4
	mfrin	1,5
	mfrin	2,7
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	rotldi	%r2,%r2,32
	extsh	%r8,%r0
	extsh	%r9,%r1
	mullw	%r10,%r8,%r9
	srawi	%r8,%r0,16
	srawi	%r9,%r1,16
	mullw	%r8,%r8,%r9
	extsw	%r9,%r2
	add	%r8,%r8,%r10
	add	%r8,%r8,%r9
	cmpd	%r8,%r12
	cmpd	%cr1,%r8,%r13
	rotldi	%r3,%r3,32
	isel	%r8,%r12,%r8,GT
	isel	%r8,%r13,%r8,4*1+LT
	rldimi	%r3,%r8,0,32
	cror	31,31,GT
	cror	31,31,4*1+LT
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r6,LO
	bne	setsatif31x
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	addi	%r7,%r7,LO
	b	1b

do_vmsumuhs:
	crclr	31
	li	%r11,2
	li	%r12,-1
	clrldi	%r12,%r12,32
1:	mfrin	0,4
	mfrin	1,5
	mfrin	2,7
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	rotldi	%r2,%r2,32
	clrldi	%r8,%r0,48
	clrldi	%r9,%r1,48
	mullw	%r10,%r8,%r9
	rldicl	%r8,%r0,48,48
	rldicl	%r9,%r1,48,48
	mullw	%r8,%r8,%r9
	clrldi	%r9,%r2,32
	add	%r8,%r8,%r10
	add	%r8,%r8,%r9
	cmpd	%r8,%r12
	rotldi	%r3,%r3,32
	isel	%r8,%r12,%r8,GT
	rldimi	%r3,%r8,0,32
	cror	31,31,GT
	bdnz	2b
	mtrin	3,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	addi	%r7,%r7,LO
	b	1b

do_vmsumudm:
	mfrin	0,4
	mfrin	1,5
	mfrin	2,7
	addi	%r7,%r7,LO
	mfrin	3,7
	maddld	%r9,%r0,%r1,%r3
	maddhdu	%r8,%r0,%r1,%r3
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	0,4
	mfrin	1,5
	maddld	%r11,%r0,%r1,%r9
	maddhdu	%r10,%r0,%r1,%r9
	add	%r8,%r8,%r2
	add	%r8,%r8,%r10
	mtrin	8,6
	addi	%r6,%r6,LO
	mtrin	11,6
	b	return

do_vmsumcud:
	mfxer	%r29
	mfrin	0,4
	mfrin	1,5
	mfrin	2,7
	addi	%r7,%r7,LO
	mfrin	3,7
	maddld	%r9,%r0,%r1,%r3
	maddhdu	%r8,%r0,%r1,%r3
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	0,4
	mfrin	1,5
	maddhdu	%r10,%r0,%r1,%r9
	li	%r3,0
	addc	%r8,%r8,%r2
	addze	%r3,%r3
	addc	%r8,%r8,%r10
	addze	%r3,%r3
	li	%r2,0
	mtrin	2,6
	addi	%r6,%r6,LO
	mtrin	3,6
	mtxer	%r29
	b	return

setsatif31x:
	mtxer	%r29
setsatif31:
	bf+	31,return
setsat:
	mfspr	%r12,VRSAVE
	li	%r9,SAT
	sldi	%r9,%r9,32
	or	%r12,%r12,%r9
	mtspr	VRSAVE,%r12
return:
	mfspr	%r1,HSRR0
	addi	%r1,%r1,4
1:	mtspr	HSRR0,%r1
	mtctr	%r30
	mtcr	%r31
	li	%r0,0
	mtspr	EMUC,%r0
	hrfid
preturn:
	mfspr	%r1,HSRR0
	addi	%r1,%r1,8
	b	1b

do_vclzb:
	li	%r11,8
	li	%r12,1
	sldi	%r12,%r12,55
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
	sldi	%r12,%r12,47
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
	rldimi	%r2,%r0,32,0
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

do_vprtybw:
	mfrin	1,5
	prtyw	%r1,%r1
	mtrin	1,6
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	1,5
	prtyw	%r1,%r1
	mtrin	1,6
	b	return

do_vprtybd:
	mfrin	1,5
	prtyd	%r1,%r1
	mtrin	1,6
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	mfrin	1,5
	prtyd	%r1,%r1
	mtrin	1,6
	b	return

do_vprtybq:
	mfrin	0,5
	prtyd	%r0,%r0
	addi	%r5,%r5,LO
	mfrin	1,5
	prtyd	%r1,%r1
	xor	%r1,%r0,%r1
	li	%r0,0
	mtrin	0,6
	addi	%r6,%r6,LO
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
	addi	%r6,%r6,-VR0			# this writes a GPR destination
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
	addi	%r6,%r6,-VR0			# this writes a GPR destination
	mtrin	3,6
	b	return

do_vsumsws:
	mfxer	%r29
	mfrin	0,4
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	1,4
	mfrin	2,5
	extsw	%r2,%r2
	sradi	%r3,%r0,32
	add	%r2,%r2,%r3
	extsw	%r0,%r0
	add	%r2,%r2,%r0
	sradi	%r3,%r1,32
	add	%r2,%r2,%r3
	extsw	%r1,%r1
	add	%r2,%r2,%r1
	lis	%r11,-0x8000
	not	%r12,%r11
	cmpd	%r2,%r11
	cmpd	%cr1,%r2,%r12
	isel	%r2,%r11,%r2,LT
	isel	%r2,%r12,%r2,4*1+GT
	cror	31,LT,4*1+GT
	li	%r1,0
	mtrin	1,6
	clrldi	%r2,%r2,32
	addi	%r6,%r6,LO
	mtrin	2,6
	b	setsatif31x

do_vsum2sws:
	mfxer	%r29
	crclr	31
	lis	%r11,-0x8000
	not	%r12,%r11
1:	mfrin	0,4
	mfrin	2,5
	extsw	%r2,%r2
	sradi	%r3,%r0,32
	add	%r2,%r2,%r3
	extsw	%r0,%r0
	add	%r2,%r2,%r0
	cmpd	%r2,%r11
	cmpd	%cr1,%r2,%r12
	isel	%r2,%r11,%r2,LT
	clrldi	%r2,%r2,32
	cror	31,31,LT
	isel	%r2,%r12,%r2,4*1+GT
	cror	31,31,4*1+GT
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	setsatif31x
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vsum4sbs:
	mfxer	%r29
	crclr	31
	lis	%r11,-0x8000
	not	%r12,%r11
	li	%r10,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r10
2:	rotldi	%r1,%r1,32
	extsw	%r2,%r1
	.rept	4
	rotldi	%r0,%r0,8
	extsb	%r3,%r0
	add	%r2,%r2,%r3
	.endr
	cmpd	%r2,%r11
	cmpd	%cr1,%r2,%r12
	isel	%r2,%r11,%r2,LT
	cror	31,31,LT
	isel	%r2,%r12,%r2,4*1+GT
	cror	31,31,4*1+GT
	rotldi	%r8,%r8,32
	rldimi	%r8,%r2,0,32
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31x
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vsum4shs:
	mfxer	%r29
	crclr	31
	lis	%r11,-0x8000
	not	%r12,%r11
	li	%r10,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r10
2:	rotldi	%r1,%r1,32
	extsw	%r2,%r1
	.rept	2
	rotldi	%r0,%r0,16
	extsh	%r3,%r0
	add	%r2,%r2,%r3
	.endr
	cmpd	%r2,%r11
	cmpd	%cr1,%r2,%r12
	isel	%r2,%r11,%r2,LT
	cror	31,31,LT
	isel	%r2,%r12,%r2,4*1+GT
	cror	31,31,4*1+GT
	rotldi	%r8,%r8,32
	rldimi	%r8,%r2,0,32
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31x
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vsum4ubs:
	crclr	31
	li	%r11,-1
	clrldi	%r11,%r11,32
	li	%r10,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r10
2:	rotldi	%r1,%r1,32
	clrldi	%r2,%r1,32
	.rept	4
	rotldi	%r0,%r0,8
	clrldi	%r3,%r0,56
	add	%r2,%r2,%r3
	.endr
	cmpd	%r2,%r11
	isel	%r2,%r11,%r2,GT
	cror	31,31,GT
	rotldi	%r8,%r8,32
	rldimi	%r8,%r2,0,32
	bdnz	2b
	mtrin	8,6
	andi.	%r0,%r6,LO
	bne	setsatif31
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	b	1b

do_vnegw:
	li	%r11,2
	mtctr	%r11
1:	mfrin	1,5
	neg	%r0,%r1
	rotldi	%r1,%r1,32
	neg	%r1,%r1
	rldimi	%r0,%r1,32,0
	mtrin	0,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	bdnz	1b
	b	return

do_vnegd:
	mfrin	1,5
	neg	%r1,%r1
	mtrin	1,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	1,5
	neg	%r1,%r1
	mtrin	1,6
	b	return

do_vmulesb:
	li	%r11,4
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
	srdi	%r0,%r0,8
	srdi	%r1,%r1,8
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	extsb	%r8,%r0
	extsb	%r9,%r1
	mullw	%r8,%r8,%r9
	rotldi	%r2,%r2,16
	rldimi	%r2,%r8,0,48
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmulosb:
	li	%r11,4
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	extsb	%r8,%r0
	extsb	%r9,%r1
	mullw	%r8,%r8,%r9
	rotldi	%r2,%r2,16
	rldimi	%r2,%r8,0,48
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmuleub:
	li	%r11,4
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
	srdi	%r0,%r0,8
	srdi	%r1,%r1,8
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	clrldi	%r8,%r0,56
	clrldi	%r9,%r1,56
	mullw	%r8,%r8,%r9
	rotldi	%r2,%r2,16
	rldimi	%r2,%r8,0,48
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmuloub:
	li	%r11,4
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,16
	rotldi	%r1,%r1,16
	clrldi	%r8,%r0,56
	clrldi	%r9,%r1,56
	mullw	%r8,%r8,%r9
	rotldi	%r2,%r2,16
	rldimi	%r2,%r8,0,48
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmulesh:
	li	%r11,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
	srdi	%r0,%r0,16
	srdi	%r1,%r1,16
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	extsh	%r8,%r0
	extsh	%r9,%r1
	mullw	%r8,%r8,%r9
	rotldi	%r2,%r2,32
	rldimi	%r2,%r8,0,32
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmulosh:
	li	%r11,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	extsh	%r8,%r0
	extsh	%r9,%r1
	mullw	%r8,%r8,%r9
	rotldi	%r2,%r2,32
	rldimi	%r2,%r8,0,32
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmuleuh:
	li	%r11,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
	srdi	%r0,%r0,16
	srdi	%r1,%r1,16
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	clrldi	%r8,%r0,48
	clrldi	%r9,%r1,48
	mullw	%r8,%r8,%r9
	rotldi	%r2,%r2,32
	rldimi	%r2,%r8,0,32
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b
	li	%r11,4

do_vmulouh:
	li	%r11,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	clrldi	%r8,%r0,48
	clrldi	%r9,%r1,48
	mullw	%r8,%r8,%r9
	rotldi	%r2,%r2,32
	rldimi	%r2,%r8,0,32
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmulesw:
1:	mfrin	0,4
	mfrin	1,5
	srdi	%r0,%r0,32
	srdi	%r1,%r1,32
	mullw	%r2,%r0,%r1
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmulosw:
1:	mfrin	0,4
	mfrin	1,5
	mullw	%r2,%r0,%r1
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmuleuw:
1:	mfrin	0,4
	mfrin	1,5
	srdi	%r0,%r0,32
	srdi	%r1,%r1,32
	mulld	%r2,%r0,%r1
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmulouw:
1:	mfrin	0,4
	mfrin	1,5
	clrldi	%r0,%r0,32
	clrldi	%r1,%r1,32
	mulld	%r2,%r0,%r1
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmulesd:
	mfrin	0,4
	mfrin	1,5
	mulhd	%r2,%r0,%r1
	mulld	%r3,%r0,%r1
	mtrin	2,6
	ori	%r6,%r6,LO
	mtrin	3,6
	b	return

do_vmulosd:
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	mfrin	0,4
	mfrin	1,5
	mulhd	%r2,%r0,%r1
	mulld	%r3,%r0,%r1
	mtrin	2,6
	ori	%r6,%r6,LO
	mtrin	3,6
	b	return

do_vmuleud:
	mfrin	0,4
	mfrin	1,5
	mulhdu	%r2,%r0,%r1
	mulld	%r3,%r0,%r1
	mtrin	2,6
	ori	%r6,%r6,LO
	mtrin	3,6
	b	return

do_vmuloud:
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	mfrin	0,4
	mfrin	1,5
	mulhdu	%r2,%r0,%r1
	mulld	%r3,%r0,%r1
	mtrin	2,6
	ori	%r6,%r6,LO
	mtrin	3,6
	b	return

do_vmuluwm:
	li	%r11,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	mullw	%r3,%r0,%r1
	rotldi	%r2,%r2,32
	rldimi	%r2,%r3,0,32
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmulhsw:
	li	%r11,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	mulhd	%r3,%r0,%r1
	rotldi	%r2,%r2,32
	rldimi	%r2,%r3,0,32
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmulhuw:
	li	%r11,2
1:	mfrin	0,4
	mfrin	1,5
	mtctr	%r11
2:	rotldi	%r0,%r0,32
	rotldi	%r1,%r1,32
	mulhdu	%r3,%r0,%r1
	rotldi	%r2,%r2,32
	rldimi	%r2,%r3,0,32
	bdnz	2b
	mtrin	2,6
	andi.	%r0,%r6,LO
	bne	return
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	b	1b

do_vmulld:
	mfrin	0,4
	mfrin	1,5
	mulld	%r2,%r0,%r1
	mtrin	2,6
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	mulld	%r2,%r0,%r1
	mtrin	2,6
	b	return

do_vmulhsd:
	mfrin	0,4
	mfrin	1,5
	mulhd	%r2,%r0,%r1
	mtrin	2,6
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	mulhd	%r2,%r0,%r1
	mtrin	2,6
	b	return

do_vmulhud:
	mfrin	0,4
	mfrin	1,5
	mulhdu	%r2,%r0,%r1
	mtrin	2,6
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	mulhdu	%r2,%r0,%r1
	mtrin	2,6
	b	return

do_vextsb2w:
	li	%r11,2
	mtctr	%r11
1:	mfrin	1,5
	extsb	%r0,%r1
	rotldi	%r1,%r1,32
	extsb	%r1,%r1
	rldimi	%r0,%r1,32,0
	mtrin	0,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	bdnz	1b
	b	return

do_vextsh2w:
	li	%r11,2
	mtctr	%r11
1:	mfrin	1,5
	extsh	%r0,%r1
	rotldi	%r1,%r1,32
	extsh	%r1,%r1
	rldimi	%r0,%r1,32,0
	mtrin	0,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	bdnz	1b
	b	return

do_vextsb2d:
	mfrin	1,5
	extsb	%r1,%r1
	mtrin	1,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	1,5
	extsb	%r1,%r1
	mtrin	1,6
	b	return

do_vextsh2d:
	mfrin	1,5
	extsh	%r1,%r1
	mtrin	1,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	1,5
	extsh	%r1,%r1
	mtrin	1,6
	b	return

do_vextsw2d:
	mfrin	1,5
	extsw	%r1,%r1
	mtrin	1,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	1,5
	extsw	%r1,%r1
	mtrin	1,6
	b	return

do_vextsd2q:
	ori	%r5,%r5,LO
	mfrin	1,5
	srdi	%r0,%r1,63
	neg	%r0,%r0
	mtrin	0,6
	ori	%r6,%r6,LO
	mtrin	1,6
	b	return

do_vextractub:
	rlwimi	%r5,%r4,LOBIT-3,LO	# put bit 3 of index into r5
	rlwinm	%r2,%r4,3,0x38		# shift count from bits 0-2
	mfrin	1,5
	sld	%r1,%r1,%r2		# target byte to MSB
	srdi	%r1,%r1,56		# move it to LSB
	mtrin	1,6
	li	%r0,0
	addi	%r6,%r6,LO
	mtrin	0,6
	b	return

do_vextractuh:
	rlwimi	%r5,%r4,LOBIT-3,LO	# put bit 3 of index into r5
	mfrin	0,5			# fetch both dwords of VRB
	xori	%r5,%r5,LO
	mfrin	1,5
	rlwinm	%r2,%r4,3,0x38		# shift count from bits 0-2
	sld	%r0,%r0,%r2
	rotld	%r1,%r1,%r2
	li	%r3,1			# mask for bits from r0
	sld	%r3,%r3,%r2
	neg	%r3,%r3
	andc	%r1,%r1,%r3
	or	%r0,%r0,%r1
	srdi	%r0,%r0,48		# move bytes 0:1 to right end
	mtrin	0,6
	li	%r1,0
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return

do_vextractuw:
	rlwimi	%r5,%r4,LOBIT-3,LO	# put bit 3 of index into r5
	mfrin	0,5			# fetch both dwords of VRB
	xori	%r5,%r5,LO
	mfrin	1,5
	rlwinm	%r2,%r4,3,0x38		# shift count from bits 0-2
	sld	%r0,%r0,%r2
	rotld	%r1,%r1,%r2
	li	%r3,1			# mask for bits from r0
	sld	%r3,%r3,%r2
	neg	%r3,%r3
	andc	%r1,%r1,%r3
	or	%r0,%r0,%r1
	srdi	%r0,%r0,32		# move bytes 0:3 to right end
	mtrin	0,6
	li	%r1,0
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return

do_vextractd:
	rlwimi	%r5,%r4,LOBIT-3,LO	# put bit 3 of index into r5
	mfrin	0,5			# fetch both dwords of VRB
	xori	%r5,%r5,LO
	mfrin	1,5
	rlwinm	%r2,%r4,3,0x38		# shift count from bits 0-2
	sld	%r0,%r0,%r2
	rotld	%r1,%r1,%r2
	li	%r3,1			# mask for bits from r0
	sld	%r3,%r3,%r2
	neg	%r3,%r3
	andc	%r1,%r1,%r3
	or	%r0,%r0,%r1
	mtrin	0,6
	li	%r1,0
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return

do_vextublx:
	clrldi	%r4,%r4,59		# RT and RA are GPRs not VRs
	mfrin	2,4			# RA = byte index
2:	clrldi	%r6,%r6,59
	rlwimi	%r5,%r2,LOBIT-3,LO	# put bit 3 of index into r5
	rlwinm	%r2,%r2,3,0x38		# shift count from bits 0-2
	mfrin	1,5
	sld	%r1,%r1,%r2		# target byte to MSB
	srdi	%r1,%r1,56		# move it to LSB
	mtrin	1,6
	b	return

do_vextubrx:
	clrldi	%r4,%r4,59		# RT and RA are GPRs not VRs
	mfrin	2,4			# RA = byte index
	not	%r2,%r2			# convert to big-endian index
	b	2b

do_vextuhlx:
	clrldi	%r4,%r4,59		# RT and RA are GPRs not VRs
	mfrin	2,4			# RA = byte index (0 = MSB)
2:	clrldi	%r6,%r6,59
	rlwimi	%r5,%r2,LOBIT-3,LO	# put bit 3 of index into r5
	mfrin	0,5			# fetch both dwords of VRB
	xori	%r5,%r5,LO
	mfrin	1,5
	rlwinm	%r2,%r2,3,0x38		# shift count from bits 0-2
	sld	%r0,%r0,%r2
	rotld	%r1,%r1,%r2
	li	%r3,1			# mask for bits from r0
	sld	%r3,%r3,%r2
	neg	%r3,%r3
	andc	%r1,%r1,%r3
	or	%r0,%r0,%r1
	srdi	%r0,%r0,48		# move bytes 0:1 to right end
	mtrin	0,6
	b	return

do_vextuhrx:
	clrldi	%r4,%r4,59		# RT and RA are GPRs not VRs
	mfrin	0,4			# RA = byte index
	li	%r2,14			# convert to big-endian index
	subf	%r2,%r0,%r2
	b	2b

do_vextuwlx:
	clrldi	%r4,%r4,59		# RT and RA are GPRs not VRs
	mfrin	2,4			# RA = byte index (0 = MSB)
2:	clrldi	%r6,%r6,59
	rlwimi	%r5,%r2,LOBIT-3,LO	# put bit 3 of index into r5
	mfrin	0,5			# fetch both dwords of VRB
	xori	%r5,%r5,LO
	mfrin	1,5
	rlwinm	%r2,%r2,3,0x38		# shift count from bits 0-2
	sld	%r0,%r0,%r2
	rotld	%r1,%r1,%r2
	li	%r3,1			# mask for bits from r0
	sld	%r3,%r3,%r2
	neg	%r3,%r3
	andc	%r1,%r1,%r3
	or	%r0,%r0,%r1
	srdi	%r0,%r0,32		# move bytes 0:3 to right end
	mtrin	0,6
	b	return

do_vextuwrx:
	clrldi	%r4,%r4,59		# RT and RA are GPRs not VRs
	mfrin	0,4			# RA = byte index
	li	%r2,12			# convert to big-endian index
	subf	%r2,%r0,%r2
	b	2b

do_vextractbm:
	clrldi	%r6,%r6,59		# RT is a GPR
	li	%r3,0
	li	%r11,8
1:	mfrin	1,5
	rotldi	%r1,%r1,1
	mtctr	%r11
2:	rotldi	%r3,%r3,1
	rldimi	%r3,%r1,0,63
	rotldi	%r1,%r1,8
	bdnz	2b
	andi.	%r0,%r5,LO
	addi	%r5,%r5,LO
	beq	1b
	mtrin	3,6
	b	return

do_vextracthm:
	clrldi	%r6,%r6,59		# RT is a GPR
	li	%r3,0
	li	%r11,4
1:	mfrin	1,5
	rotldi	%r1,%r1,1
	mtctr	%r11
2:	rotldi	%r3,%r3,1
	rldimi	%r3,%r1,0,63
	rotldi	%r1,%r1,16
	bdnz	2b
	andi.	%r0,%r5,LO
	addi	%r5,%r5,LO
	beq	1b
	mtrin	3,6
	b	return

do_vextractwm:
	clrldi	%r6,%r6,59		# RT is a GPR
	li	%r3,0
	li	%r11,2
1:	mfrin	1,5
	rotldi	%r1,%r1,1
	mtctr	%r11
2:	rotldi	%r3,%r3,1
	rldimi	%r3,%r1,0,63
	rotldi	%r1,%r1,32
	bdnz	2b
	andi.	%r0,%r5,LO
	addi	%r5,%r5,LO
	beq	1b
	mtrin	3,6
	b	return

do_vextractdm:
	clrldi	%r6,%r6,59		# RT is a GPR
	mfrin	1,5
	rldicl	%r3,%r1,1,63
	sldi	%r3,%r3,1
	addi	%r5,%r5,LO
	mfrin	1,5
	rldicl	%r1,%r1,1,63
	or	%r3,%r3,%r1
	mtrin	3,6
	b	return

do_vextractqm:
	clrldi	%r6,%r6,59		# RT is a GPR
	mfrin	1,5
	rldicl	%r3,%r1,1,63
	mtrin	3,6
	b	return

do_vmsumubm:
	li	%r11,2
1:	mfrin	8,4
	mfrin	9,5
	mfrin	10,7
	mtctr	%r11
2:	rotldi	%r10,%r10,32
	rotldi	%r8,%r8,32
	rotldi	%r9,%r9,32
	clrldi	%r0,%r8,56
	clrldi	%r1,%r9,56
	mullw	%r2,%r0,%r1
	rldicl	%r0,%r8,56,56
	rldicl	%r1,%r9,56,56
	add	%r3,%r10,%r2
	mullw	%r2,%r0,%r1
	rldicl	%r0,%r8,48,56
	rldicl	%r1,%r9,48,56
	add	%r3,%r3,%r2
	mullw	%r2,%r0,%r1
	rldicl	%r0,%r8,40,56
	rldicl	%r1,%r9,40,56
	mullw	%r0,%r0,%r1
	add	%r3,%r3,%r2
	add	%r3,%r3,%r0
	rldimi	%r10,%r3,0,32
	bdnz	2b
	mtrin	10,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	addi	%r7,%r7,LO
	b	1b

do_vmsummbm:
	li	%r11,2
1:	mfrin	8,4
	mfrin	9,5
	mfrin	10,7
	mtctr	%r11
2:	rotldi	%r10,%r10,32
	rotldi	%r8,%r8,32
	rotldi	%r9,%r9,32
	extsb	%r0,%r8
	clrldi	%r1,%r9,56
	mullw	%r2,%r0,%r1
	rldicl	%r0,%r8,56,56
	extsb	%r0,%r0
	rldicl	%r1,%r9,56,56
	add	%r3,%r10,%r2
	mullw	%r2,%r0,%r1
	rldicl	%r0,%r8,48,56
	extsb	%r0,%r0
	rldicl	%r1,%r9,48,56
	add	%r3,%r3,%r2
	mullw	%r2,%r0,%r1
	rldicl	%r0,%r8,40,56
	extsb	%r0,%r0
	rldicl	%r1,%r9,40,56
	mullw	%r0,%r0,%r1
	add	%r3,%r3,%r2
	add	%r3,%r3,%r0
	rldimi	%r10,%r3,0,32
	bdnz	2b
	mtrin	10,6
	andi.	%r0,%r6,LO
	bne	return
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	addi	%r6,%r6,LO
	addi	%r7,%r7,LO
	b	1b

do_xxbrh:
	mfrin	1,5
	brh	%r1,%r1
	mtrin	1,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	1,5
	brh	%r1,%r1
	mtrin	1,6
	b	return

do_xxbrw:
	mfrin	1,5
	brw	%r1,%r1
	mtrin	1,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	1,5
	brw	%r1,%r1
	mtrin	1,6
	b	return

do_xxbrd:
	mfrin	1,5
	brd	%r1,%r1
	mtrin	1,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	1,5
	brd	%r1,%r1
	mtrin	1,6
	b	return

do_xxbrq:
	mfrin	1,5
	brd	%r1,%r1
	ori	%r5,%r5,LO
	mfrin	0,5
	brd	%r0,%r0
	mtrin	0,6
	ori	%r6,%r6,LO
	mtrin	1,6
	b	return

# common preliminary code for binary scalar floating-point ops
xsb_prolog:
	# enable floating-point and VSX
	mfmsr	%r8
	ori	%r8,%r8,MSR_FP
	oris	%r8,%r8,MSR_VSX@h
	mtmsrd	%r8
	# save a couple of FPRs and their VSR low halves
	mffprd	%r24,%f0
	mfvsrld	%r25,%vs0
	mffprd	%r26,%f1
	mfvsrld	%r27,%vs1
	# get parameters
	mfrin	2,4
	mfrin	3,5
	# save FPSCR
	mffs	%f0
	mffprd	%r28,%f0
	# put parameters in FP regs
	mtfprd	%f0,%r2
	mtfprd	%f1,%r3
	blr

check_snan:
	# is either operand, r2 or r3, a signaling NaN?
	# clears cr1.so if neither is, leaves unmodified otherwise
	# may destroy values in r2 and r3
	rotldi	%r2,%r2,12	# move sign and exponent to right end
	cmpdi	%r2,0x1000	# check if any mantissa bit is set
	blt	1f		# and MSB of mantissa is 0
	clrldi	%r2,%r2,53	# get exponent
	cmpdi	%r2,0x7ff
	beq	3f		# if XA was SNaN
1:	rotldi	%r3,%r3,12	# move sign and exponent to right end
	cmpdi	%r3,0x1000	# check if any mantissa bit is set
	blt	2f		# and MSB of mantissa is 0
	clrldi	%r3,%r3,53	# get exponent
	cmpdi	%r3,0x7ff
	beq	3f		# if XB was SNaN
2:	crclr	1*4+3		# neither was SNaN, no exception
3:	blr

do_xscmpeqdp:
	mflr	%r23
	bl	xsb_prolog
	fcmpu	%cr1,%f0,%f1
	setnbc	%r0,1*4+2
	bf+	1*4+3,xscmp_finish	# if neither operand is a NaN
	bl	check_snan
	li	%r0,0
	b	xscmp_finish

do_xscmpgtdp:
	mflr	%r23
	bl	xsb_prolog
	fcmpo	%cr1,%f0,%f1
	setnbc	%r0,1*4+1
	b	xscmp_finish

do_xscmpgedp:
	mflr	%r23
	bl	xsb_prolog
	fcmpo	%cr1,%f0,%f1
	setnbcr	%r0,1*4+0

xscmp_finish:
	li	%r3,0
xsmm_finish:
	li	%r1,0
	# restore FPCC and FPRs and their low halves
	# do this before writing results in case dest is vs0 or vs1
	mtfprd	%f0,%r28
	mtfsf	0x08,%f0
	mtvsrdd	%vs0,%r24,%r25
	mtvsrdd	%vs1,%r26,%r27
	isync
	mtlr	%r23
	bt	1*4+3,1f		# if VXSNAN or VXVC got set
2:	mtrin	0,6
	addi	%r6,%r6,LO
	mtrin	1,6
	b	return
1:	mr	%r0,%r3
	andi.	%r1,%r28,FPS_VE
	beq	2b
	b	return

do_xsmincdp:
	mflr	%r23
	bl	xsb_prolog
	mr	%r0,%r3			# answer defaults to B
	fcmpu	%cr1,%f0,%f1
	bt	1*4+3,1f		# if either operand is a NaN
	bge	%cr1,xsmm_finish
	mr	%r0,%r2
	b	xsmm_finish
1:	bl	check_snan
	mr	%r3,%r0
	b	xsmm_finish

do_xsmaxcdp:
	mflr	%r23
	bl	xsb_prolog
	mr	%r0,%r3			# answer defaults to B
	fcmpu	%cr1,%f0,%f1
	bt	1*4+3,1b		# if either operand is a NaN
	ble	%cr1,xsmm_finish
	mr	%r0,%r2
	b	xsmm_finish

# common preliminary code for binary vector FP ops
xvarith_prolog:
	li	%r15,FPS_VE|FPS_OE|FPS_UE|FPS_ZE|FPS_XE	# exceptions that cause result suppression
	# enable floating-point and VSX
	mfmsr	%r8
	ori	%r8,%r8,MSR_FP
	oris	%r8,%r8,MSR_VSX@h
	mtmsrd	%r8
	# save a couple of FPRs and their VSR low halves
	mffprd	%r24,%f0
	mfvsrld	%r25,%vs0
	mffprd	%r26,%f1
	mfvsrld	%r27,%vs1
	# get parameters
	mfrin	12,4
	mfrin	13,5
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	mfrin	16,4
	mfrin	17,5
	xori	%r4,%r4,LO
	xori	%r5,%r5,LO
	# save FPSCR
	mffs	%f0
	mffprd	%r28,%f0
	lis	%r10,FPS_ALLX@h
	ori	%r10,%r10,FPS_ALLX@l
	and.	%r0,%r28,%r15		# check for enabled exceptions
	beq+	1f
	andc	%r0,%r28,%r10		# if so, clear all sticky exception flags
	mtfprd	%f0,%r0
	mtfsf	0xf4,%f0
1:	blr

# convert single-precision FP value in %r3 to double
conv_spdp:
	rldic	%r0,%r3,29,12		# extract mantissa
	rlwinm.	%r1,%r3,9,0xff		# extract exponent
	rldicr	%r3,%r3,32,0		# extract sign
	beq	1f			# if 0 or denorm
	or	%r3,%r3,%r0		# insert mantissa
	cmpdi	%r1,0xff
	beq	9f			# if infinity or NaN
	addi	%r1,%r1,0x380
	rldimi	%r3,%r1,52,1		# insert exponent
	blr
1:	cmpdi	%r0,0
	beqlr				# if +/- zero, done
	cntlzd	%r1,%r0			# otherwise, normalize
	addi	%r1,%r1,-11
	sld	%r0,%r0,%r1
	or	%r3,%r3,%r0		# insert mantissa
	li	%r2,1023-126
	subf	%r1,%r1,%r2
	rldimi	%r3,%r1,52,1		# insert exponent
	blr
9:	li	%r1,0x7ff
	rldimi	%r3,%r1,52,1		# insert exponent
	blr

# convert double-precision FP value in %r3 to single
conv_dpsp:
	rldicl	%r0,%r3,12,53		# extract exponent
	cmpdi	%r0,896
	ble	2f			# if denorm or zero
	rldimi	%r3,%r3,3,2
	srdi	%r3,%r3,32
	blr
2:	# may have to denormalize
	rldicl	%r1,%r3,35,41		# extract top 23 bits of mantissa
	clrrdi	%r3,%r3,63		# isolate sign bit
	srdi	%r3,%r3,32
	cmpdi	%r0,874
	bltlr				# if zero or practically zero
	oris	%r1,%r1,(1<<23)@h	# set implied unit bit
	li	%r2,897
	subf	%r0,%r0,%r2
	srd	%r1,%r1,%r0
	or	%r3,%r3,%r1
	blr

do_xvaddsp:
	mflr	%r23
	bl	xvarith_prolog
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r12,%r12,32		# get next vector elements
	rotldi	%r13,%r13,32
	mr	%r3,%r12
	bl	conv_spdp
	mtfprd	%f0,%r3
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f1,%r3
	fadds	%f0,%f0,%f1
	mffprd	%r3,%f0
	bl	conv_dpsp
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r4,LO
	bne	xvarith_finish
	ori	%r4,%r4,LO
	mr	%r12,%r16
	mr	%r13,%r17
	mr	%r8,%r9
	b	1b

do_xvadddp:
	mflr	%r23
	bl	xvarith_prolog
	mtfprd	%f0,%r12
	mtfprd	%f1,%r13
	fadd	%f0,%f0,%f1
	mffprd	%r8,%f0
	mtfprd	%f0,%r16
	mtfprd	%f1,%r17
	fadd	%f0,%f0,%f1
	mffprd	%r9,%f0
	b	xvarith_finish

do_xvdivsp:
	mflr	%r23
	bl	xvarith_prolog
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r12,%r12,32		# get next vector elements
	rotldi	%r13,%r13,32
	mr	%r3,%r12
	bl	conv_spdp
	mtfprd	%f0,%r3
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f1,%r3
	fdivs	%f0,%f0,%f1
	mffprd	%r3,%f0
	bl	conv_dpsp
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r4,LO
	bne	xvarith_finish
	ori	%r4,%r4,LO
	mr	%r12,%r16
	mr	%r13,%r17
	mr	%r8,%r9
	b	1b

do_xvdivdp:
	mflr	%r23
	bl	xvarith_prolog
	mtfprd	%f0,%r12
	mtfprd	%f1,%r13
	fdiv	%f0,%f0,%f1
	mffprd	%r8,%f0
	mtfprd	%f0,%r16
	mtfprd	%f1,%r17
	fdiv	%f0,%f0,%f1
	mffprd	%r9,%f0
	b	xvarith_finish

do_xvmulsp:
	mflr	%r23
	bl	xvarith_prolog
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r12,%r12,32		# get next vector elements
	rotldi	%r13,%r13,32
	mr	%r3,%r12
	bl	conv_spdp
	mtfprd	%f0,%r3
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f1,%r3
	fmuls	%f0,%f0,%f1
	mffprd	%r3,%f0
	bl	conv_dpsp
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r4,LO
	bne	xvarith_finish
	ori	%r4,%r4,LO
	mr	%r12,%r16
	mr	%r13,%r17
	mr	%r8,%r9
	b	1b

do_xvmuldp:
	mflr	%r23
	bl	xvarith_prolog
	mtfprd	%f0,%r12
	mtfprd	%f1,%r13
	fmul	%f0,%f0,%f1
	mffprd	%r8,%f0
	mtfprd	%f0,%r16
	mtfprd	%f1,%r17
	fmul	%f0,%f0,%f1
	mffprd	%r9,%f0
	b	xvarith_finish

do_xvsubsp:
	mflr	%r23
	bl	xvarith_prolog
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r12,%r12,32		# get next vector elements
	rotldi	%r13,%r13,32
	mr	%r3,%r12
	bl	conv_spdp
	mtfprd	%f0,%r3
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f1,%r3
	fsubs	%f0,%f0,%f1
	mffprd	%r3,%f0
	bl	conv_dpsp
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r4,LO
	bne	xvarith_finish
	ori	%r4,%r4,LO
	mr	%r12,%r16
	mr	%r13,%r17
	mr	%r8,%r9
	b	1b

do_xvsubdp:
	mflr	%r23
	bl	xvarith_prolog
	mtfprd	%f0,%r12
	mtfprd	%f1,%r13
	fsub	%f0,%f0,%f1
	mffprd	%r8,%f0
	mtfprd	%f0,%r16
	mtfprd	%f1,%r17
	fsub	%f0,%f0,%f1
	mffprd	%r9,%f0
	b	xvarith_finish

do_xvsqrtsp:
	mflr	%r23
	bl	xvarith_prolog
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r13,%r13,32		# get next vector element
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f0,%r3
	fsqrts	%f0,%f0
	mffprd	%r3,%f0
	bl	conv_dpsp
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r5,LO
	bne	xvarith_finish
	mr	%r13,%r17
	ori	%r5,%r5,LO
	mr	%r8,%r9
	b	1b

do_xvsqrtdp:
	mflr	%r23
	bl	xvarith_prolog
	mtfprd	%f0,%r13
	fsqrt	%f0,%f0
	mffprd	%r8,%f0
	mtfprd	%f0,%r17
	fsqrt	%f0,%f0
	mffprd	%r9,%f0
	b	xvarith_finish

# result is in r8/r9, check for enabled exceptions
# vector ops only affect exception flags in FPSCR, not FPRF/FR/FI
xvarith_finish:
	mffs	%f0
	mffprd	%r1,%f0			# get current FPSCR
	andc	%r0,%r1,%r28		# any exception flags newly set?
	and.	%r0,%r0,%r10
	beq	1f
	or	%r28,%r28,%r0		# set them in saved FPSCR
	oris	%r28,%r28,FPS_FX@h	# and also set FX
1:	mtfprd	%f0,%r28		# restore FPSCR + new exception bits
	mtfsf	0xff,%f0
	# restore FPRs and low halves before writing results
	mtvsrdd	%vs0,%r24,%r25
	mtvsrdd	%vs1,%r26,%r27
	and.	%r0,%r28,%r15		# test for enabled exception
	beq+	4f
	sldi	%r0,%r0,22		# move VE->VX, ZE->ZX etc.
	and.	%r0,%r0,%r1		# enabled exception occurred?
	bne	5f			# if so don't write result
4:	mtrin	8,6
	ori	%r6,%r6,LO
	mtrin	9,6
5:	mtlr	%r23
	b	return
