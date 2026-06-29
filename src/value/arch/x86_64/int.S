// Glue Int 算术 - x86_64 跨平台 (System V + Windows)
//
// 使用 C 预处理器 #ifdef _WIN32 切换 ABI:
//   System V: rdi, rsi, rdx, rcx, r8
//   Windows:  rcx, rdx, r8,  r9,  [rsp+0x28]
//
// 状态码: 0=成功, 1=溢出, 2=除零
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
#define A3 r8
#define A4 r9
#define A3B r8b
#define A4B r9b
#else
#define A1 rdi
#define A2 rsi
#define A3 rdx
#define A4 rcx
#define A3B dl
#define A4B cl
#endif

// ============================================================
// 寄存器使用约定 (所有函数统一)
//   r10 = len (字节宽度 1/2/4/8/16)
//   r11 = signed (0 或 1)
//   rax = 操作数 a / 结果
//   r8  = 操作数 b / 临时
//   r9  = 临时
//   r12-r15, rbx = 128 位运算专用 (按需 push/pop)
//
// 5 参数函数第 5 参数 (signed 或 n):
//   System V: r8b
//   Windows:  [rsp+0x28]
// ============================================================

// ============================================================
// i8 glue_cmp_bytes([*]const u8 a, [*]const u8 b, u8 len, bool signed)
// 4 参数: A1=a, A2=b, A3B=len, A4B=signed
// 返回: al = -1 (a<b), 0 (a==b), 1 (a>b)
// ============================================================
.globl glue_cmp_bytes
glue_cmp_bytes:
    movzx r10d, A3B
    movzx r11d, A4B

    cmp r10, 16
    je .L_cmp_128

    // <=64 位: 零扩展加载 a -> rax, b -> r8
    xor rax, rax
    xor r8, r8
    cmp r10, 8
    je .L_cmp_a8
    cmp r10, 4
    je .L_cmp_a4
    cmp r10, 2
    je .L_cmp_a2
    movzx eax, byte ptr [A1]
    movzx r8d, byte ptr [A2]
    jmp .L_cmp_do
.L_cmp_a2:
    movzx eax, word ptr [A1]
    movzx r8d, word ptr [A2]
    jmp .L_cmp_do
.L_cmp_a4:
    mov eax, dword ptr [A1]
    mov r8d, dword ptr [A2]
    jmp .L_cmp_do
.L_cmp_a8:
    mov rax, qword ptr [A1]
    mov r8, qword ptr [A2]

.L_cmp_do:
    test r11, r11
    jnz .L_cmp_signed

    // 无符号比较
    cmp rax, r8
    ja .L_cmp_gt
    jb .L_cmp_lt
    xor eax, eax
    ret

.L_cmp_signed:
    // 按位宽符号扩展到 64 位
    cmp r10, 8
    je .L_cmp_signed_do
    cmp r10, 4
    je .L_cmp_se32
    cmp r10, 2
    je .L_cmp_se16
    movsx rax, al
    movsx r8, r8b
    jmp .L_cmp_signed_do
.L_cmp_se16:
    movsx rax, ax
    movsx r8, r8w
    jmp .L_cmp_signed_do
.L_cmp_se32:
    movsxd rax, eax
    movsxd r8, r8d
.L_cmp_signed_do:
    cmp rax, r8
    jg .L_cmp_gt
    jl .L_cmp_lt
    xor eax, eax
    ret

.L_cmp_gt:
    mov eax, 1
    ret
.L_cmp_lt:
    mov eax, -1
    ret

// ---- 128 位比较 ----
.L_cmp_128:
    mov rax, qword ptr [A1+8]
    mov r8, qword ptr [A2+8]
    test r11, r11
    jnz .L_cmp_128_signed

    cmp rax, r8
    ja .L_cmp_gt
    jb .L_cmp_lt
    mov rax, qword ptr [A1]
    mov r8, qword ptr [A2]
    cmp rax, r8
    ja .L_cmp_gt
    jb .L_cmp_lt
    xor eax, eax
    ret

.L_cmp_128_signed:
    cmp rax, r8
    jg .L_cmp_gt
    jl .L_cmp_lt
    mov rax, qword ptr [A1]
    mov r8, qword ptr [A2]
    cmp rax, r8
    ja .L_cmp_gt
    jb .L_cmp_lt
    xor eax, eax
    ret

// ============================================================
// u8 glue_add_bytes([*]u8 out, [*]const u8 a, [*]const u8 b, u8 len, bool signed)
// 5 参数: A1=out, A2=a, A3=b, A4B=len, 第5参数=signed
// 返回: 0=成功, 1=溢出
// ============================================================
.globl glue_add_bytes
glue_add_bytes:
    movzx r10d, A4B
#ifdef _WIN32
    movzx r11d, byte ptr [rsp+0x28]
#else
    movzx r11d, r8b
