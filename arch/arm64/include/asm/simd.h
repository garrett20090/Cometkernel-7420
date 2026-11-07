#ifndef __ASM_SIMD_H
#define __ASM_SIMD_H

#include <linux/hardirq.h>
#include <linux/irqflags.h>

/*
 * may_use_simd - whether kernel-mode NEON may be used now
 *
 * kernel_neon_begin_partial() saves the NEON state to a per-CPU softirq or hardirq buffer
 * when called in interrupt context (arch/arm64/kernel/fpsimd.c), so softirq may use it.
 * The asm-generic !in_interrupt() made ablk_helper defer every AES operation issued from a
 * softirq to cryptd, which put all inbound IPsec (ESP) decryption on the asynchronous
 * xfrm_input_resume() path; IMS SIP over IPsec lost TCP segments there.
 */
static __must_check inline bool may_use_simd(void)
{
	return !in_irq() && !irqs_disabled();
}

#endif /* __ASM_SIMD_H */
