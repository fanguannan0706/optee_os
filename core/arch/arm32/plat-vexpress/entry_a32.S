/*
 * Copyright (c) 2014, Linaro Limited
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#include <platform_config.h>

#include <asm.S>
#include <arm32.h>
#include <arm32_macros.S>
#include <sm/teesmc.h>
#include <sm/teesmc_opteed_macros.h>
#include <sm/teesmc_opteed.h>

.section .text.boot
FUNC _start , :
	b	reset
	b	.	/* Undef */
	b	.	/* Syscall */
	b	.	/* Prefetch abort */
	b	.	/* Data abort */
	b	.	/* Reserved */
	b	.	/* IRQ */
	b	.	/* FIQ */
END_FUNC _start

LOCAL_FUNC reset , :
	mov	r4, r0		/* Save pageable part address */
	mov	r5, lr		/* Save ns-entry address */

	/*
	 * Enable alignment checks and disable data and instruction cache.
	 */
	read_sctlr r0
	orr	r0, r0, #SCTLR_A
	bic	r0, r0, #SCTLR_C
	bic	r0, r0, #SCTLR_I
	write_sctlr r0

	ldr	r0, =_start
	write_vbar r0

#if defined(CFG_WITH_ARM_TRUSTED_FW)
	b	reset_primary
#else
	bl	get_core_pos
	cmp	r0, #0
	beq	reset_primary
	b	reset_secondary
#endif
END_FUNC reset

LOCAL_FUNC reset_primary , :
#ifdef CFG_WITH_PAGER
	/*
	 * Move init code into correct location
	 *
	 * The binary is built as:
	 * [Pager code, rodata and data] : In correct location
	 * [Init code and rodata] : Should be copied to __text_init_start
	 * [Hashes] : Should be saved before clearing bss
	 *
	 * When we copy init code and rodata into correct location we don't
	 * need to worry about hashes being overwritten as size of .bss,
	 * .heap, .nozi and .heap3 is much larger than the size of init
	 * code and rodata and hashes.
	 */
	ldr	r0, =__text_init_start	/* dst */
	ldr	r1, =__data_end 	/* src */
	ldr	r2, =__rodata_init_end	/* dst limit */
copy_init:
	ldm	r1!, {r6-r12}
	stm	r0!, {r6-r12}
	cmp	r0, r2
	blt	copy_init
#endif

	bl	get_core_pos
	cmp	r0, #CFG_TEE_CORE_NB_CORE
	/* Unsupported CPU, park it before it breaks something */
	bge	unhandled_cpu
	lsl	r0, #2
	ldr	r1, =stack_tmp_top
	ldr	sp, [r1, r0]

	/*
	 * Invalidate dcache for all memory used during initialization to
	 * avoid nasty surprices when the cache is turned on. We must not
	 * invalidate memory not used by OP-TEE since we may invalidate
	 * entries used by for instance ARM Trusted Firmware.
	 *
	 * Before MMU is turned on is VA == PA for cache operations.
	 */
	ldr	r0, =__text_start
#ifdef CFG_WITH_PAGER
	ldr	r1, =__init_end
#else
	ldr	r1, =_end
#endif
	sub	r1, r1, #1
	bl	arm_cl1_d_invbyva

	/* Enable UART */
	ldr	r0, =CONSOLE_UART_BASE
	ldr	r1, =CONSOLE_UART_CLK_IN_HZ
	ldr	r2, =CONSOLE_BAUDRATE
	bl	pl011_init

	bl	core_init_mmu_map
	bl	core_init_mmu_regs
	bl	cpu_mmu_enable
	bl	cpu_mmu_enable_icache
	bl	cpu_mmu_enable_dcache

	mov	r0, r4		/* pageable part address */
	mov	r1, r5		/* ns-entry address */
	bl	main_init_primary

	/*
	 * In case we've touched memory that secondary CPUs will use before
	 * they have turned on their D-cache, clean and invalidate the
	 * D-cache before exiting to normal world.
	 */
	mov	r4, r0
	ldr	r0, =__text_start
#ifdef CFG_WITH_PAGER
	ldr	r1, =__init_end
#else
	ldr	r1, =_end
#endif
	sub	r1, r1, #1
	bl	arm_cl1_d_cleaninvbyva
	mov	r0, r4

#if defined(CFG_WITH_ARM_TRUSTED_FW)
	/* Pass the vector address returned from main_init */
	mov     r1, r0
#else
	mov	r1, #0
	mov	r2, #0
	mov	r3, #0
#endif
	mov	r0, #TEESMC_OPTEED_RETURN_ENTRY_DONE
	smc	#0
	b	.	/* SMC should not return */
END_FUNC reset_primary


LOCAL_FUNC unhandled_cpu , :
	wfi
	b	unhandled_cpu
END_FUNC unhandled_cpu

#if defined(CFG_WITH_ARM_TRUSTED_FW)
FUNC cpu_on_handler , :
	mov	r4, r0
	mov	r5, r1
	mov	r6, lr
	read_sctlr r0
	orr	r0, r0, #SCTLR_A
	write_sctlr r0

	ldr	r0, =_start
	write_vbar r0

	mov	r4, lr
	bl	get_core_pos
	cmp	r0, #CFG_TEE_CORE_NB_CORE
	/* Unsupported CPU, park it before it breaks something */
	bge	unhandled_cpu
	lsl	r0, #2
	ldr	r1, =stack_tmp_top
	ldr	sp, [r1, r0]

	bl	core_init_mmu_regs
	bl	cpu_mmu_enable
	bl	cpu_mmu_enable_icache
	bl	cpu_mmu_enable_dcache

	mov	r0, r4
	mov	r1, r5
	bl	main_cpu_on_handler

	bx	r6
END_FUNC cpu_on_handler

#else /* defined(CFG_WITH_ARM_TRUSTED_FW) */

LOCAL_FUNC reset_secondary , :
	bl	get_core_pos
	cmp	r0, #CFG_TEE_CORE_NB_CORE
	/* Unsupported CPU, park it before it breaks something */
	bge	unhandled_cpu
	lsl	r0, #2
	ldr	r1, =stack_tmp_top
	ldr	sp, [r1, r0]

	bl	core_init_mmu_regs
	bl	cpu_mmu_enable
	bl	cpu_mmu_enable_icache
	bl	cpu_mmu_enable_dcache

	mov	r0, r5		/* ns-entry address */
	bl	main_init_secondary

	mov	r0, #TEESMC_OPTEED_RETURN_ENTRY_DONE
	mov	r1, #0
	mov	r2, #0
	mov	r3, #0
	smc	#0
	b	.	/* SMC should not return */
END_FUNC reset_primary
#endif /* defined(CFG_WITH_ARM_TRUSTED_FW) */