#endif

    cmp r10, 16
    je .L_add_128

    // <=64 位: 零扩展加载 a -> rax, b -> r8, 按位宽 add
    cmp r10, 8
    je .L_add_ld8
    cmp r10, 4
    je .L_add_ld4
    cmp r10, 2
    je .L_add_ld2
    movzx eax, byte ptr [A2]
    movzx r8d, byte ptr [A3]
    add al, r8b
    jmp .L_add_store
.L_add_ld2:
    movzx eax, word ptr [A2]
    movzx r8d, word ptr [A3]
    add ax, r8w
    jmp .L_add_store
.L_add_ld4:
    mov eax, dword ptr [A2]
    mov r8d, dword ptr [A3]
    add eax, r8d
    jmp .L_add_store
.L_add_ld8:
    mov rax, qword ptr [A2]
    mov r8, qword ptr [A3]
    add rax, r8

.L_add_store:
    setc r9b
    seto r8b
    cmp r10, 8
    je .L_add_st8
    cmp r10, 4
    je .L_add_st4
    cmp r10, 2
    je .L_add_st2
    mov byte ptr [A1], al
    jmp .L_add_check
.L_add_st2:
    mov word ptr [A1], ax
    jmp .L_add_check
.L_add_st4:
    mov dword ptr [A1], eax
    jmp .L_add_check
.L_add_st8:
    mov qword ptr [A1], rax

.L_add_check:
    test r11, r11
    jnz .L_add_signed
    test r9b, r9b
    jnz .L_add_ovf
    xor eax, eax
    ret
.L_add_signed:
    test r8b, r8b
    jnz .L_add_ovf
    xor eax, eax
    ret
.L_add_ovf:
    mov eax, 1
    ret

.L_add_128:
    // 保存 b 指针到 rbx (Windows 下 A3=r8, 不能用 r8 做 scratch 后再访问 [A3])
    push rbx
    mov rbx, A3
    mov rax, qword ptr [A2]
    mov r8, qword ptr [rbx]
    add rax, r8
    mov qword ptr [A1], rax
    mov rax, qword ptr [A2+8]
    mov r8, qword ptr [rbx+8]
    adc rax, r8
    mov qword ptr [A1+8], rax
    setc r9b
    seto r8b
    pop rbx
    jmp .L_add_check

// ============================================================
// u8 glue_sub_bytes([*]u8 out, [*]const u8 a, [*]const u8 b, u8 len, bool signed)
// 5 参数: A1=out, A2=a, A3=b, A4B=len, 第5参数=signed
// 返回: 0=成功, 1=溢出
// ============================================================
.globl glue_sub_bytes
glue_sub_bytes:
    movzx r10d, A4B
#ifdef _WIN32
    movzx r11d, byte ptr [rsp+0x28]
#else
    movzx r11d, r8b
#endif

    cmp r10, 16
    je .L_sub_128

    cmp r10, 8
    je .L_sub_ld8
    cmp r10, 4
    je .L_sub_ld4
    cmp r10, 2
    je .L_sub_ld2
    movzx eax, byte ptr [A2]
    movzx r8d, byte ptr [A3]
    sub al, r8b
    jmp .L_sub_store
.L_sub_ld2:
    movzx eax, word ptr [A2]
    movzx r8d, word ptr [A3]
    sub ax, r8w
    jmp .L_sub_store
.L_sub_ld4:
    mov eax, dword ptr [A2]
    mov r8d, dword ptr [A3]
    sub eax, r8d
    jmp .L_sub_store
.L_sub_ld8:
    mov rax, qword ptr [A2]
    mov r8, qword ptr [A3]
    sub rax, r8

.L_sub_store:
    setc r9b
    seto r8b
    cmp r10, 8
    je .L_sub_st8
    cmp r10, 4
    je .L_sub_st4
    cmp r10, 2
    je .L_sub_st2
    mov byte ptr [A1], al
    jmp .L_sub_check
.L_sub_st2:
    mov word ptr [A1], ax
    jmp .L_sub_check
.L_sub_st4:
    mov dword ptr [A1], eax
    jmp .L_sub_check
.L_sub_st8:
    mov qword ptr [A1], rax

.L_sub_check:
    test r11, r11
    jnz .L_sub_signed
    test r9b, r9b
    jnz .L_sub_ovf
    xor eax, eax
    ret
.L_sub_signed:
    test r8b, r8b
    jnz .L_sub_ovf
    xor eax, eax
    ret
.L_sub_ovf:
    mov eax, 1
    ret

.L_sub_128:
    // 保存 b 指针到 rbx (Windows 下 A3=r8, 不能用 r8 做 scratch 后再访问 [A3])
    push rbx
    mov rbx, A3
    mov rax, qword ptr [A2]
    mov r8, qword ptr [rbx]
    sub rax, r8
    mov qword ptr [A1], rax
    mov rax, qword ptr [A2+8]
    mov r8, qword ptr [rbx+8]
    sbb rax, r8
    mov qword ptr [A1+8], rax
    setc r9b
    seto r8b
    pop rbx
    jmp .L_sub_check

