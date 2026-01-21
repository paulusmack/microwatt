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
	.long	do_vcipher - vcol8		# row 20
	.long	do_vncipher - vcol8
	.long	0
	.long	do_vsbox - vcol8
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
	.long	do_vcipherlast - vcol9		# row 20
	.long	do_vncipherlast - vcol9
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
	.long	xcol4 - op60_table
	.long	xcol4 - op60_table
	.long	xcol8 - op60_table
	.long	xcol8 - op60_table
	.long	xcol12 - op60_table
	.long	xcol12 - op60_table
	.long	xcol16 - op60_table			# column 16,17
	.long	xcol18 - op60_table
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
	.long	do_xvcpsgnsp - xcol0
	.long	0
	.long	0
	.long	0
	.long	do_xvcpsgndp - xcol0		# row 30
	.long	0

xcol4:
	.long	do_xsmaddasp-xcol4		# row 0
	.long	do_xsmaddmsp-xcol4
	.long	do_xsmsubasp-xcol4
	.long	do_xsmsubmsp-xcol4
	.long	do_xsmaddadp-xcol4		# row 4
	.long	do_xsmaddmdp-xcol4
	.long	do_xsmsubadp-xcol4
	.long	do_xsmsubmdp-xcol4
	.long	do_xvmaddasp-xcol4		# row 8
	.long	do_xvmaddmsp-xcol4
	.long	do_xvmsubasp-xcol4
	.long	do_xvmsubmsp-xcol4
	.long	do_xvmaddadp-xcol4		# row 12
	.long	do_xvmaddmdp-xcol4
	.long	do_xvmsubadp-xcol4
	.long	do_xvmsubmdp-xcol4
	.long	do_xsnmaddasp-xcol4
	.long	do_xsnmaddmsp-xcol4
	.long	do_xsnmsubasp-xcol4
	.long	do_xsnmsubmsp-xcol4
	.long	do_xsnmaddadp-xcol4		# row 20
	.long	do_xsnmaddmdp-xcol4
	.long	do_xsnmsubadp-xcol4
	.long	do_xsnmsubmdp-xcol4
	.long	do_xvnmaddasp-xcol4
	.long	do_xvnmaddmsp-xcol4
	.long	do_xvnmsubasp-xcol4
	.long	do_xvnmsubmsp-xcol4
	.long	do_xvnmaddadp-xcol4
	.long	do_xvnmaddmdp-xcol4
	.long	do_xvnmsubadp-xcol4		# row 30
	.long	do_xvnmsubmdp-xcol4

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

xcol16:
	.long	0		# row 0
	.long	0
	.long	0
	.long	0
	.long	0		# row 4
	.long	0
	.long	0
	.long	0
	.long	do_xvcvspuxws - xcol16		# row 8
	.long	do_xvcvspsxws - xcol16
	.long	do_xvcvuxwsp - xcol16
	.long	do_xvcvsxwsp - xcol16
	.long	do_xvcvdpuxws - xcol16		# row 12
	.long	do_xvcvdpsxws - xcol16
	.long	do_xvcvuxwdp - xcol16
	.long	do_xvcvsxwdp - xcol16
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0		# row 20
	.long	0
	.long	0
	.long	0
	.long	do_xvcvspuxds - xcol16
	.long	do_xvcvspsxds - xcol16
	.long	do_xvcvuxdsp - xcol16
	.long	do_xvcvsxdsp - xcol16
	.long	do_xvcvdpuxds - xcol16
	.long	do_xvcvdpsxds - xcol16
	.long	do_xvcvuxddp - xcol16		# row 30
	.long	do_xvcvsxddp - xcol16

xcol18:
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
	.long	do_xvabssp - xcol18
	.long	do_xvnabssp - xcol18
	.long	do_xvnegsp - xcol18
	.long	0
	.long	do_xvabsdp - xcol18
	.long	do_xvnabsdp - xcol18		# row 30
	.long	do_xvnegdp - xcol18

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
xvarith_prolog_xx:
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

# common preliminary code for 3-operand vector/scalar FP ops
xv3arith_prolog_xany:
	li	%r15,FPS_VE|FPS_OE|FPS_UE|FPS_ZE|FPS_XE
	# get low halves of parameter regs
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	16,4
	mfrin	17,5
	mfrin	18,6
	xori	%r4,%r4,LO
	xori	%r5,%r5,LO
	xori	%r6,%r6,LO
	b	1f
xs3arith_prolog:
	li	%r15,FPS_VE		# exceptions that cause result suppression
	# enable floating-point and VSX
1:	mfmsr	%r8
	ori	%r8,%r8,MSR_FP
	oris	%r8,%r8,MSR_VSX@h
	mtmsrd	%r8
	# save three FPRs and their VSR low halves
	mffprd	%r24,%f0
	mfvsrld	%r25,%vs0
	mffprd	%r26,%f1
	mfvsrld	%r27,%vs1
	mffprd	%r21,%f2
	mfvsrld	%r22,%vs2
	# get parameters
	mfrin	12,4
	mfrin	13,5
	mfrin	14,6
	# save FPSCR
	mffs	%f0
	mffprd	%r28,%f0
	lis	%r10,FPS_ALLX@h
	ori	%r10,%r10,FPS_ALLX@l
	and.	%r0,%r28,%r15		# check for enabled invalid exception
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
xv3arith_finish:
	mtvsrdd	%vs2,%r21,%r22
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

# Like xvarith_finish, except scalar ops do update fprf/fr/fi.
# FPSCR is correct, except that we may need to put back
# exception bits if we cleared them earlier.
# Write back result if no enabled invalid operation exception occurred.
xs3arith_finish:
	mffprd	%r8,%f0
	li	%r9,0
	mtvsrdd	%vs2,%r21,%r22
	and.	%r3,%r28,%r15		# test for enabled relevant exception
	beq+	3f			# if none, then FPSCR is correct
	mffs	%f0
	mffprd	%r1,%f0			# get current FPSCR
	andc	%r0,%r1,%r28		# any exception flags newly set?
	and.	%r0,%r0,%r10
	setbc	%r0,EQ			# if none, clear FX
	sldi	%r0,%r0,31
	andc	%r1,%r1,%r0
	oris	%r10,%r10,FPS_FX@h
	and	%r2,%r28,%r10		# get saved exception flags and FX
	or	%r1,%r1,%r2
	mtfprd	%f0,%r1			# set them in FPSCR
	mtfsf	0xff,%f0
	sldi	%r0,%r3,22		# move VE->VX
	and.	%r0,%r0,%r1		# see if VX is set
	# restore FPRs and low halves before writing results
3:	mtvsrdd	%vs0,%r24,%r25
	mtvsrdd	%vs1,%r26,%r27
	bne	5f			# don't write result if enabled exception
