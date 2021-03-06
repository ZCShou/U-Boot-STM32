/* SPDX-License-Identifier: GPL-2.0+ */
/*
 *  crt0 - C-runtime startup Code for ARM U-Boot
 *
 *  Copyright (c) 2012  Albert ARIBAUD <albert.u.boot@aribaud.net>
 */

#include <config.h>
#include <asm-offsets.h>
#include <linux/linkage.h>
#include <asm/assembler.h>

/*
 * This file handles the target-independent stages of the U-Boot
 * start-up where a C runtime environment is needed. Its entry point
 * is _main and is branched into from the target's start.S file.
 *
 * _main execution sequence is:
 *
 * 1. Set up initial environment for calling board_init_f().
 *    This environment only provides a stack and a place to store
 *    the GD ('global data') structure, both located in some readily
 *    available RAM (SRAM, locked cache...). In this context, VARIABLE
 *    global data, initialized or not (BSS), are UNAVAILABLE; only
 *    CONSTANT initialized data are available. GD should be zeroed
 *    before board_init_f() is called.
 *
 * 2. Call board_init_f(). This function prepares the hardware for
 *    execution from system RAM (DRAM, DDR...) As system RAM may not
 *    be available yet, , board_init_f() must use the current GD to
 *    store any data which must be passed on to later stages. These
 *    data include the relocation destination, the future stack, and
 *    the future GD location.
 *
 * 3. Set up intermediate environment where the stack and GD are the
 *    ones allocated by board_init_f() in system RAM, but BSS and
 *    initialized non-const data are still not available.
 *
 * 4a.For U-Boot proper (not SPL), call relocate_code(). This function
 *    relocates U-Boot from its current location into the relocation
 *    destination computed by board_init_f().
 *
 * 4b.For SPL, board_init_f() just returns (to crt0). There is no
 *    code relocation in SPL.
 *
 * 5. Set up final environment for calling board_init_r(). This
 *    environment has BSS (initialized to 0), initialized non-const
 *    data (initialized to their intended value), and stack in system
 *    RAM (for SPL moving the stack and GD into RAM is optional - see
 *    CONFIG_SPL_STACK_R). GD has retained values set by board_init_f().
 *
 * 6. For U-Boot proper (not SPL), some CPUs have some work left to do
 *    at this point regarding memory, so call c_runtime_cpu_setup.
 *
 * 7. Branch to board_init_r().
 *
 * For more information see 'Board Initialisation Flow in README.
 */

/*
 * Macro for clearing BSS during SPL execution. Usually called during the
 * relocation process for most boards before entering board_init_r(), but
 * can also be done early before entering board_init_f() on plaforms that
 * can afford it due to sufficient memory being available early.
 */
.macro CLEAR_BSS
	ldr	r0, =__bss_start	/* this is auto-relocated! */

	#ifdef CONFIG_USE_ARCH_MEMSET
		ldr	r3, =__bss_end		/* this is auto-relocated! */
		mov	r1, #0x00000000		/* prepare zero to clear BSS */

		subs	r2, r3, r0		/* r2 = memset len */
		bl	memset
	#else
		ldr	r1, =__bss_end		/* this is auto-relocated! */
		mov	r2, #0x00000000		/* prepare zero to clear BSS */

	clbss_l:cmp	r0, r1			/* while not at end of BSS */
		strlo	r2, [r0]		/* clear 32-bit BSS word */
		addlo	r0, r0, #4		/* move to next */
		blo	clbss_l
	#endif
.endm

/*
 * entry point of crt0 sequence
 */