// ============================================================
// u8 glue_mul_bytes([*]u8 out, [*]const u8 a, [*]const u8 b, u8 len, bool signed)
// 5 参数: A1=out, A2=a, A3=b, A4B=len, 第5参数=signed
// 返回: 0=成功, 1=溢出
// ============================================================
.globl glue_mul_bytes
glue_mul_bytes:
    movzx r10d, A4B
#ifdef _WIN32
    movzx r11d, byte ptr [rsp+0x28]
#else
    movzx r11d, r8b
#endif

    cmp r10, 16
    je .L_mul_128

    test r11, r11
    jnz .L_mul_signed

    // ---- 无符号 <=64 位 ----
    cmp r10, 8
    je .L_mul_u8
    cmp r10, 4
    je .L_mul_u4
    cmp r10, 2
    je .L_mul_u2
    movzx eax, byte ptr [A2]
    movzx r8d, byte ptr [A3]
    mul r8
    test rdx, rdx
    jnz .L_mul_ovf
    mov r9, rax
    shr r9, 8
    jnz .L_mul_ovf
    jmp .L_mul_st1
.L_mul_u2:
    movzx eax, word ptr [A2]
    movzx r8d, word ptr [A3]
    mul r8
    test rdx, rdx
    jnz .L_mul_ovf
    mov r9, rax
    shr r9, 16
    jnz .L_mul_ovf
    jmp .L_mul_st2
.L_mul_u4:
    mov eax, dword ptr [A2]
    mov r8d, dword ptr [A3]
    mul r8
    test rdx, rdx
    jnz .L_mul_ovf
    mov r9, rax
    shr r9, 32
    jnz .L_mul_ovf
    jmp .L_mul_st4
.L_mul_u8:
    mov rax, qword ptr [A2]
    mov r8, qword ptr [A3]
    mul r8
    test rdx, rdx
    jnz .L_mul_ovf
    jmp .L_mul_st8

.L_mul_signed:
    // ---- 有符号 <=64 位: 符号扩展到 64 位, imul ----
    cmp r10, 8
    je .L_mul_s8
    cmp r10, 4
    je .L_mul_s4
    cmp r10, 2
    je .L_mul_s2
    movsx rax, byte ptr [A2]
    movsx r8, byte ptr [A3]
    imul rax, r8
    movsx r9, al
    cmp r9, rax
    jne .L_mul_ovf
    jmp .L_mul_st1
.L_mul_s2:
    movsx rax, word ptr [A2]
    movsx r8, word ptr [A3]
    imul rax, r8
    movsx r9, ax
    cmp r9, rax
    jne .L_mul_ovf
    jmp .L_mul_st2
.L_mul_s4:
    movsxd rax, dword ptr [A2]
    movsxd r8, dword ptr [A3]
    imul rax, r8
    movsxd r9, eax
    cmp r9, rax
    jne .L_mul_ovf
    jmp .L_mul_st4
.L_mul_s8:
    mov rax, qword ptr [A2]
    mov r8, qword ptr [A3]
    imul rax, r8
    jo .L_mul_ovf
    jmp .L_mul_st8

.L_mul_st1:
    mov byte ptr [A1], al
    xor eax, eax
    ret
.L_mul_st2:
    mov word ptr [A1], ax
    xor eax, eax
    ret
.L_mul_st4:
    mov dword ptr [A1], eax
    xor eax, eax
    ret
.L_mul_st8:
    mov qword ptr [A1], rax
    xor eax, eax
    ret
.L_mul_ovf:
    // 溢出时仍需存储截断结果 (rax 低位有效), @mulWithOverflow 返回 wrap 后的值
    cmp r10, 8
    je .L_mul_ovf_st8
    cmp r10, 4
    je .L_mul_ovf_st4
    cmp r10, 2
    je .L_mul_ovf_st2
    mov byte ptr [A1], al
    jmp .L_mul_ovf_ret
.L_mul_ovf_st2:
    mov word ptr [A1], ax
    jmp .L_mul_ovf_ret
.L_mul_ovf_st4:
    mov dword ptr [A1], eax
    jmp .L_mul_ovf_ret
.L_mul_ovf_st8:
    mov qword ptr [A1], rax
.L_mul_ovf_ret:
    mov eax, 1
    ret

.L_mul_128:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, qword ptr [A2]       // a_lo
    mov r13, qword ptr [A2+8]     // a_hi
    mov r14, qword ptr [A3]       // b_lo
    mov r15, qword ptr [A3+8]     // b_hi

    xor ebx, ebx                  // result_sign = 0

    test r11, r11
    jz .L_mul_128_do

    // 有符号: 取绝对值, 跟踪符号
    bt r13, 63
    jnc .L_mul_s_a_ok
    not r12
    not r13
    add r12, 1
    adc r13, 0
    inc ebx
.L_mul_s_a_ok:
    bt r15, 63
    jnc .L_mul_128_do
    not r14
    not r15
    add r14, 1
    adc r15, 0
    inc ebx