4:	mtrin	8,6
	ori	%r6,%r6,LO
	mtrin	9,6
5:	mtlr	%r23
	b	return

do_xvcvdpsxds:
	mflr	%r23
	li	%r15,FPS_VE|FPS_XE
	bl	xvarith_prolog_xx
	mtfprd	%f0,%r13
	fctidz	%f0,%f0
	mffprd	%r8,%f0
	mtfprd	%f0,%r17
	fctidz	%f0,%f0
	mffprd	%r9,%f0
	b	xvarith_finish

do_xvcvdpsxws:
	mflr	%r23
	li	%r15,FPS_VE|FPS_XE
	bl	xvarith_prolog_xx
	mtfprd	%f0,%r13
	fctiwz	%f0,%f0
	mffprd	%r8,%f0
	rldimi	%r8,%r8,32,0
	mtfprd	%f0,%r17
	fctiwz	%f0,%f0
	mffprd	%r9,%f0
	rldimi	%r9,%r9,32,0
	b	xvarith_finish

do_xvcvdpuxds:
	mflr	%r23
	li	%r15,FPS_VE|FPS_XE
	bl	xvarith_prolog_xx
	mtfprd	%f0,%r13
	fctiduz	%f0,%f0
	mffprd	%r8,%f0
	mtfprd	%f0,%r17
	fctiduz	%f0,%f0
	mffprd	%r9,%f0
	b	xvarith_finish

do_xvcvdpuxws:
	mflr	%r23
	li	%r15,FPS_VE|FPS_XE
	bl	xvarith_prolog_xx
	mtfprd	%f0,%r13
	fctiwuz	%f0,%f0
	mffprd	%r8,%f0
	rldimi	%r8,%r8,32,0
	mtfprd	%f0,%r17
	fctiwuz	%f0,%f0
	mffprd	%r9,%f0
	rldimi	%r9,%r9,32,0
	b	xvarith_finish

do_xvcvspsxds:
	mflr	%r23
	li	%r15,FPS_VE|FPS_XE
	bl	xvarith_prolog_xx
	srdi	%r3,%r13,32
	bl	conv_spdp
	mtfprd	%f0,%r3
	fctidz	%f0,%f0
	mffprd	%r8,%f0
	srdi	%r3,%r17,32
	bl	conv_spdp
	mtfprd	%f0,%r3
	fctidz	%f0,%f0
	mffprd	%r9,%f0
	b	xvarith_finish

do_xvcvspsxws:
	mflr	%r23
	li	%r15,FPS_VE|FPS_XE
	bl	xvarith_prolog_xx
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r13,%r13,32		# get next vector element
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f0,%r3
	fctiwz	%f0,%f0
	mffprd	%r3,%f0
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r5,LO
	bne	xvarith_finish
	mr	%r13,%r17
	ori	%r5,%r5,LO
	mr	%r8,%r9
	b	1b

do_xvcvspuxds:
	mflr	%r23
	li	%r15,FPS_VE|FPS_XE
	bl	xvarith_prolog_xx
	srdi	%r3,%r13,32
	bl	conv_spdp
	mtfprd	%f0,%r3
	fctiduz	%f0,%f0
	mffprd	%r8,%f0
	srdi	%r3,%r17,32
	bl	conv_spdp
	mtfprd	%f0,%r3
	fctiduz	%f0,%f0
	mffprd	%r9,%f0
	b	xvarith_finish

do_xvcvspuxws:
	mflr	%r23
	li	%r15,FPS_VE|FPS_XE
	bl	xvarith_prolog_xx
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r13,%r13,32		# get next vector element
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f0,%r3
	fctiwuz	%f0,%f0
	mffprd	%r3,%f0
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r5,LO
	bne	xvarith_finish
	mr	%r13,%r17
	ori	%r5,%r5,LO
	mr	%r8,%r9
	b	1b

do_xvcvsxddp:
	mflr	%r23
	li	%r15,FPS_XE
	bl	xvarith_prolog_xx
	mtfprd	%f0,%r13
	fcfid	%f0,%f0
	mffprd	%r8,%f0
	mtfprd	%f0,%r17
	fcfid	%f0,%f0
	mffprd	%r9,%f0
	b	xvarith_finish

do_xvcvuxddp:
	mflr	%r23
	li	%r15,FPS_XE
	bl	xvarith_prolog_xx
	mtfprd	%f0,%r13
	fcfidu	%f0,%f0
	mffprd	%r8,%f0
	mtfprd	%f0,%r17
	fcfidu	%f0,%f0
	mffprd	%r9,%f0
	b	xvarith_finish

do_xvcvsxwdp:
	mflr	%r23
	li	%r15,0
	bl	xvarith_prolog_xx
	srdi	%r3,%r13,32
	extsw	%r3,%r3
	mtfprd	%f0,%r3
	fcfid	%f0,%f0
	mffprd	%r8,%f0
	srdi	%r3,%r17,32
	extsw	%r3,%r3
	mtfprd	%f0,%r3
	fcfid	%f0,%f0
	mffprd	%r9,%f0
	b	xvarith_finish

do_xvcvuxwdp:
	mflr	%r23
	li	%r15,0
	bl	xvarith_prolog_xx
	srdi	%r3,%r13,32
	mtfprd	%f0,%r3
	fcfidu	%f0,%f0
	mffprd	%r8,%f0
	srdi	%r3,%r17,32
	mtfprd	%f0,%r3
	fcfidu	%f0,%f0
	mffprd	%r9,%f0
	b	xvarith_finish

do_xvcvsxdsp:
	mflr	%r23
	li	%r15,FPS_XE
	bl	xvarith_prolog_xx
	mtfprd	%f0,%r13
	fcfids	%f0,%f0
	mffprd	%r3,%f0
	bl	conv_dpsp
	mr	%r8,%r3
	rldimi	%r8,%r8,32,0
	mtfprd	%f0,%r17
	fcfids	%f0,%f0
	mffprd	%r3,%f0
	bl	conv_dpsp
	mr	%r9,%r3
	rldimi	%r9,%r9,32,0
	b	xvarith_finish

do_xvcvuxdsp:
	mflr	%r23
	li	%r15,FPS_XE
	bl	xvarith_prolog_xx
	mtfprd	%f0,%r13
	fcfidus	%f0,%f0
	mffprd	%r3,%f0
	bl	conv_dpsp
	mr	%r8,%r3
	rldimi	%r8,%r8,32,0
	mtfprd	%f0,%r17
	fcfidus	%f0,%f0
	mffprd	%r3,%f0
	bl	conv_dpsp
	mr	%r9,%r3
	rldimi	%r9,%r9,32,0
	b	xvarith_finish

