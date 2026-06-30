// Glue Char 运算 - x86_64 跨平台 (System V + Windows)
//
// Char 是 [4]u8 UTF-32 小端码点，全部无符号，固定 4 字节。
// 结构与 int.S/float.S 一致，不使用 SSE 指令。
//
// 使用 C 预处理器 #ifdef _WIN32 切换 ABI:
//   System V: rdi, rsi, rdx, rcx
//   Windows:  rcx, rdx, r8,  r9
//
// 注释用 // 不用 # (# 是 cpp 指令前缀)
// 大写 S 后缀确保文件经过 C 预处理器

.intel_syntax noprefix
.text

// ============================================================
// ABI 宏定义
// ============================================================
#ifdef _WIN32
#define A1 rcx
#define A2 rdx
#else
#define A1 rdi
#define A2 rsi
#endif

// ============================================================
// glue_cmp_char
// 输入: A1=a_ptr, A2=b_ptr (各 4 字节 UTF-32 小端)
// 输出: eax = -1 (a<b), 0 (a==b), 1 (a>b)
// 语义: 按码点无符号比较
// 破坏: rax, r8 (均为 volatile，无需 prologue)
// ============================================================
.globl glue_cmp_char
glue_cmp_char:
    mov eax, dword ptr [A1]
    mov r8d, dword ptr [A2]
    cmp eax, r8d
    jb .L_cmp_lt
    ja .L_cmp_gt
    xor eax, eax
    ret
.L_cmp_lt:
    mov eax, -1
    ret
.L_cmp_gt:
    mov eax, 1
    ret

// ============================================================
// glue_succ_char
// 输入: A1=out_ptr, A2=a_ptr (4 字节)
// 输出: 无 (存 4 字节到 [out])
// 语义: 码点 +1 (不校验上溢，调用方负责)
// ============================================================
.globl glue_succ_char
glue_succ_char:
    mov eax, dword ptr [A2]
    add eax, 1
    mov dword ptr [A1], eax
    ret

// ============================================================
// glue_pred_char
// 输入: A1=out_ptr, A2=a_ptr (4 字节)
// 输出: 无 (存 4 字节到 [out])
// 语义: 码点 -1 (不校验下溢，调用方负责)
// ============================================================
.globl glue_pred_char
glue_pred_char:
    mov eax, dword ptr [A2]
    sub eax, 1
    mov dword ptr [A1], eax
    ret

// ============================================================
// glue_is_ascii_char
// 输入: A1=a_ptr (4 字节)
// 输出: eax = 0/1 (码点 <= 0x7F)
// ============================================================
.globl glue_is_ascii_char
glue_is_ascii_char:
    mov eax, dword ptr [A1]
    cmp eax, 0x7F
    setbe al
    movzx eax, al
    ret

// ============================================================
// glue_is_digit_char
// 输入: A1=a_ptr (4 字节)
// 输出: eax = 0/1 ('0' <= cp <= '9')
// 技巧: sub 后无符号比较，cp<'0' 会下溢为大数，cp>'9' 结果>9
// ============================================================
.globl glue_is_digit_char
glue_is_digit_char:
    mov eax, dword ptr [A1]
    sub eax, 0x30            // '0'
    cmp eax, 9               // '9' - '0'
    setbe al
    movzx eax, al
    ret

// ============================================================
// glue_is_alpha_char
// 输入: A1=a_ptr (4 字节)
// 输出: eax = 0/1 (('A'<=cp<='Z') || ('a'<=cp<='z'))
// ============================================================
.globl glue_is_alpha_char
glue_is_alpha_char:
    mov eax, dword ptr [A1]
    // 大写: cp - 'A' <= 25
    mov ecx, eax
    sub ecx, 0x41            // 'A'
    cmp ecx, 25              // 'Z' - 'A'
    setbe cl
    // 小写: cp - 'a' <= 25
    sub eax, 0x61            // 'a'
    cmp eax, 25              // 'z' - 'a'
    setbe al
    or al, cl
    movzx eax, al
    ret

// Unix: 标记栈段不可执行 (避免 executable stack 警告)
#ifndef _WIN32
.section .note.GNU-stack,"",@progbits
#endif