.L_mul_128_do:
    // schoolbook: r12:r13 * r14:r15
    mov rax, r12
    mul r14                       // p0 = a_lo * b_lo
    mov r8, rax                   // result_lo
    mov r9, rdx                   // result_hi

    mov rax, r12
    mul r15                       // p1 = a_lo * b_hi
    add r9, rax
    xor r10d, r10d
    adc r10, rdx                  // overflow += p1_hi + CF

    mov rax, r13
    mul r14                       // p2 = a_hi * b_lo
    add r9, rax
    adc r10, rdx

    mov rax, r13
    mul r15                       // p3 = a_hi * b_hi
    add r10, rax
    adc r10, 0
    or r10, rdx                   // r10 = bits 128+

    // r8:r9 = 128 位 magnitude, r10 = 高位溢出, ebx = 符号
    test r11, r11
    jz .L_mul_128_u_chk

    // 有符号溢出检查
    test r10, r10
    jnz .L_mul_128_ovf
    test bl, 1
    jnz .L_mul_128_neg_chk
    // 正结果: magnitude >= 2^127 → 溢出
    bt r9, 63
    jc .L_mul_128_ovf
    jmp .L_mul_128_store
.L_mul_128_neg_chk:
    // 负结果: magnitude > 2^127 → 溢出
    bt r9, 63
    jnc .L_mul_128_store
    mov rax, r9
    shl rax, 1
    jnz .L_mul_128_ovf            // r9 > 2^63
    test r8, r8
    jnz .L_mul_128_ovf            // r9 == 2^63 且 r8 != 0
    jmp .L_mul_128_store

.L_mul_128_u_chk:
    test r10, r10
    jnz .L_mul_128_ovf

.L_mul_128_store:
    test r11, r11
    jz .L_mul_128_raw
    test bl, 1
    jz .L_mul_128_raw
    not r8
    not r9
    add r8, 1
    adc r9, 0
.L_mul_128_raw:
    mov qword ptr [A1], r8
    mov qword ptr [A1+8], r9
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.L_mul_128_ovf:
    test r11, r11
    jz .L_mul_128_ovf_raw
    test bl, 1
    jz .L_mul_128_ovf_raw
    not r8
    not r9
    add r8, 1
    adc r9, 0
.L_mul_128_ovf_raw:
    mov qword ptr [A1], r8
    mov qword ptr [A1+8], r9
    mov eax, 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

// ============================================================
// u8 glue_divmod_bytes([*]u8 out_q, [*]u8 out_r,
//                      [*]const u8 a, [*]const u8 b, u8 len, bool signed)
// 6 参数: A1=out_q, A2=out_r, A3=a, A4=b, 第5=len, 第6=signed
// 返回: 0=成功, 2=除零
// 注意: minInt/-1 由 Zig 层在调用前拦截 (≤64位 idiv 会 #DE)
//       128 位算法天然处理 (位运算回绕)
// ============================================================
.globl glue_divmod_bytes
glue_divmod_bytes:
#ifdef _WIN32
    movzx r10d, byte ptr [rsp+0x28]    // len (第5参数)
    movzx r11d, byte ptr [rsp+0x30]    // signed (第6参数)
#else
    movzx r10d, r8b                    // len (第5参数)
    movzx r11d, r9b                    // signed (第6参数)
#endif

    cmp r10, 16
    je .L_divmod_128

    // ---- ≤64 位: 保存 out 指针, 加载 a/b, div/idiv ----
    push rbx
    push r12
    mov rbx, A1                       // out_q
    mov r12, A2                       // out_r

    cmp r10, 8
    je .L_dm_ld8
    cmp r10, 4
    je .L_dm_ld4
    cmp r10, 2
    je .L_dm_ld2
    movzx eax, byte ptr [A3]
    movzx r8d, byte ptr [A4]
    jmp .L_dm_do
.L_dm_ld2:
    movzx eax, word ptr [A3]
    movzx r8d, word ptr [A4]
    jmp .L_dm_do
.L_dm_ld4:
    mov eax, dword ptr [A3]
    mov r8d, dword ptr [A4]
    jmp .L_dm_do
.L_dm_ld8:
    mov rax, qword ptr [A3]
    mov r8, qword ptr [A4]

.L_dm_do:
    test r8, r8
    jz .L_dm_zero

    test r11, r11
    jnz .L_dm_signed

    // 无符号: rdx=0, div r8
    xor rdx, rdx
    div r8                            // rax=商, rdx=余
    jmp .L_dm_store

.L_dm_signed:
    // 有符号: 符号扩展 a, b 到 64 位, cqo, idiv r8
    cmp r10, 8
    je .L_dm_s_do
    cmp r10, 4
    je .L_dm_s_se32
    cmp r10, 2
    je .L_dm_s_se16
    movsx rax, al
    movsx r8, r8b
    jmp .L_dm_s_do
.L_dm_s_se16:
    movsx rax, ax
    movsx r8, r8w
    jmp .L_dm_s_do
.L_dm_s_se32:
    movsxd rax, eax
    movsxd r8, r8d