do_xvcvsxwsp:
	mflr	%r23
	li	%r15,FPS_XE
	bl	xvarith_prolog_xx
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r13,%r13,32		# get next vector element
	extsw	%r3,%r13
	mtfprd	%f0,%r3
	fcfids	%f0,%f0
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

do_xvcvuxwsp:
	mflr	%r23
	li	%r15,FPS_XE
	bl	xvarith_prolog_xx
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r13,%r13,32		# get next vector element
	clrldi	%r3,%r13,32
	mtfprd	%f0,%r3
	fcfidus	%f0,%f0
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

do_xsmaddadp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r13			# XB
	mtfprd	%f2,%r14			# XT
1:	fmadd	%f0,%f0,%f1,%f2
	b	xs3arith_finish

do_xsmaddmdp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r14			# XT
	mtfprd	%f2,%r13			# XB
	b	1b

do_xsmaddasp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r13			# XB
	mtfprd	%f2,%r14			# XT
1:	fmadds	%f0,%f0,%f1,%f2
	b	xs3arith_finish

do_xsmaddmsp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r14			# XT
	mtfprd	%f2,%r13			# XB
	b	1b

do_xsmsubadp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r13			# XB
	mtfprd	%f2,%r14			# XT
1:	fmsub	%f0,%f0,%f1,%f2
	b	xs3arith_finish

do_xsmsubmdp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r14			# XT
	mtfprd	%f2,%r13			# XB
	b	1b

do_xsmsubasp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r13			# XB
	mtfprd	%f2,%r14			# XT
1:	fmsubs	%f0,%f0,%f1,%f2
	b	xs3arith_finish

do_xsmsubmsp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r14			# XT
	mtfprd	%f2,%r13			# XB
	b	1b

do_xsnmaddadp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r13			# XB
	mtfprd	%f2,%r14			# XT
1:	fnmadd	%f0,%f0,%f1,%f2
	b	xs3arith_finish

do_xsnmaddmdp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r14			# XT
	mtfprd	%f2,%r13			# XB
	b	1b

do_xsnmaddasp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r13			# XB
	mtfprd	%f2,%r14			# XT
1:	fnmadds	%f0,%f0,%f1,%f2
	b	xs3arith_finish

do_xsnmaddmsp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r14			# XT
	mtfprd	%f2,%r13			# XB
	b	1b

do_xsnmsubadp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r13			# XB
	mtfprd	%f2,%r14			# XT
1:	fnmsub	%f0,%f0,%f1,%f2
	b	xs3arith_finish

do_xsnmsubmdp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r14			# XT
	mtfprd	%f2,%r13			# XB
	b	1b

do_xsnmsubasp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r13			# XB
	mtfprd	%f2,%r14			# XT
1:	fnmsubs	%f0,%f0,%f1,%f2
	b	xs3arith_finish

do_xsnmsubmsp:
	mflr	%r23
	bl	xs3arith_prolog
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r14			# XT
	mtfprd	%f2,%r13			# XB
	b	1b

do_xvmaddadp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r13			# XB
	mtfprd	%f2,%r14			# XT
	fmadd	%f0,%f0,%f1,%f2
	mffprd	%r8,%f0
	mtfprd	%f0,%r16			# XA
	mtfprd	%f1,%r17			# XB
	mtfprd	%f2,%r18			# XT
	fmadd	%f0,%f0,%f1,%f2
	mffprd	%r9,%f0
	b	xv3arith_finish

do_xvmaddmdp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	mtfprd	%f0,%r12			# XA
	mtfprd	%f1,%r14			# XT
	mtfprd	%f2,%r13			# XB
	fmadd	%f0,%f0,%f1,%f2
	mffprd	%r8,%f0
	mtfprd	%f0,%r16			# XA
	mtfprd	%f1,%r18			# XT
	mtfprd	%f2,%r17			# XB
	fmadd	%f0,%f0,%f1,%f2
	mffprd	%r9,%f0
	b	xv3arith_finish

do_xvmaddasp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r12,%r12,32		# get next vector elements
	rotldi	%r13,%r13,32
	rotldi	%r14,%r14,32
	mr	%r3,%r12
	bl	conv_spdp
	mtfprd	%f0,%r3
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f1,%r3
	mr	%r3,%r14
	bl	conv_spdp
	mtfprd	%f2,%r3
	fmadds	%f0,%f0,%f1,%f2
	mffprd	%r3,%f0
	bl	conv_dpsp
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r4,LO
	bne	xv3arith_finish
	ori	%r4,%r4,LO
	mr	%r12,%r16
	mr	%r13,%r17
	mr	%r14,%r18
	mr	%r8,%r9
	b	1b

do_xvmaddmsp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r12,%r12,32		# get next vector elements
	rotldi	%r13,%r13,32
	rotldi	%r14,%r14,32
	mr	%r3,%r12
	bl	conv_spdp
	mtfprd	%f0,%r3
	mr	%r3,%r14
	bl	conv_spdp
	mtfprd	%f1,%r3
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f2,%r3
	fmadds	%f0,%f0,%f1,%f2
	mffprd	%r3,%f0
	bl	conv_dpsp
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r4,LO
	bne	xv3arith_finish
	ori	%r4,%r4,LO
	mr	%r12,%r16
	mr	%r13,%r17
	mr	%r14,%r18
	mr	%r8,%r9
	b	1b

do_xvmsubadp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	mtfprd	%f0,%r12
	mtfprd	%f1,%r13
	mtfprd	%f2,%r14
	fmsub	%f0,%f0,%f1,%f2
	mffprd	%r8,%f0
	mtfprd	%f0,%r16
	mtfprd	%f1,%r17
	mtfprd	%f2,%r18
	fmsub	%f0,%f0,%f1,%f2
	mffprd	%r9,%f0
	b	xv3arith_finish

do_xvmsubmdp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	mtfprd	%f0,%r12
	mtfprd	%f1,%r14
	mtfprd	%f2,%r13
	fmsub	%f0,%f0,%f1,%f2
	mffprd	%r8,%f0
	mtfprd	%f0,%r16
	mtfprd	%f1,%r18
	mtfprd	%f2,%r17
	fmsub	%f0,%f0,%f1,%f2
	mffprd	%r9,%f0
	b	xv3arith_finish

do_xvmsubasp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r12,%r12,32		# get next vector elements
	rotldi	%r13,%r13,32
	rotldi	%r14,%r14,32
	mr	%r3,%r12
	bl	conv_spdp
	mtfprd	%f0,%r3
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f1,%r3
	mr	%r3,%r14
	bl	conv_spdp
	mtfprd	%f2,%r3
	fmsubs	%f0,%f0,%f1,%f2
	mffprd	%r3,%f0
	bl	conv_dpsp
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r4,LO
	bne	xv3arith_finish
	ori	%r4,%r4,LO
	mr	%r12,%r16
	mr	%r13,%r17
	mr	%r14,%r18
	mr	%r8,%r9
	b	1b