ENTRY(_main)
	/*
	* Set up initial C runtime environment and call board_init_f(0).
	*/
	#if defined(CONFIG_TPL_BUILD) && defined(CONFIG_TPL_NEEDS_SEPARATE_STACK)
		ldr	r0, =(CONFIG_TPL_STACK)										/* r0 = CONFIG_TPL_STACK =  */
	#elif defined(CONFIG_SPL_BUILD) && defined(CONFIG_SPL_STACK)
		ldr	r0, =(CONFIG_SPL_STACK)										/* r0 = CONFIG_SPL_STACK = 0x20050000 */
	#else
		ldr	r0, =(CONFIG_SYS_INIT_SP_ADDR)								/* r0 = CONFIG_SYS_INIT_SP_ADDR = 0x20050000 */
	#endif
	bic	r0, r0, #7	/* 8-byte alignment for ABI compliance */			/* r0 = r0 & ~(0x7) = 0x20050000 & 0xFFFFFFF8 = 0x20050000 */
	mov	sp, r0															/* sp = r0 = 0x20050000 */
	bl	board_init_f_alloc_reserve										/* 调用 board_init_f_alloc_reserve(0x20050000)，该函数有一个入参，ARM 默认是 r0 作为第一个参数。该函数分配 GD 空间。 */
	mov	sp, r0															/* sp = r0 = board_init_f_alloc_reserve(0x20050000) = 0x2004f120。 ARM 默认用 r0 存放函数的返回值 。这个地址正好是 GD 的地址。 */
	/* set up gd here, outside any C code */
	mov	r9, r0															/* r9 = r0 = 0x2004f120。这里使用 r9 保存了 GD 的地址 */
	bl	board_init_f_init_reserve										/* 调用 board_init_f_init_reserve(0x2004f120)。ARM 默认 r0 传递第一个参数。该函数初始化（实际是清零） GD 空间 */

	#if defined(CONFIG_SPL_BUILD) && defined(CONFIG_SPL_EARLY_BSS)
		CLEAR_BSS
	#endif

	mov	r0, #0															/* r0 = 0 */
	bl	board_init_f													/* 调用 board_init_f(0)。ARM 默认 r0 传递第一个参数。该接口没有返回值。其中会填写 GD 各成员变量的的值  */

	#if !defined(CONFIG_SPL_BUILD)
		/*
		* Set up intermediate environment (new sp and gd) and call
		* relocate_code(addr_moni). Trick here is that we'll return
		* 'here' but relocated.
		*/
		ldr	r0, [r9, #GD_START_ADDR_SP]	/* sp = gd->start_addr_sp */	/* r0 = *(r9 + GD_START_ADDR_SP) = *(0x2004f120 + ) = 0xc0da4fb0 */
		bic	r0, r0, #7	/* 8-byte alignment for ABI compliance */		/* r0 = r0 & ~(0x7) = 0xc0da4fb0 & 0xFFFFFFF8 = 0xc0da4fb0 */
		mov	sp, r0														/* sp = r0 = 0xc0da4fb0 */
		ldr	r9, [r9, #GD_NEW_GD]		/* r9 <- gd->new_gd */			/* r9 = *(r9 + GD_NEW_GD) = *(0x2004f120 + ) = 0xc0daaed0。r9 存放了重定位之后的 GD 的地址 */

		adr	lr, here													/* lr = here标号的位置 = 0x8010774 */
		ldr	r0, [r9, #GD_RELOC_OFF]		/* r0 = gd->reloc_off */		/* r0 = *(r9 + GD_RELOC_OFF) = 0 */
		add	lr, lr, r0													/* lr = lr + r0 = 0x8010774 + 0 = 0x8010774 */
		#if defined(CONFIG_CPU_V7M)
			orr	lr, #1				/* As required by Thumb-only */		/* lr = lr ^ 1 = 0x8010774 ^ 1 = 0x8010775 */
		#endif
			ldr	r0, [r9, #GD_RELOCADDR]		/* r0 = gd->relocaddr */	/* r0 = *(r9 + GD_RELOCADDR) = 0 */
			b	relocate_code											/* 调用 relocate_code(0)。ARM 默认 r0 传递第一个参数。 */
		here:
		/*
		* now relocate vectors
		*/
		bl	relocate_vectors											/* 调用 relocate_vectors() */
		/* Set up final (full) environment */
		bl	c_runtime_cpu_setup	/* we still call old routine here */	/* 调用 c_runtime_cpu_setup() */
	#endif
	#if !defined(CONFIG_SPL_BUILD) || CONFIG_IS_ENABLED(FRAMEWORK)
		#if !defined(CONFIG_SPL_BUILD) || !defined(CONFIG_SPL_EARLY_BSS)
			CLEAR_BSS
		#endif

		# ifdef CONFIG_SPL_BUILD
			/* Use a DRAM stack for the rest of SPL, if requested */
			bl	spl_relocate_stack_gd
			cmp	r0, #0
			movne	sp, r0
			movne	r9, r0
		# endif

		#if ! defined(CONFIG_SPL_BUILD)
			bl coloured_LED_init
			bl red_led_on
		#endif

		/* call board_init_r(gd_t *id, ulong dest_addr) */
		mov     r0, r9                  /* gd_t */
		ldr	r1, [r9, #GD_RELOCADDR]	/* dest_addr */

		/* call board_init_r */
		#if CONFIG_IS_ENABLED(SYS_THUMB_BUILD)
			ldr	lr, =board_init_r	/* this is auto-relocated! */
			bx	lr
		#else
			ldr	pc, =board_init_r	/* this is auto-relocated! */
		#endif
		/* we should not return here. */
	#endif
ENDPROC(_main)