.L_dm_s_do:
    cqo                               // 符号扩展 rax → rdx:rax
    idiv r8                           // rax=商, rdx=余

.L_dm_store:
    // 按位宽存储商(rax)和余数(rdx)
    cmp r10, 8
    je .L_dm_st8
    cmp r10, 4
    je .L_dm_st4
    cmp r10, 2
    je .L_dm_st2
    mov byte ptr [rbx], al
    mov byte ptr [r12], dl
    jmp .L_dm_done
.L_dm_st2:
    mov word ptr [rbx], ax
    mov word ptr [r12], dx
    jmp .L_dm_done
.L_dm_st4:
    mov dword ptr [rbx], eax
    mov dword ptr [r12], edx
    jmp .L_dm_done
.L_dm_st8:
    mov qword ptr [rbx], rax
    mov qword ptr [r12], rdx

.L_dm_done:
    xor eax, eax
    pop r12
    pop rbx
    ret

.L_dm_zero:
    mov eax, 2
    pop r12
    pop rbx
    ret

// ---- 128 位除法: 逐位恢复余数法 ----
.L_divmod_128:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    push A1                           // out_q  [rsp+8]
    push A2                           // out_r  [rsp+0]

    // 加载被除数 a → r12:r13 (lo:hi)
    mov r12, qword ptr [A3]
    mov r13, qword ptr [A3+8]
    // 加载除数 b → r14:r15 (lo:hi)
    mov r14, qword ptr [A4]
    mov r15, qword ptr [A4+8]

    // 检查除数 == 0
    mov rax, r14
    or rax, r15
    jz .L_dm_128_zero

    // 有符号: 取绝对值, 跟踪符号
    test r11, r11
    jz .L_dm_128_body

    xor r10, r10                      // r10 = a_neg
    xor r9, r9                        // r9 = b_neg
    bt r13, 63
    jnc .L_dm_128_a_ok
    not r12
    not r13
    add r12, 1
    adc r13, 0
    mov r10, 1
.L_dm_128_a_ok:
    bt r15, 63
    jnc .L_dm_128_body
    not r14
    not r15
    add r14, 1
    adc r15, 0
    mov r9, 1

.L_dm_128_body:
    // 无符号除法: r12:r13 (被除数→商) / r14:r15 (除数)
    // 余数 → rbx:rbp (初始化 0)
    xor rbx, rbx
    xor rbp, rbp
    mov rcx, 128                      // 128 次迭代

.L_dm_128_loop:
    // 被除数左移1位, MSB → CF → 余数
    shl r12, 1
    rcl r13, 1
    rcl rbx, 1
    rcl rbp, 1

    // 比较 余数(rbx:rbp) >= 除数(r14:r15)?
    cmp rbp, r15
    jb .L_dm_128_skip
    ja .L_dm_128_sub
    cmp rbx, r14
    jb .L_dm_128_skip
.L_dm_128_sub:
    sub rbx, r14
    sbb rbp, r15
    or r12, 1                         // 设置商位
.L_dm_128_skip:
    dec rcx
    jnz .L_dm_128_loop

    // r12:r13 = 商, rbx:rbp = 余数
    // 有符号: 修正符号
    test r11, r11
    jz .L_dm_128_store

    // 商符号 = a_neg XOR b_neg
    mov rax, r10
    xor rax, r9
    test rax, rax
    jz .L_dm_128_rem
    not r12
    not r13
    add r12, 1
    adc r13, 0

.L_dm_128_rem:
    // 余数符号 = a_neg
    test r10, r10
    jz .L_dm_128_store
    not rbx
    not rbp
    add rbx, 1
    adc rbp, 0

.L_dm_128_store:
    mov rax, qword ptr [rsp+8]        // out_q
    mov qword ptr [rax], r12
    mov qword ptr [rax+8], r13
    mov rax, qword ptr [rsp]          // out_r
    mov qword ptr [rax], rbx
    mov qword ptr [rax+8], rbp

    xor eax, eax
    pop A2
    pop A1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

.L_dm_128_zero:
    mov eax, 2
    pop A2
    pop A1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

// ============================================================
// void glue_and_bytes([*]u8 out, [*]const u8 a, [*]const u8 b, u8 len)
// 4 参数: A1=out, A2=a, A3=b, A4B=len
// ============================================================
.globl glue_and_bytes
glue_and_bytes:
    movzx r10d, A4B
    cmp r10, 16
    je .L_and_128
    cmp r10, 8
    je .L_and_8
    cmp r10, 4
    je .L_and_4
    cmp r10, 2
    je .L_and_2
    movzx eax, byte ptr [A2]
    movzx r8d, byte ptr [A3]
    and al, r8b
    mov byte ptr [A1], al
    ret
.L_and_2:
    movzx eax, word ptr [A2]
    movzx r8d, word ptr [A3]
    and ax, r8w
    mov word ptr [A1], ax
    ret
.L_and_4:
    mov eax, dword ptr [A2]
    mov r8d, dword ptr [A3]
    and eax, r8d
    mov dword ptr [A1], eax
    ret