do_xvmsubmsp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r12,%r12,32		# get next vector elements
	rotldi	%r13,%r13,32
	rotldi	%r14,%r14,32
	mr	%r3,%r12
	bl	conv_spdp
	mtfprd	%f0,%r3
	mr	%r3,%r14
	bl	conv_spdp
	mtfprd	%f1,%r3
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f2,%r3
	fmsubs	%f0,%f0,%f1,%f2
	mffprd	%r3,%f0
	bl	conv_dpsp
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r4,LO
	bne	xv3arith_finish
	ori	%r4,%r4,LO
	mr	%r12,%r16
	mr	%r13,%r17
	mr	%r14,%r18
	mr	%r8,%r9
	b	1b

do_xvnmaddadp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	mtfprd	%f0,%r12
	mtfprd	%f1,%r13
	mtfprd	%f2,%r14
	fnmadd	%f0,%f0,%f1,%f2
	mffprd	%r8,%f0
	mtfprd	%f0,%r16
	mtfprd	%f1,%r17
	mtfprd	%f2,%r18
	fnmadd	%f0,%f0,%f1,%f2
	mffprd	%r9,%f0
	b	xv3arith_finish

do_xvnmaddmdp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	mtfprd	%f0,%r12
	mtfprd	%f1,%r14
	mtfprd	%f2,%r13
	fnmadd	%f0,%f0,%f1,%f2
	mffprd	%r8,%f0
	mtfprd	%f0,%r16
	mtfprd	%f1,%r18
	mtfprd	%f2,%r17
	fnmadd	%f0,%f0,%f1,%f2
	mffprd	%r9,%f0
	b	xv3arith_finish

do_xvnmaddasp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r12,%r12,32		# get next vector elements
	rotldi	%r13,%r13,32
	rotldi	%r14,%r14,32
	mr	%r3,%r12
	bl	conv_spdp
	mtfprd	%f0,%r3
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f1,%r3
	mr	%r3,%r14
	bl	conv_spdp
	mtfprd	%f2,%r3
	fnmadds	%f0,%f0,%f1,%f2
	mffprd	%r3,%f0
	bl	conv_dpsp
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r4,LO
	bne	xv3arith_finish
	ori	%r4,%r4,LO
	mr	%r12,%r16
	mr	%r13,%r17
	mr	%r14,%r18
	mr	%r8,%r9
	b	1b

do_xvnmaddmsp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r12,%r12,32		# get next vector elements
	rotldi	%r13,%r13,32
	rotldi	%r14,%r14,32
	mr	%r3,%r12
	bl	conv_spdp
	mtfprd	%f0,%r3
	mr	%r3,%r14
	bl	conv_spdp
	mtfprd	%f1,%r3
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f2,%r3
	fnmadds	%f0,%f0,%f1,%f2
	mffprd	%r3,%f0
	bl	conv_dpsp
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r4,LO
	bne	xv3arith_finish
	ori	%r4,%r4,LO
	mr	%r12,%r16
	mr	%r13,%r17
	mr	%r14,%r18
	mr	%r8,%r9
	b	1b

do_xvnmsubadp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	mtfprd	%f0,%r12
	mtfprd	%f1,%r13
	mtfprd	%f2,%r14
	fnmsub	%f0,%f0,%f1,%f2
	mffprd	%r8,%f0
	mtfprd	%f0,%r16
	mtfprd	%f1,%r17
	mtfprd	%f2,%r18
	fnmsub	%f0,%f0,%f1,%f2
	mffprd	%r9,%f0
	b	xv3arith_finish

do_xvnmsubmdp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	mtfprd	%f0,%r12
	mtfprd	%f1,%r14
	mtfprd	%f2,%r13
	fnmsub	%f0,%f0,%f1,%f2
	mffprd	%r8,%f0
	mtfprd	%f0,%r16
	mtfprd	%f1,%r18
	mtfprd	%f2,%r17
	fnmsub	%f0,%f0,%f1,%f2
	mffprd	%r9,%f0
	b	xv3arith_finish

do_xvnmsubasp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r12,%r12,32		# get next vector elements
	rotldi	%r13,%r13,32
	rotldi	%r14,%r14,32
	mr	%r3,%r12
	bl	conv_spdp
	mtfprd	%f0,%r3
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f1,%r3
	mr	%r3,%r14
	bl	conv_spdp
	mtfprd	%f2,%r3
	fnmsubs	%f0,%f0,%f1,%f2
	mffprd	%r3,%f0
	bl	conv_dpsp
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r4,LO
	bne	xv3arith_finish
	ori	%r4,%r4,LO
	mr	%r12,%r16
	mr	%r13,%r17
	mr	%r14,%r18
	mr	%r8,%r9
	b	1b

do_xvnmsubmsp:
	mflr	%r23
	bl	xv3arith_prolog_xany
	li	%r11,2
1:	mtctr	%r11
2:	rotldi	%r12,%r12,32		# get next vector elements
	rotldi	%r13,%r13,32
	rotldi	%r14,%r14,32
	mr	%r3,%r12
	bl	conv_spdp
	mtfprd	%f0,%r3
	mr	%r3,%r14
	bl	conv_spdp
	mtfprd	%f1,%r3
	mr	%r3,%r13
	bl	conv_spdp
	mtfprd	%f2,%r3
	fnmsubs	%f0,%f0,%f1,%f2
	mffprd	%r3,%f0
	bl	conv_dpsp
	rotldi	%r9,%r9,32
	rldimi	%r9,%r3,0,32
	bdnz	2b
	andi.	%r0,%r4,LO
	bne	xv3arith_finish
	ori	%r4,%r4,LO
	mr	%r12,%r16
	mr	%r13,%r17
	mr	%r14,%r18
	mr	%r8,%r9
	b	1b

do_xvabsdp:
	mfrin	0,5
	clrldi	%r0,%r0,1
	mtrin	0,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	0,5
	clrldi	%r0,%r0,1
	mtrin	0,6
	b	return

do_xvabssp:
	li	%r1,1
	sldi	%r1,%r1,31
	rldimi	%r1,%r1,32,0
	mfrin	0,5
	andc	%r0,%r0,%r1
	mtrin	0,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	0,5
	andc	%r0,%r0,%r1
	mtrin	0,6
	b	return

do_xvcpsgndp:
	mfrin	0,4
	mfrin	1,5
	rotldi	%r0,%r0,1
	rldimi	%r1,%r0,63,0
	mtrin	1,6
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	rotldi	%r0,%r0,1
	rldimi	%r1,%r0,63,0
	mtrin	1,6
	b	return

