/* Generated for Glue LLVM backend (Windows x64, LLVM 18.1.8)
 * Minimal config matching the official LLVM 18.1.8 Windows prebuilt package.
 * Only includes macros referenced by llvm-c/*.h headers.
 */
#ifndef LLVM_CONFIG_H
#define LLVM_CONFIG_H

/* LLVM version string */
#define LLVM_VERSION_STRING "18.1.8"

/* Default target triple for Windows x64 */
#define LLVM_DEFAULT_TARGET_TRIPLE "x86_64-pc-windows-msvc"

/* Thread support enabled (official Windows build) */
#define LLVM_ENABLE_THREADS 1

/* Atomic operations available */
#define LLVM_HAS_ATOMICS 1

/* Only X86 target is enabled for native host codegen */
#define LLVM_HAS_X86_TARGET 1

/* Disabled targets (set to 0 to match @cImport expectations) */
#define LLVM_HAS_AARCH64_TARGET 0
#define LLVM_HAS_AMDGPU_TARGET 0
#define LLVM_HAS_ARM_TARGET 0
#define LLVM_HAS_AVR_TARGET 0
#define LLVM_HAS_BPF_TARGET 0
#define LLVM_HAS_HEXAGON_TARGET 0
#define LLVM_HAS_LANAI_TARGET 0
#define LLVM_HAS_LOONGARCH_TARGET 0
#define LLVM_HAS_M68K_TARGET 0
#define LLVM_HAS_MIPS_TARGET 0
#define LLVM_HAS_MSP430_TARGET 0
#define LLVM_HAS_NVPTX_TARGET 0
#define LLVM_HAS_POWERPC_TARGET 0
#define LLVM_HAS_RISCV_TARGET 0
#define LLVM_HAS_SPIRV_TARGET 0
#define LLVM_HAS_SYSTEMZ_TARGET 0
#define LLVM_HAS_VE_TARGET 0
#define LLVM_HAS_WEBASSEMBLY_TARGET 0
#define LLVM_HAS_XCORE_TARGET 0
#define LLVM_HAS_MOS_TARGET 0
#define LLVM_HAS_SPARC_TARGET 0
#define LLVM_HAS_DIRECTX_TARGET 0
#define LLVM_HAS_CSKY_TARGET 0
#define LLVM_HAS_ARC_TARGET 0
#define LLVM_HAS_TARGET_EXEGESIS 0

#endif /* LLVM_CONFIG_H */