.L_and_8:
    mov rax, qword ptr [A2]
    mov r8, qword ptr [A3]
    and rax, r8
    mov qword ptr [A1], rax
    ret
.L_and_128:
    push rbx
    mov rbx, A3
    mov rax, qword ptr [A2]
    mov r8, qword ptr [rbx]
    and rax, r8
    mov qword ptr [A1], rax
    mov rax, qword ptr [A2+8]
    mov r8, qword ptr [rbx+8]
    and rax, r8
    mov qword ptr [A1+8], rax
    pop rbx
    ret

// ============================================================
// void glue_or_bytes([*]u8 out, [*]const u8 a, [*]const u8 b, u8 len)
// 4 参数: A1=out, A2=a, A3=b, A4B=len
// ============================================================
.globl glue_or_bytes
glue_or_bytes:
    movzx r10d, A4B
    cmp r10, 16
    je .L_or_128
    cmp r10, 8
    je .L_or_8
    cmp r10, 4
    je .L_or_4
    cmp r10, 2
    je .L_or_2
    movzx eax, byte ptr [A2]
    movzx r8d, byte ptr [A3]
    or al, r8b
    mov byte ptr [A1], al
    ret
.L_or_2:
    movzx eax, word ptr [A2]
    movzx r8d, word ptr [A3]
    or ax, r8w
    mov word ptr [A1], ax
    ret
.L_or_4:
    mov eax, dword ptr [A2]
    mov r8d, dword ptr [A3]
    or eax, r8d
    mov dword ptr [A1], eax
    ret
.L_or_8:
    mov rax, qword ptr [A2]
    mov r8, qword ptr [A3]
    or rax, r8
    mov qword ptr [A1], rax
    ret
.L_or_128:
    push rbx
    mov rbx, A3
    mov rax, qword ptr [A2]
    mov r8, qword ptr [rbx]
    or rax, r8
    mov qword ptr [A1], rax
    mov rax, qword ptr [A2+8]
    mov r8, qword ptr [rbx+8]
    or rax, r8
    mov qword ptr [A1+8], rax
    pop rbx
    ret

// ============================================================
// void glue_xor_bytes([*]u8 out, [*]const u8 a, [*]const u8 b, u8 len)
// 4 参数: A1=out, A2=a, A3=b, A4B=len
// ============================================================
.globl glue_xor_bytes
glue_xor_bytes:
    movzx r10d, A4B
    cmp r10, 16
    je .L_xor_128
    cmp r10, 8
    je .L_xor_8
    cmp r10, 4
    je .L_xor_4
    cmp r10, 2
    je .L_xor_2
    movzx eax, byte ptr [A2]
    movzx r8d, byte ptr [A3]
    xor al, r8b
    mov byte ptr [A1], al
    ret
.L_xor_2:
    movzx eax, word ptr [A2]
    movzx r8d, word ptr [A3]
    xor ax, r8w
    mov word ptr [A1], ax
    ret
.L_xor_4:
    mov eax, dword ptr [A2]
    mov r8d, dword ptr [A3]
    xor eax, r8d
    mov dword ptr [A1], eax
    ret
.L_xor_8:
    mov rax, qword ptr [A2]
    mov r8, qword ptr [A3]
    xor rax, r8
    mov qword ptr [A1], rax
    ret
.L_xor_128:
    push rbx
    mov rbx, A3
    mov rax, qword ptr [A2]
    mov r8, qword ptr [rbx]
    xor rax, r8
    mov qword ptr [A1], rax
    mov rax, qword ptr [A2+8]
    mov r8, qword ptr [rbx+8]
    xor rax, r8
    mov qword ptr [A1+8], rax
    pop rbx
    ret

// ============================================================
// void glue_not_bytes([*]u8 out, [*]const u8 a, u8 len)
// 3 参数: A1=out, A2=a, A3B=len
// ============================================================
.globl glue_not_bytes
glue_not_bytes:
    movzx r10d, A3B
    cmp r10, 16
    je .L_not_128
    cmp r10, 8
    je .L_not_8
    cmp r10, 4
    je .L_not_4
    cmp r10, 2
    je .L_not_2
    movzx eax, byte ptr [A2]
    not al
    mov byte ptr [A1], al
    ret
.L_not_2:
    movzx eax, word ptr [A2]
    not ax
    mov word ptr [A1], ax
    ret
.L_not_4:
    mov eax, dword ptr [A2]
    not eax
    mov dword ptr [A1], eax
    ret
.L_not_8:
    mov rax, qword ptr [A2]
    not rax
    mov qword ptr [A1], rax
    ret
.L_not_128:
    mov rax, qword ptr [A2]
    not rax
    mov qword ptr [A1], rax
    mov rax, qword ptr [A2+8]
    not rax
    mov qword ptr [A1+8], rax
    ret