do_xvcpsgnsp:
	li	%r2,1
	sldi	%r2,%r2,31
	rldimi	%r2,%r2,32,0
	mfrin	0,4
	mfrin	1,5
	and	%r0,%r0,%r2
	andc	%r1,%r1,%r2
	or	%r0,%r0,%r1
	mtrin	0,6
	ori	%r4,%r4,LO
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	0,4
	mfrin	1,5
	and	%r0,%r0,%r2
	andc	%r1,%r1,%r2
	or	%r0,%r0,%r1
	mtrin	0,6
	b	return

do_xvnabsdp:
	li	%r1,1
	sldi	%r1,%r1,63
	mfrin	0,5
	or	%r0,%r0,%r1
	mtrin	0,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	0,5
	or	%r0,%r0,%r1
	mtrin	0,6
	b	return

do_xvnabssp:
	li	%r1,1
	sldi	%r1,%r1,31
	rldimi	%r1,%r1,32,0
	mfrin	0,5
	or	%r0,%r0,%r1
	mtrin	0,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	0,5
	or	%r0,%r0,%r1
	mtrin	0,6
	b	return

do_xvnegdp:
	li	%r1,1
	sldi	%r1,%r1,63
	mfrin	0,5
	xor	%r0,%r0,%r1
	mtrin	0,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	0,5
	xor	%r0,%r0,%r1
	mtrin	0,6
	b	return

do_xvnegsp:
	li	%r1,1
	sldi	%r1,%r1,31
	rldimi	%r1,%r1,32,0
	mfrin	0,5
	xor	%r0,%r0,%r1
	mtrin	0,6
	ori	%r5,%r5,LO
	ori	%r6,%r6,LO
	mfrin	0,5
	xor	%r0,%r0,%r1
	mtrin	0,6
	b	return

# AES SBOX array
subbytes:
	.byte	0x63,0x7C,0x77,0x7B,0xF2,0x6B,0x6F,0xC5,0x30,0x01,0x67,0x2B,0xFE,0xD7,0xAB,0x76
	.byte	0xCA,0x82,0xC9,0x7D,0xFA,0x59,0x47,0xF0,0xAD,0xD4,0xA2,0xAF,0x9C,0xA4,0x72,0xC0
	.byte	0xB7,0xFD,0x93,0x26,0x36,0x3F,0xF7,0xCC,0x34,0xA5,0xE5,0xF1,0x71,0xD8,0x31,0x15
	.byte	0x04,0xC7,0x23,0xC3,0x18,0x96,0x05,0x9A,0x07,0x12,0x80,0xE2,0xEB,0x27,0xB2,0x75
	.byte	0x09,0x83,0x2C,0x1A,0x1B,0x6E,0x5A,0xA0,0x52,0x3B,0xD6,0xB3,0x29,0xE3,0x2F,0x84
	.byte	0x53,0xD1,0x00,0xED,0x20,0xFC,0xB1,0x5B,0x6A,0xCB,0xBE,0x39,0x4A,0x4C,0x58,0xCF
	.byte	0xD0,0xEF,0xAA,0xFB,0x43,0x4D,0x33,0x85,0x45,0xF9,0x02,0x7F,0x50,0x3C,0x9F,0xA8
	.byte	0x51,0xA3,0x40,0x8F,0x92,0x9D,0x38,0xF5,0xBC,0xB6,0xDA,0x21,0x10,0xFF,0xF3,0xD2
	.byte	0xCD,0x0C,0x13,0xEC,0x5F,0x97,0x44,0x17,0xC4,0xA7,0x7E,0x3D,0x64,0x5D,0x19,0x73
	.byte	0x60,0x81,0x4F,0xDC,0x22,0x2A,0x90,0x88,0x46,0xEE,0xB8,0x14,0xDE,0x5E,0x0B,0xDB
	.byte	0xE0,0x32,0x3A,0x0A,0x49,0x06,0x24,0x5C,0xC2,0xD3,0xAC,0x62,0x91,0x95,0xE4,0x79
	.byte	0xE7,0xC8,0x37,0x6D,0x8D,0xD5,0x4E,0xA9,0x6C,0x56,0xF4,0xEA,0x65,0x7A,0xAE,0x08
	.byte	0xBA,0x78,0x25,0x2E,0x1C,0xA6,0xB4,0xC6,0xE8,0xDD,0x74,0x1F,0x4B,0xBD,0x8B,0x8A
	.byte	0x70,0x3E,0xB5,0x66,0x48,0x03,0xF6,0x0E,0x61,0x35,0x57,0xB9,0x86,0xC1,0x1D,0x9E
	.byte	0xE1,0xF8,0x98,0x11,0x69,0xD9,0x8E,0x94,0x9B,0x1E,0x87,0xE9,0xCE,0x55,0x28,0xDF
	.byte	0x8C,0xA1,0x89,0x0D,0xBF,0xE6,0x42,0x68,0x41,0x99,0x2D,0x0F,0xB0,0x54,0xBB,0x16

# AES inverse SBOX array
invsubbytes:
	.byte	0x52,0x09,0x6A,0xD5,0x30,0x36,0xA5,0x38,0xBF,0x40,0xA3,0x9E,0x81,0xF3,0xD7,0xFB
	.byte	0x7C,0xE3,0x39,0x82,0x9B,0x2F,0xFF,0x87,0x34,0x8E,0x43,0x44,0xC4,0xDE,0xE9,0xCB
	.byte	0x54,0x7B,0x94,0x32,0xA6,0xC2,0x23,0x3D,0xEE,0x4C,0x95,0x0B,0x42,0xFA,0xC3,0x4E
	.byte	0x08,0x2E,0xA1,0x66,0x28,0xD9,0x24,0xB2,0x76,0x5B,0xA2,0x49,0x6D,0x8B,0xD1,0x25
	.byte	0x72,0xF8,0xF6,0x64,0x86,0x68,0x98,0x16,0xD4,0xA4,0x5C,0xCC,0x5D,0x65,0xB6,0x92
	.byte	0x6C,0x70,0x48,0x50,0xFD,0xED,0xB9,0xDA,0x5E,0x15,0x46,0x57,0xA7,0x8D,0x9D,0x84
	.byte	0x90,0xD8,0xAB,0x00,0x8C,0xBC,0xD3,0x0A,0xF7,0xE4,0x58,0x05,0xB8,0xB3,0x45,0x06
	.byte	0xD0,0x2C,0x1E,0x8F,0xCA,0x3F,0x0F,0x02,0xC1,0xAF,0xBD,0x03,0x01,0x13,0x8A,0x6B
	.byte	0x3A,0x91,0x11,0x41,0x4F,0x67,0xDC,0xEA,0x97,0xF2,0xCF,0xCE,0xF0,0xB4,0xE6,0x73
	.byte	0x96,0xAC,0x74,0x22,0xE7,0xAD,0x35,0x85,0xE2,0xF9,0x37,0xE8,0x1C,0x75,0xDF,0x6E
	.byte	0x47,0xF1,0x1A,0x71,0x1D,0x29,0xC5,0x89,0x6F,0xB7,0x62,0x0E,0xAA,0x18,0xBE,0x1B
	.byte	0xFC,0x56,0x3E,0x4B,0xC6,0xD2,0x79,0x20,0x9A,0xDB,0xC0,0xFE,0x78,0xCD,0x5A,0xF4
	.byte	0x1F,0xDD,0xA8,0x33,0x88,0x07,0xC7,0x31,0xB1,0x12,0x10,0x59,0x27,0x80,0xEC,0x5F
	.byte	0x60,0x51,0x7F,0xA9,0x19,0xB5,0x4A,0x0D,0x2D,0xE5,0x7A,0x9F,0x93,0xC9,0x9C,0xEF
	.byte	0xA0,0xE0,0x3B,0x4D,0xAE,0x2A,0xF5,0xB0,0xC8,0xEB,0xBB,0x3C,0x83,0x53,0x99,0x61
	.byte	0x17,0x2B,0x04,0x7E,0xBA,0x77,0xD6,0x26,0xE1,0x69,0x14,0x63,0x55,0x21,0x0C,0x7D

# tbox combines the AES SubBytes and MixColumns operations
# Since SubBytes() is position independent, and ShiftRows merely
# changes the positions of bytes, the order of the two operations can
# be interchanged, and thus SubBytes and MixColumns can be combined.
# tbox[i] = (0x02 * s) || s || s || (0x03 * s) where s = subbytes[i]
# and * is polynomial multiplication over GF(2^8).
tbox:
	.long	0xc66363a5,0xf87c7c84,0xee777799,0xf67b7b8d,0xfff2f20d,0xd66b6bbd,0xde6f6fb1,0x91c5c554
	.long	0x60303050,0x02010103,0xce6767a9,0x562b2b7d,0xe7fefe19,0xb5d7d762,0x4dababe6,0xec76769a
	.long	0x8fcaca45,0x1f82829d,0x89c9c940,0xfa7d7d87,0xeffafa15,0xb25959eb,0x8e4747c9,0xfbf0f00b
	.long	0x41adadec,0xb3d4d467,0x5fa2a2fd,0x45afafea,0x239c9cbf,0x53a4a4f7,0xe4727296,0x9bc0c05b
	.long	0x75b7b7c2,0xe1fdfd1c,0x3d9393ae,0x4c26266a,0x6c36365a,0x7e3f3f41,0xf5f7f702,0x83cccc4f
	.long	0x6834345c,0x51a5a5f4,0xd1e5e534,0xf9f1f108,0xe2717193,0xabd8d873,0x62313153,0x2a15153f
	.long	0x0804040c,0x95c7c752,0x46232365,0x9dc3c35e,0x30181828,0x379696a1,0x0a05050f,0x2f9a9ab5
	.long	0x0e070709,0x24121236,0x1b80809b,0xdfe2e23d,0xcdebeb26,0x4e272769,0x7fb2b2cd,0xea75759f
	.long	0x1209091b,0x1d83839e,0x582c2c74,0x341a1a2e,0x361b1b2d,0xdc6e6eb2,0xb45a5aee,0x5ba0a0fb
	.long	0xa45252f6,0x763b3b4d,0xb7d6d661,0x7db3b3ce,0x5229297b,0xdde3e33e,0x5e2f2f71,0x13848497
	.long	0xa65353f5,0xb9d1d168,0x00000000,0xc1eded2c,0x40202060,0xe3fcfc1f,0x79b1b1c8,0xb65b5bed
	.long	0xd46a6abe,0x8dcbcb46,0x67bebed9,0x7239394b,0x944a4ade,0x984c4cd4,0xb05858e8,0x85cfcf4a
	.long	0xbbd0d06b,0xc5efef2a,0x4faaaae5,0xedfbfb16,0x864343c5,0x9a4d4dd7,0x66333355,0x11858594
	.long	0x8a4545cf,0xe9f9f910,0x04020206,0xfe7f7f81,0xa05050f0,0x783c3c44,0x259f9fba,0x4ba8a8e3
	.long	0xa25151f3,0x5da3a3fe,0x804040c0,0x058f8f8a,0x3f9292ad,0x219d9dbc,0x70383848,0xf1f5f504
	.long	0x63bcbcdf,0x77b6b6c1,0xafdada75,0x42212163,0x20101030,0xe5ffff1a,0xfdf3f30e,0xbfd2d26d
	.long	0x81cdcd4c,0x180c0c14,0x26131335,0xc3ecec2f,0xbe5f5fe1,0x359797a2,0x884444cc,0x2e171739
	.long	0x93c4c457,0x55a7a7f2,0xfc7e7e82,0x7a3d3d47,0xc86464ac,0xba5d5de7,0x3219192b,0xe6737395
	.long	0xc06060a0,0x19818198,0x9e4f4fd1,0xa3dcdc7f,0x44222266,0x542a2a7e,0x3b9090ab,0x0b888883
	.long	0x8c4646ca,0xc7eeee29,0x6bb8b8d3,0x2814143c,0xa7dede79,0xbc5e5ee2,0x160b0b1d,0xaddbdb76
	.long	0xdbe0e03b,0x64323256,0x743a3a4e,0x140a0a1e,0x924949db,0x0c06060a,0x4824246c,0xb85c5ce4
	.long	0x9fc2c25d,0xbdd3d36e,0x43acacef,0xc46262a6,0x399191a8,0x319595a4,0xd3e4e437,0xf279798b
	.long	0xd5e7e732,0x8bc8c843,0x6e373759,0xda6d6db7,0x018d8d8c,0xb1d5d564,0x9c4e4ed2,0x49a9a9e0
	.long	0xd86c6cb4,0xac5656fa,0xf3f4f407,0xcfeaea25,0xca6565af,0xf47a7a8e,0x47aeaee9,0x10080818
	.long	0x6fbabad5,0xf0787888,0x4a25256f,0x5c2e2e72,0x381c1c24,0x57a6a6f1,0x73b4b4c7,0x97c6c651
	.long	0xcbe8e823,0xa1dddd7c,0xe874749c,0x3e1f1f21,0x964b4bdd,0x61bdbddc,0x0d8b8b86,0x0f8a8a85
	.long	0xe0707090,0x7c3e3e42,0x71b5b5c4,0xcc6666aa,0x904848d8,0x06030305,0xf7f6f601,0x1c0e0e12
	.long	0xc26161a3,0x6a35355f,0xae5757f9,0x69b9b9d0,0x17868691,0x99c1c158,0x3a1d1d27,0x279e9eb9
	.long	0xd9e1e138,0xebf8f813,0x2b9898b3,0x22111133,0xd26969bb,0xa9d9d970,0x078e8e89,0x339494a7
	.long	0x2d9b9bb6,0x3c1e1e22,0x15878792,0xc9e9e920,0x87cece49,0xaa5555ff,0x50282878,0xa5dfdf7a
	.long	0x038c8c8f,0x59a1a1f8,0x09898980,0x1a0d0d17,0x65bfbfda,0xd7e6e631,0x844242c6,0xd06868b8
	.long	0x824141c3,0x299999b0,0x5a2d2d77,0x1e0f0f11,0x7bb0b0cb,0xa85454fc,0x6dbbbbd6,0x2c16163a