// ============================================================
// void glue_shl_bytes([*]u8 out, [*]const u8 a, u8 len, u8 n)
// 4 参数: A1=out, A2=a, A3B=len, A4B=n
// 逻辑左移, n >= bitWidth → 0
// ============================================================
.globl glue_shl_bytes
glue_shl_bytes:
    movzx r10d, A3B                    // len
    movzx r11d, A4B                    // n

    // 保存 out 指针到 rbx (cl 用于移位, Windows 下 rcx=out 会被覆盖)
    push rbx
    mov rbx, A1
    mov cl, r11b                       // cl = n (System V 上 A4=rcx 已有 n, 冗余但正确)

    cmp r10, 16
    je .L_shl_128

    // ≤64 位: 检查 n >= bitWidth
    mov r9, r10
    shl r9, 3                          // r9 = bitWidth
    cmp r11, r9
    jae .L_shl_zero

    // 加载 a
    cmp r10, 8
    je .L_shl_ld8
    cmp r10, 4
    je .L_shl_ld4
    cmp r10, 2
    je .L_shl_ld2
    movzx eax, byte ptr [A2]
    shl ax, cl
    mov byte ptr [rbx], al
    jmp .L_shl_done
.L_shl_ld2:
    movzx eax, word ptr [A2]
    shl ax, cl
    mov word ptr [rbx], ax
    jmp .L_shl_done
.L_shl_ld4:
    mov eax, dword ptr [A2]
    shl eax, cl
    mov dword ptr [rbx], eax
    jmp .L_shl_done
.L_shl_ld8:
    mov rax, qword ptr [A2]
    shl rax, cl
    mov qword ptr [rbx], rax
    jmp .L_shl_done

.L_shl_zero:
    xor eax, eax
    cmp r10, 8
    je .L_shl_z8
    cmp r10, 4
    je .L_shl_z4
    cmp r10, 2
    je .L_shl_z2
    mov byte ptr [rbx], 0
    jmp .L_shl_done
.L_shl_z2:
    mov word ptr [rbx], 0
    jmp .L_shl_done
.L_shl_z4:
    mov dword ptr [rbx], 0
    jmp .L_shl_done
.L_shl_z8:
    mov qword ptr [rbx], 0

.L_shl_done:
    pop rbx
    ret

.L_shl_128:
    // n in r11/cl
    cmp r11, 128
    jae .L_shl_128_zero
    test r11, r11
    jz .L_shl_128_copy

    mov rax, qword ptr [A2]            // low
    mov r8, qword ptr [A2+8]           // high

    cmp r11, 64
    je .L_shl_128_eq64
    jb .L_shl_128_lt64

    // n > 64: high = low << (n-64), low = 0
    mov cl, r11b
    sub cl, 64
    shl rax, cl
    mov r8, rax
    xor rax, rax
    jmp .L_shl_128_store

.L_shl_128_lt64:
    // n < 64: shld high, low, n; shl low, n
    mov cl, r11b
    shld r8, rax, cl
    shl rax, cl
    jmp .L_shl_128_store

.L_shl_128_eq64:
    mov r8, rax
    xor rax, rax

.L_shl_128_store:
    mov qword ptr [rbx], rax
    mov qword ptr [rbx+8], r8
    pop rbx
    ret

.L_shl_128_zero:
    mov qword ptr [rbx], 0
    mov qword ptr [rbx+8], 0
    pop rbx
    ret

.L_shl_128_copy:
    mov rax, qword ptr [A2]
    mov r8, qword ptr [A2+8]
    mov qword ptr [rbx], rax
    mov qword ptr [rbx+8], r8
    pop rbx
    ret

// ============================================================
// void glue_shr_bytes([*]u8 out, [*]const u8 a, u8 len, bool signed, u8 n)
// 5 参数: A1=out, A2=a, A3B=len, A4B=signed, 第5=n
// 逻辑/算术右移, n >= bitWidth → 0 (逻辑) 或 符号填充 (算术)
// ============================================================
.globl glue_shr_bytes
glue_shr_bytes:
    movzx r10d, A3B                    // len
    movzx r11d, A4B                    // signed
#ifdef _WIN32
    movzx r9d, byte ptr [rsp+0x28]     // n (第5参数)
#else
    movzx r9d, r8b                     // n (第5参数)
#endif

    // 保存 out 指针到 rbx (cl 用于移位)
    push rbx
    mov rbx, A1

    cmp r10, 16
    je .L_shr_128

    // ≤64 位: 检查 n >= bitWidth
    mov rax, r10
    shl rax, 3                         // rax = bitWidth
    cmp r9, rax
    jae .L_shr_fill

    // 加载 a
    cmp r10, 8
    je .L_shr_ld8
    cmp r10, 4
    je .L_shr_ld4
    cmp r10, 2
    je .L_shr_ld2
    movzx eax, byte ptr [A2]
    jmp .L_shr_do
.L_shr_ld2:
    movzx eax, word ptr [A2]
    jmp .L_shr_do
.L_shr_ld4:
    mov eax, dword ptr [A2]
    jmp .L_shr_do
.L_shr_ld8:
    mov rax, qword ptr [A2]