# invmixcols is used to implement the InvMixColumns operations
# invmixcols[i] = (0x0e * i) || (0x09 * i) || (0x0D * i) || (0x0B * i)
# where * is polynomial multiplication over GF(2^8).
invmixcols:
	.long	0x00000000,0x0e090d0b,0x1c121a16,0x121b171d,0x3824342c,0x362d3927,0x24362e3a,0x2a3f2331
	.long	0x70486858,0x7e416553,0x6c5a724e,0x62537f45,0x486c5c74,0x4665517f,0x547e4662,0x5a774b69
	.long	0xe090d0b0,0xee99ddbb,0xfc82caa6,0xf28bc7ad,0xd8b4e49c,0xd6bde997,0xc4a6fe8a,0xcaaff381
	.long	0x90d8b8e8,0x9ed1b5e3,0x8ccaa2fe,0x82c3aff5,0xa8fc8cc4,0xa6f581cf,0xb4ee96d2,0xbae79bd9
	.long	0xdb3bbb7b,0xd532b670,0xc729a16d,0xc920ac66,0xe31f8f57,0xed16825c,0xff0d9541,0xf104984a
	.long	0xab73d323,0xa57ade28,0xb761c935,0xb968c43e,0x9357e70f,0x9d5eea04,0x8f45fd19,0x814cf012
	.long	0x3bab6bcb,0x35a266c0,0x27b971dd,0x29b07cd6,0x038f5fe7,0x0d8652ec,0x1f9d45f1,0x119448fa
	.long	0x4be30393,0x45ea0e98,0x57f11985,0x59f8148e,0x73c737bf,0x7dce3ab4,0x6fd52da9,0x61dc20a2
	.long	0xad766df6,0xa37f60fd,0xb16477e0,0xbf6d7aeb,0x955259da,0x9b5b54d1,0x894043cc,0x87494ec7
	.long	0xdd3e05ae,0xd33708a5,0xc12c1fb8,0xcf2512b3,0xe51a3182,0xeb133c89,0xf9082b94,0xf701269f
	.long	0x4de6bd46,0x43efb04d,0x51f4a750,0x5ffdaa5b,0x75c2896a,0x7bcb8461,0x69d0937c,0x67d99e77
	.long	0x3daed51e,0x33a7d815,0x21bccf08,0x2fb5c203,0x058ae132,0x0b83ec39,0x1998fb24,0x1791f62f
	.long	0x764dd68d,0x7844db86,0x6a5fcc9b,0x6456c190,0x4e69e2a1,0x4060efaa,0x527bf8b7,0x5c72f5bc
	.long	0x0605bed5,0x080cb3de,0x1a17a4c3,0x141ea9c8,0x3e218af9,0x302887f2,0x223390ef,0x2c3a9de4
	.long	0x96dd063d,0x98d40b36,0x8acf1c2b,0x84c61120,0xaef93211,0xa0f03f1a,0xb2eb2807,0xbce2250c
	.long	0xe6956e65,0xe89c636e,0xfa877473,0xf48e7978,0xdeb15a49,0xd0b85742,0xc2a3405f,0xccaa4d54
	.long	0x41ecdaf7,0x4fe5d7fc,0x5dfec0e1,0x53f7cdea,0x79c8eedb,0x77c1e3d0,0x65daf4cd,0x6bd3f9c6
	.long	0x31a4b2af,0x3fadbfa4,0x2db6a8b9,0x23bfa5b2,0x09808683,0x07898b88,0x15929c95,0x1b9b919e
	.long	0xa17c0a47,0xaf75074c,0xbd6e1051,0xb3671d5a,0x99583e6b,0x97513360,0x854a247d,0x8b432976
	.long	0xd134621f,0xdf3d6f14,0xcd267809,0xc32f7502,0xe9105633,0xe7195b38,0xf5024c25,0xfb0b412e
	.long	0x9ad7618c,0x94de6c87,0x86c57b9a,0x88cc7691,0xa2f355a0,0xacfa58ab,0xbee14fb6,0xb0e842bd
	.long	0xea9f09d4,0xe49604df,0xf68d13c2,0xf8841ec9,0xd2bb3df8,0xdcb230f3,0xcea927ee,0xc0a02ae5
	.long	0x7a47b13c,0x744ebc37,0x6655ab2a,0x685ca621,0x42638510,0x4c6a881b,0x5e719f06,0x5078920d
	.long	0x0a0fd964,0x0406d46f,0x161dc372,0x1814ce79,0x322bed48,0x3c22e043,0x2e39f75e,0x2030fa55
	.long	0xec9ab701,0xe293ba0a,0xf088ad17,0xfe81a01c,0xd4be832d,0xdab78e26,0xc8ac993b,0xc6a59430
	.long	0x9cd2df59,0x92dbd252,0x80c0c54f,0x8ec9c844,0xa4f6eb75,0xaaffe67e,0xb8e4f163,0xb6edfc68
	.long	0x0c0a67b1,0x02036aba,0x10187da7,0x1e1170ac,0x342e539d,0x3a275e96,0x283c498b,0x26354480
	.long	0x7c420fe9,0x724b02e2,0x605015ff,0x6e5918f4,0x44663bc5,0x4a6f36ce,0x587421d3,0x567d2cd8
	.long	0x37a10c7a,0x39a80171,0x2bb3166c,0x25ba1b67,0x0f853856,0x018c355d,0x13972240,0x1d9e2f4b
	.long	0x47e96422,0x49e06929,0x5bfb7e34,0x55f2733f,0x7fcd500e,0x71c45d05,0x63df4a18,0x6dd64713
	.long	0xd731dcca,0xd938d1c1,0xcb23c6dc,0xc52acbd7,0xef15e8e6,0xe11ce5ed,0xf307f2f0,0xfd0efffb
	.long	0xa779b492,0xa970b999,0xbb6bae84,0xb562a38f,0x9f5d80be,0x91548db5,0x834f9aa8,0x8d4697a3

do_vcipher:
	mfrin	1,4		# get VRA and VRB
	mfrin	8,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	3,4
	mfrin	9,5
	li	%r11,4
	srdi	%r0,%r1,32	# unpack words of state
	srdi	%r2,%r3,32
	mtctr	%r11
	pla	%r10,tbox-.
1:	rlwinm	%r12,%r0,10,0x3fc
	lwzx	%r13,%r10,%r12
	rlwinm	%r12,%r1,18,0x3fc
	lwzx	%r14,%r10,%r12
	rlwinm	%r12,%r2,26,0x3fc
	rotlwi	%r14,%r14,24
	xor	%r13,%r13,%r14
	lwzx	%r14,%r10,%r12
	rlwinm	%r12,%r3,2,0x3fc
	rotlwi	%r14,%r14,16
	xor	%r13,%r13,%r14
	lwzx	%r14,%r10,%r12
	rotldi	%r8,%r8,32
	rotlwi	%r14,%r14,8
	xor	%r13,%r13,%r14
	rotldi	%r9,%r9,32
	xor	%r13,%r13,%r8
	rldimi	%r8,%r9,0,32
	rldimi	%r9,%r13,0,32
	mr	%r4,%r0
	mr	%r0,%r1
	mr	%r1,%r2
	mr	%r2,%r3
	mr	%r3,%r4
	bdnz	1b
	mtrin	8,6
	addi	%r6,%r6,LO
	mtrin	9,6
	b	return

do_vcipherlast:
	mfrin	1,4		# get VRA and VRB
	mfrin	8,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	3,4
	mfrin	9,5
	li	%r11,4
	srdi	%r0,%r1,32	# unpack words of state
	srdi	%r2,%r3,32
	mtctr	%r11
	pla	%r10,subbytes-.
1:	rlwinm	%r12,%r0,8,0xff
	lbzx	%r13,%r10,%r12
	rlwinm	%r12,%r1,16,0xff
	slwi	%r13,%r13,24
	lbzx	%r14,%r10,%r12
	rlwinm	%r12,%r2,24,0xff
	rlwimi	%r13,%r14,16,0xff0000
	lbzx	%r14,%r10,%r12
	rlwinm	%r12,%r3,0,0xff
	rlwimi	%r13,%r14,8,0xff00
	lbzx	%r14,%r10,%r12
	rotldi	%r8,%r8,32
	rotldi	%r9,%r9,32
	rlwimi	%r13,%r14,0,0xff
	xor	%r13,%r13,%r8
	rldimi	%r8,%r9,0,32
	rldimi	%r9,%r13,0,32
	mr	%r4,%r0
	mr	%r0,%r1
	mr	%r1,%r2
	mr	%r2,%r3
	mr	%r3,%r4
	bdnz	1b
	mtrin	8,6
	addi	%r6,%r6,LO
	mtrin	9,6
	b	return

do_vsbox:
	li	%r11,8
	pla	%r10,subbytes-.
1:	mtctr	%r11
	mfrin	0,4
2:	rotldi	%r0,%r0,8
	clrldi	%r1,%r0,56
	lbzx	%r1,%r10,%r1
	rldimi	%r0,%r1,0,56
	bdnz	2b
	mtrin	0,6
	andi.	%r0,%r6,LO
	addi	%r4,%r4,LO
	addi	%r6,%r6,LO
	beq	1b
	b	return

do_vncipher:
	mfrin	3,4		# get VRA (state) and VRB (roundkey)
	mfrin	8,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	9,5
	mfrin	5,4
	li	%r11,4
	srdi	%r2,%r3,32	# unpack words of state
	srdi	%r4,%r5,32
	mtctr	%r11
	pla	%r10,invmixcols-.
	pla	%r11,invsubbytes-.
1:	rlwinm	%r1,%r2,8,0xff
	lbzx	%r0,%r1,%r11
	rotldi	%r8,%r8,8
	xor	%r0,%r0,%r8
	rlwinm	%r1,%r0,2,0x3fc
	lwzx	%r7,%r1,%r10
	rlwinm	%r1,%r5,16,0xff
	lbzx	%r0,%r1,%r11
	rotldi	%r8,%r8,8
	xor	%r0,%r0,%r8
	rlwinm	%r1,%r0,2,0x3fc
	lwzx	%r0,%r1,%r10
	rlwinm	%r1,%r4,24,0xff
	rotlwi	%r0,%r0,24
	xor	%r7,%r7,%r0
	lbzx	%r0,%r1,%r11
	rotldi	%r8,%r8,8
	xor	%r0,%r0,%r8
	rlwinm	%r1,%r0,2,0x3fc
	lwzx	%r0,%r1,%r10
	rlwinm	%r1,%r3,0,0xff
	rotlwi	%r0,%r0,16
	xor	%r7,%r7,%r0
	lbzx	%r0,%r1,%r11
	rotldi	%r8,%r8,8
	xor	%r0,%r0,%r8
	rlwinm	%r1,%r0,2,0x3fc
	lwzx	%r0,%r1,%r10
	rotldi	%r9,%r9,32
	rotlwi	%r0,%r0,8
	xor	%r7,%r7,%r0
	rldimi	%r8,%r9,0,32
	rldimi	%r9,%r7,0,32
	mr	%r1,%r2
	mr	%r2,%r3
	mr	%r3,%r4
	mr	%r4,%r5
	mr	%r5,%r1
	bdnz	1b
	mtrin	8,6
	addi	%r6,%r6,LO
	mtrin	9,6
	b	return

do_vncipherlast:
	mfrin	3,4		# get VRA (state) and VRB (roundkey)
	mfrin	8,5
	addi	%r4,%r4,LO
	addi	%r5,%r5,LO
	mfrin	9,5
	mfrin	5,4
	li	%r11,4
	srdi	%r2,%r3,32	# unpack words of state
	srdi	%r4,%r5,32
	mtctr	%r11
	pla	%r11,invsubbytes-.
1:	rlwinm	%r1,%r2,8,0xff
	lbzx	%r0,%r1,%r11
	rlwinm	%r1,%r5,16,0xff
	slwi	%r7,%r0,24
	lbzx	%r0,%r1,%r11
	rlwinm	%r1,%r4,24,0xff
	rlwimi	%r7,%r0,16,0xff0000
	lbzx	%r0,%r1,%r11
	rlwinm	%r1,%r3,0,0xff
	rlwimi	%r7,%r0,8,0xff00
	lbzx	%r0,%r1,%r11
	rotldi	%r8,%r8,32
	rlwimi	%r7,%r0,0,0xff
	xor	%r7,%r7,%r8
	rotldi	%r9,%r9,32
	rldimi	%r8,%r9,0,32
	rldimi	%r9,%r7,0,32
	mr	%r1,%r2
	mr	%r2,%r3
	mr	%r3,%r4
	mr	%r4,%r5
	mr	%r5,%r1
	bdnz	1b
	mtrin	8,6
	addi	%r6,%r6,LO
	mtrin	9,6
	b	return