.L_shr_do:
    mov cl, r9b                        // cl = n
    test r11, r11
    jnz .L_shr_arith

    // 逻辑右移
    shr rax, cl
    jmp .L_shr_store

.L_shr_arith:
    // 算术右移: 先符号扩展到 64 位, 再 sar
    cmp r10, 8
    je .L_shr_arith_do
    cmp r10, 4
    je .L_shr_arith_se32
    cmp r10, 2
    je .L_shr_arith_se16
    movsx rax, al
    jmp .L_shr_arith_do
.L_shr_arith_se16:
    movsx rax, ax
    jmp .L_shr_arith_do
.L_shr_arith_se32:
    movsxd rax, eax
.L_shr_arith_do:
    sar rax, cl
    jmp .L_shr_store

.L_shr_store:
    cmp r10, 8
    je .L_shr_st8
    cmp r10, 4
    je .L_shr_st4
    cmp r10, 2
    je .L_shr_st2
    mov byte ptr [rbx], al
    jmp .L_shr_done
.L_shr_st2:
    mov word ptr [rbx], ax
    jmp .L_shr_done
.L_shr_st4:
    mov dword ptr [rbx], eax
    jmp .L_shr_done
.L_shr_st8:
    mov qword ptr [rbx], rax

.L_shr_done:
    pop rbx
    ret

.L_shr_fill:
    // n >= bitWidth: 逻辑→0, 算术→符号填充
    test r11, r11
    jnz .L_shr_fill_signed
    xor eax, eax
    jmp .L_shr_store

.L_shr_fill_signed:
    // 加载 a, 检查符号
    cmp r10, 8
    je .L_shr_fs8
    cmp r10, 4
    je .L_shr_fs4
    cmp r10, 2
    je .L_shr_fs2
    movsx rax, byte ptr [A2]
    jmp .L_shr_fs_chk
.L_shr_fs2:
    movsx rax, word ptr [A2]
    jmp .L_shr_fs_chk
.L_shr_fs4:
    movsxd rax, dword ptr [A2]
    jmp .L_shr_fs_chk
.L_shr_fs8:
    mov rax, qword ptr [A2]
.L_shr_fs_chk:
    test rax, rax
    js .L_shr_fill_neg
    xor eax, eax
    jmp .L_shr_store
.L_shr_fill_neg:
    mov rax, -1
    jmp .L_shr_store

// ---- 128 位右移 ----
.L_shr_128:
    // n in r9
    cmp r9, 128
    jae .L_shr_128_fill
    test r9, r9
    jz .L_shr_128_copy

    mov rax, qword ptr [A2]            // low
    mov r8, qword ptr [A2+8]           // high

    cmp r9, 64
    je .L_shr_128_eq64
    jb .L_shr_128_lt64

    // n > 64: low = high >> (n-64), high = 填充
    mov cl, r9b
    sub cl, 64
    mov rax, r8
    test r11, r11
    jnz .L_shr_128_gt64_s
    shr rax, cl
    xor r8, r8
    jmp .L_shr_128_store
.L_shr_128_gt64_s:
    sar rax, cl
    sar r8, 63                         // 符号填充 high
    jmp .L_shr_128_store

.L_shr_128_lt64:
    // n < 64: shrd low, high, n; shr/sar high, n
    mov cl, r9b
    shrd rax, r8, cl
    test r11, r11
    jnz .L_shr_128_lt64_s
    shr r8, cl
    jmp .L_shr_128_store
.L_shr_128_lt64_s:
    sar r8, cl
    jmp .L_shr_128_store

.L_shr_128_eq64:
    // low = high, high = 填充
    mov rax, r8
    test r11, r11
    jnz .L_shr_128_eq64_s
    xor r8, r8
    jmp .L_shr_128_store
.L_shr_128_eq64_s:
    sar r8, 63

.L_shr_128_store:
    mov qword ptr [rbx], rax
    mov qword ptr [rbx+8], r8
    pop rbx
    ret

.L_shr_128_fill:
    // n >= 128
    test r11, r11
    jnz .L_shr_128_fill_s
    xor eax, eax
    mov qword ptr [rbx], rax
    mov qword ptr [rbx+8], rax
    pop rbx
    ret
.L_shr_128_fill_s:
    mov rax, qword ptr [A2+8]
    test rax, rax
    js .L_shr_128_fill_neg
    xor eax, eax
    mov qword ptr [rbx], rax
    mov qword ptr [rbx+8], rax
    pop rbx
    ret
.L_shr_128_fill_neg:
    mov rax, -1
    mov qword ptr [rbx], rax
    mov qword ptr [rbx+8], rax
    pop rbx
    ret

.L_shr_128_copy:
    mov rax, qword ptr [A2]
    mov r8, qword ptr [A2+8]
    mov qword ptr [rbx], rax
    mov qword ptr [rbx+8], r8
    pop rbx
    ret

// ============================================================
// Unix: 标记栈段不可执行 (避免 executable stack 警告)
// ============================================================
#ifndef _WIN32
.section .note.GNU-stack,"",@progbits
#endif
