// Glue Float 算术 - x86_64 跨平台 (System V + Windows)
//
// 全部 5 个浮点类型（f8/f16/f32/f64/f128）统一走 IEEE 754 位运算：
//   字节数组 → unpack → decompose → 运算 → compose → 字节数组
//   结构与 int.S 一致，不使用 SSE 指令。
//
// 使用 C 预处理器 #ifdef _WIN32 切换 ABI:
//   System V: rdi, rsi, rdx, rcx
//   Windows:  rcx, rdx, r8,  r9
//
// 状态码: 0=finite, 1=NaN, 2=Inf
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
#define A3B r8b
#define A4 r9
#define A4B r9b
#else
#define A1 rdi
#define A2 rsi
#define A3 rdx
#define A3B dl
#define A4 rcx
#define A4B cl
#endif

// ============================================================
// 寄存器使用约定 (内部子程序 + 操作函数统一)
//   r12d = p        (尾数位数，不含隐含位)
//   r13d = bias     (指数偏置)
//   r14d = max_exp  ((1<<exp_bits)-1)
//   r15d = nbytes   (1/2/4/8/16)
//   rbx:rbp = 128位尾数 (rbx=hi, rbp=lo)
//   r9d  = sign
//   r8d  = exp (i32: unpack 时为 exp_field; compose 时为 unbiased)
//   r10d = stored_exp (compose 内部)
//   rdi  = out_ptr (compose/pack/store_zero)
//   rsi  = src_ptr (unpack/copy_bytes)
//   rax, rcx, rdx, r11 = 临时
// ============================================================

// ============================================================
// glue_float_load_params (内部)
// 输入: r10b = len (nbytes)
// 输出: r12d=p, r13d=bias, r14d=max_exp, r15d=nbytes
// ============================================================
glue_float_load_params:
    mov r15d, r10d
    cmp r10, 1
    je .L_lp_f8
    cmp r10, 2
    je .L_lp_f16
    cmp r10, 4
    je .L_lp_f32
    cmp r10, 8
    je .L_lp_f64
    cmp r10, 16
    je .L_lp_f128
    // 未知 len — 默认 f64 (不应到达)
    mov r12d, 52
    mov r13d, 1023
    mov r14d, 2047
    ret
.L_lp_f8:
    mov r12d, 2
    mov r13d, 15
    mov r14d, 31
    ret
.L_lp_f16:
    mov r12d, 10
    mov r13d, 15
    mov r14d, 31
    ret
.L_lp_f32:
    mov r12d, 23
    mov r13d, 127
    mov r14d, 255
    ret
.L_lp_f64:
    mov r12d, 52
    mov r13d, 1023
    mov r14d, 2047
    ret
.L_lp_f128:
    mov r12d, 112
    mov r13d, 16383
    mov r14d, 32767
    ret

// ============================================================
// glue_float_unpack (内部)
// 输入: rsi = ptr, r12=p, r14=max_exp, r15=nbytes
// 输出: r9d=sign, r8d=exp_field, rbx:rbp=mantissa(hi:lo, 未补隐含位)
// 破坏: rax, rcx, rdx, r10, r11
// ============================================================
glue_float_unpack:
    xor rbx, rbx
    xor rbp, rbp
    cmp r15, 16
    je .L_unp_ld16
    cmp r15, 8
    je .L_unp_ld8
    cmp r15, 4
    je .L_unp_ld4
    cmp r15, 2
    je .L_unp_ld2
    // len=1
    movzx rbp, byte ptr [rsi]
    jmp .L_unp_extract
.L_unp_ld2:
    movzx rbp, word ptr [rsi]
    jmp .L_unp_extract
.L_unp_ld4:
    mov ebp, dword ptr [rsi]
    jmp .L_unp_extract
.L_unp_ld8:
    mov rbp, qword ptr [rsi]
    jmp .L_unp_extract
.L_unp_ld16:
    mov rbp, qword ptr [rsi]
    mov rbx, qword ptr [rsi+8]
.L_unp_extract:
    // 提取 sign 并清除符号位
    cmp r15, 16
    je .L_unp_sign_128
    // len 1/2/4/8: sign = rbp >> (nbytes*8-1)
    mov eax, r15d
    shl eax, 3
    dec eax               // eax = nbytes*8-1
    mov ecx, eax
    mov rdx, rbp
    shr rdx, cl
    and edx, 1
    mov r9d, edx          // sign
    // 清符号位: rbp &= ~(1 << (nbytes*8-1))
    mov rdx, 1
    shl rdx, cl
    not rdx
    and rbp, rdx
    jmp .L_unp_get_exp
.L_unp_sign_128:
    mov rdx, rbx
    shr rdx, 63
    and edx, 1
    mov r9d, edx
    btr rbx, 63            // 清除符号位 (bit 63 of hi)
.L_unp_get_exp:
    // exp_field = without_sign >> p; mantissa = without_sign & ((1<<p)-1)
    cmp r12, 64
    jae .L_unp_exp_128
    // p < 64: 全在 rbp
    mov rax, rbp
    mov ecx, r12d
    shr rax, cl           // exp_field
    mov r8d, eax
    mov rax, 1
    shl rax, cl
    dec rax               // (1<<p)-1
    and rbp, rax          // mantissa 低 64 位
    xor rbx, rbx          // hi = 0
    ret
.L_unp_exp_128:
    // p >= 64 (p=112): exp_field = rbx >> (p-64); mantissa: rbp 全保留, rbx &= (1<<(p-64))-1
    mov ecx, r12d
    sub ecx, 64           // p-64 = 48
    mov rax, rbx
    shr rax, cl           // exp_field = rbx >> 48
    mov r8d, eax
    mov rax, 1
    shl rax, cl
    dec rax               // (1<<48)-1
    and rbx, rax
    ret

// ============================================================
// glue_float_shift_right_sticky (内部)
// 输入: rbx:rbp = value (hi:lo), rcx = shift (u32)
// 输出: rbx:rbp = shifted | sticky
// 破坏: rax, rdx, rcx
// ============================================================
glue_float_shift_right_sticky:
    test ecx, ecx
    jz .L_srs_ret
    cmp ecx, 128
    jae .L_srs_ge128
    // 1 <= shift < 128
    cmp ecx, 64
    jb .L_srs_lt64
    je .L_srs_eq64
    // 64 < shift < 128: s = shift - 64
    // 丢失: rbp 全部 + rbx 低 s 位
    xor edx, edx          // sticky
    test rbp, rbp
    jz .L_srs_gt64_skip_lo
    inc edx
.L_srs_gt64_skip_lo:
    sub ecx, 64           // s
    mov rax, 1
    shl rax, cl
    dec rax               // mask = (1<<s)-1
    and rax, rbx          // lost_hi
    test rax, rax
    jz .L_srs_gt64_skip_hi
    inc edx
.L_srs_gt64_skip_hi:
    shr rbx, cl           // new_lo = rbx >> s
    mov rbp, rbx
    xor rbx, rbx
    test edx, edx
    jz .L_srs_ret
    or rbp, 1
.L_srs_ret:
    ret
.L_srs_eq64:
    // new_lo = rbx, new_hi = 0; sticky = (rbp != 0)
    mov rdx, rbp
    mov rbp, rbx
    xor rbx, rbx
    test rdx, rdx
    jz .L_srs_ret
    or rbp, 1
    ret
.L_srs_lt64:
    // 1 <= shift < 64
    // lost = rbp & ((1<<shift)-1)
    mov rax, 1
    shl rax, cl
    dec rax               // mask
    and rax, rbp          // lost
    xor edx, edx
    test rax, rax
    jz .L_srs_lt64_no_lost
    inc edx
.L_srs_lt64_no_lost:
    // new_lo = (rbp >> cl) | (rbx << (64-cl)); new_hi = rbx >> cl
    shrd rbp, rbx, cl
    shr rbx, cl
    test edx, edx
    jz .L_srs_ret
    or rbp, 1
    ret
.L_srs_ge128:
    // m != 0 → 1, else 0
    mov rax, rbx
    or rax, rbp
    xor edx, edx
    test rax, rax
    jz .L_srs_ge128_zero
    mov edx, 1
.L_srs_ge128_zero:
    xor rbx, rbx
    mov rbp, rdx
    ret

// ============================================================
// glue_float_pack (内部)
// 输入: r9d=sign, r10d=stored_exp, rbx:rbp=fraction(hi:lo), r12=p, r15=nbytes, rdi=out_ptr
// 输出: 无 (存字节到 [rdi])
// 破坏: rax, rcx, rdx
// ============================================================
glue_float_pack:
    cmp r15, 16
    je .L_pack_f128
    cmp r15, 8
    je .L_pack_f64
    cmp r15, 4
    je .L_pack_f32
    cmp r15, 2
    je .L_pack_f16
.L_pack_f8:
    // p=2: raw = frac | (exp<<2) | (sign<<7)
    mov rax, r10
    shl rax, 2
    or rbp, rax
    test r9d, r9d
    jz .L_pack_f8_store
    or rbp, 0x80
.L_pack_f8_store:
    mov byte ptr [rdi], bpl
    ret
.L_pack_f16:
    mov rax, r10
    shl rax, 10
    or rbp, rax
    test r9d, r9d
    jz .L_pack_f16_store
    or rbp, 0x8000
.L_pack_f16_store:
    mov word ptr [rdi], bp
    ret
.L_pack_f32:
    mov rax, r10
    shl rax, 23
    or rbp, rax
    test r9d, r9d
    jz .L_pack_f32_store
    bts rbp, 31
.L_pack_f32_store:
    mov dword ptr [rdi], ebp
    ret
.L_pack_f64:
    mov rax, r10
    shl rax, 52
    or rbp, rax
    test r9d, r9d
    jz .L_pack_f64_store
    bts rbp, 63
.L_pack_f64_store:
    mov qword ptr [rdi], rbp
    ret
.L_pack_f128:
    // p=112: raw_lo = rbp; raw_hi = rbx | (exp<<48) | (sign<<63)
    mov rax, r10
    shl rax, 48
    or rbx, rax
    test r9d, r9d
    jz .L_pack_f128_store
    bts rbx, 63
.L_pack_f128_store:
    mov qword ptr [rdi], rbp
    mov qword ptr [rdi+8], rbx
    ret

// ============================================================
// glue_float_store_zero (内部)
// 输入: rdi=ptr, r9d=sign, r15=nbytes
// 输出: 无
// 破坏: rax, rcx
// ============================================================
glue_float_store_zero:
    cmp r15, 16
    je .L_sz_16
    cmp r15, 8
    je .L_sz_8
    cmp r15, 4
    je .L_sz_4
    cmp r15, 2
    je .L_sz_2
.L_sz_1:
    xor eax, eax
    test r9d, r9d
    jz .L_sz_1_store
    mov eax, 0x80
.L_sz_1_store:
    mov byte ptr [rdi], al
    ret
.L_sz_2:
    xor eax, eax
    test r9d, r9d
    jz .L_sz_2_store
    mov eax, 0x8000
.L_sz_2_store:
    mov word ptr [rdi], ax
    ret
.L_sz_4:
    xor eax, eax
    test r9d, r9d
    jz .L_sz_4_store
    mov eax, 0x80000000
.L_sz_4_store:
    mov dword ptr [rdi], eax
    ret
.L_sz_8:
    xor rax, rax
    test r9d, r9d
    jz .L_sz_8_store
    mov rax, 0x8000000000000000
.L_sz_8_store:
    mov qword ptr [rdi], rax
    ret
.L_sz_16:
    xor rax, rax
    xor rcx, rcx
    test r9d, r9d
    jz .L_sz_16_store
    mov rcx, 0x8000000000000000
.L_sz_16_store:
    mov qword ptr [rdi], rax
    mov qword ptr [rdi+8], rcx
    ret

// ============================================================
// glue_float_copy_bytes (内部)
// 输入: rsi=src, rdi=dst, r15=nbytes
// 输出: 无
// 破坏: rax, rcx
// ============================================================
glue_float_copy_bytes:
    cmp r15, 16
    je .L_cb_16
    cmp r15, 8
    je .L_cb_8
    cmp r15, 4
    je .L_cb_4
    cmp r15, 2
    je .L_cb_2
    movzx eax, byte ptr [rsi]
    mov byte ptr [rdi], al
    ret
.L_cb_2:
    movzx eax, word ptr [rsi]
    mov word ptr [rdi], ax
    ret
.L_cb_4:
    mov eax, dword ptr [rsi]
    mov dword ptr [rdi], eax
    ret
.L_cb_8:
    mov rax, qword ptr [rsi]
    mov qword ptr [rdi], rax
    ret
.L_cb_16:
    mov rax, qword ptr [rsi]
    mov rcx, qword ptr [rsi+8]
    mov qword ptr [rdi], rax
    mov qword ptr [rdi+8], rcx
    ret

// ============================================================
// glue_float_compose (内部, leaf)
// 输入: r9d=sign, r8d=exp(i32 unbiased), rbx:rbp=mantissa(hi:lo 含GRS),
//       r12d=p, r13d=bias, r14d=max_exp, r15d=nbytes, rdi=out_ptr
// 输出: eax=状态码(0=finite, 2=Inf)，结果存入 [rdi]
// 破坏: rax, rcx, rdx, r10, r11, r8, rbx, rbp
// ============================================================
glue_float_compose:
    // 1. m==0 → makeZero(sign)
    mov rax, rbx
    or rax, rbp
    jnz .L_comp_m_nonzero
    xor r10d, r10d         // stored_exp=0
    xor rbp, rbp
    xor rbx, rbx
    call glue_float_pack
    xor eax, eax
    ret

.L_comp_m_nonzero:
    // 2. carry 处理: m >= (1<<(p+4)) → shiftRightWithSticky(m,1), e++
    mov r10d, r12d
    add r10d, 4            // r10 = p+4
    cmp r10, 64
    jae .L_comp_carry_hi
    // p+4 < 64: carry_bit 在 rbp
    mov rax, 1
    mov rcx, r10
    shl rax, cl            // carry_bit
    test rbx, rbx
    jnz .L_comp_do_carry
    cmp rbp, rax
    jae .L_comp_do_carry
    jmp .L_comp_carry_done
.L_comp_carry_hi:
    // p+4 >= 64: carry_bit = 1<<(p+4-64) 在 rbx
    mov rcx, r10
    sub rcx, 64
    mov rax, 1
    shl rax, cl
    cmp rbx, rax
    jae .L_comp_do_carry
    jmp .L_comp_carry_done
.L_comp_do_carry:
    mov ecx, 1
    call glue_float_shift_right_sticky
    inc r8d
.L_comp_carry_done:
    // 3. 规格化: m < (1<<(p+3)) → 左移至 implicit 位置
    mov r10d, r12d
    add r10d, 3            // r10 = p+3
    cmp r10, 64
    jae .L_comp_norm_hi
    mov rax, 1
    mov rcx, r10
    shl rax, cl            // implicit_bit
    test rbx, rbx
    jnz .L_comp_norm_done
    cmp rbp, rax
    jae .L_comp_norm_done
    jmp .L_comp_do_norm
.L_comp_norm_hi:
    mov rcx, r10
    sub rcx, 64
    mov rax, 1
    shl rax, cl
    cmp rbx, rax
    jae .L_comp_norm_done
.L_comp_do_norm:
    // 计算 clz(m)
    test rbx, rbx
    jnz .L_comp_clz_hi
    bsr rax, rbp
    mov ecx, 127
    sub ecx, eax           // clz = 127 - bsr(rbp)
    jmp .L_comp_clz_have
.L_comp_clz_hi:
    bsr rax, rbx
    mov ecx, 63
    sub ecx, eax           // clz = 63 - bsr(rbx)
.L_comp_clz_have:
    // ecx = clz_m; target_clz = 124 - p
    mov edx, 124
    sub edx, r12d          // target_clz
    sub ecx, edx           // shift_amt = clz_m - target_clz
    mov r11d, ecx
    // 128 位左移 r11
    cmp r11, 64
    jb .L_comp_shl_lt64
    je .L_comp_shl_eq64
    mov rcx, r11
    sub rcx, 64
    mov rbx, rbp
    shl rbx, cl
    xor rbp, rbp
    jmp .L_comp_shl_done
.L_comp_shl_eq64:
    mov rbx, rbp
    xor rbp, rbp
    jmp .L_comp_shl_done
.L_comp_shl_lt64:
    mov rcx, r11
    shld rbx, rbp, cl
    shl rbp, cl
.L_comp_shl_done:
    sub r8d, r11d          // e -= shift_amt
.L_comp_norm_done:
    // 4. 上溢检查: e + bias >= max_exp → Inf
    mov eax, r8d
    add eax, r13d
    cmp eax, r14d
    jge .L_comp_overflow_inf
    // 5. 正规/次正规分支
    cmp eax, 1
    jge .L_comp_normal
    // 次正规: shift = 1 - bias - e; m = shiftRightWithSticky(m, shift); stored_exp=0
    mov ecx, 1
    sub ecx, r13d
    sub ecx, r8d
    call glue_float_shift_right_sticky
    xor r10d, r10d
    jmp .L_comp_round
.L_comp_normal:
    mov r10d, eax          // stored_exp = e + bias
.L_comp_round:
    // 6. RNE 舍入: g=bit2, r=bit1, s=bit0, lsb=bit3
    mov rax, rbp
    and rax, 7
    test al, 4             // g
    jz .L_comp_round_done
    test al, 3             // r|s
    jnz .L_comp_do_round
    test rbp, 8            // lsb
    jz .L_comp_round_done
.L_comp_do_round:
    and rbp, 0xFFFFFFFFFFFFFFF8
    add rbp, 8
    adc rbx, 0
.L_comp_round_done:
    // 7. 舍入后溢出检查
    test r10d, r10d
    jnz .L_comp_post_normal
    // 次正规: 若 m & (1<<(p+3)) → stored_exp=1
    mov r11d, r12d
    add r11d, 3
    cmp r11, 64
    jae .L_comp_post_sub_hi
    mov rax, 1
    mov rcx, r11
    shl rax, cl
    test rbp, rax
    jz .L_comp_pack
    mov r10d, 1
    jmp .L_comp_pack
.L_comp_post_sub_hi:
    mov rcx, r11
    sub rcx, 64
    mov rax, 1
    shl rax, cl
    test rbx, rax
    jz .L_comp_pack
    mov r10d, 1
    jmp .L_comp_pack
.L_comp_post_normal:
    // 正规: 若 m & (1<<(p+4)) → m>>=1, stored_exp++; 若 >= max_exp → Inf
    mov r11d, r12d
    add r11d, 4
    cmp r11, 64
    jae .L_comp_post_n_hi
    mov rax, 1
    mov rcx, r11
    shl rax, cl
    test rbp, rax
    jz .L_comp_pack
    jmp .L_comp_post_n_do
.L_comp_post_n_hi:
    mov rcx, r11
    sub rcx, 64
    mov rax, 1
    shl rax, cl
    test rbx, rax
    jz .L_comp_pack
.L_comp_post_n_do:
    shrd rbp, rbx, 1
    shr rbx, 1
    inc r10d
    cmp r10d, r14d
    jge .L_comp_overflow_inf
.L_comp_pack:
    // 8. fraction = (m>>3) & ((1<<p)-1); pack
    shrd rbp, rbx, 3
    shr rbx, 3
    cmp r12, 64
    jae .L_comp_mask_hi
    mov rax, 1
    mov ecx, r12d
    shl rax, cl
    dec rax
    and rbp, rax
    xor rbx, rbx
    call glue_float_pack
    xor eax, eax
    ret
.L_comp_mask_hi:
    mov ecx, r12d
    sub ecx, 64
    mov rax, 1
    shl rax, cl
    dec rax
    and rbx, rax
    call glue_float_pack
    xor eax, eax
    ret
.L_comp_overflow_inf:
    mov r10d, r14d         // stored_exp = max_exp
    xor rbp, rbp
    xor rbx, rbx
    call glue_float_pack
    mov eax, 2
    ret

// ============================================================
// u8 glue_add_float([*]u8 out, [*]const u8 a, [*]const u8 b, u8 len)
// 栈布局 (sub rsp, 0x58):
//   [rsp+0]=out, [rsp+8]=a, [rsp+16]=b,
//   [rsp+24]=sign_a, [rsp+32]=exp_a, [rsp+40]=mant_a_hi, [rsp+48]=mant_a_lo,
//   [rsp+56]=sign_b, [rsp+64]=exp_b_field, [rsp+72]=mant_b_hi, [rsp+80]=mant_b_lo
// 注: [rsp+72..88) 在 sub_float 中作为 b 缓冲区，unpack(b) 读取后即可复用为 mant_b
// ============================================================
.globl glue_add_float
glue_add_float:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 0x58
    mov [rsp+0], A1
    mov [rsp+8], A2
    mov [rsp+16], A3
    movzx r10d, A4B
    call glue_float_load_params
.L_add_main:
    // unpack a
    mov rsi, [rsp+8]
    call glue_float_unpack
    mov [rsp+24], r9       // sign_a
    mov [rsp+32], r8       // exp_a_field
    mov [rsp+40], rbx      // mant_a_hi
    mov [rsp+48], rbp      // mant_a_lo
    // unpack b
    mov rsi, [rsp+16]
    call glue_float_unpack
    mov [rsp+56], r9       // sign_b
    mov [rsp+64], r8       // exp_b_field
    // mant_b 在 rbx:rbp; 保存推迟到 .L_add_normal (避开 sub 的 b 缓冲区)

    // 特殊值: a 是 NaN/Inf? (exp_a == max_exp)
    mov eax, [rsp+32]
    cmp eax, r14d
    jne .L_add_a_not_special
    mov rax, [rsp+40]
    mov rcx, [rsp+48]
    or rax, rcx
    jnz .L_add_ret_nan     // a NaN
    // a Inf
    mov eax, [rsp+64]
    cmp eax, r14d
    jne .L_add_copy_a_ret2 // a Inf, b 有限 → 存 a
    mov rax, rbx
    mov rcx, rbp
    or rax, rcx
    jnz .L_add_ret_nan     // b NaN
    mov eax, [rsp+24]
    cmp eax, [rsp+56]
    jne .L_add_ret_nan     // 异号 Inf
    jmp .L_add_copy_a_ret2 // 同号 Inf
.L_add_a_not_special:
    mov eax, [rsp+64]
    cmp eax, r14d
    jne .L_add_check_zero
    mov rax, rbx
    mov rcx, rbp
    or rax, rcx
    jnz .L_add_ret_nan     // b NaN
    jmp .L_add_copy_b_ret2 // b Inf
.L_add_check_zero:
    // a zero? (exp_a==0 && mant_a==0)
    mov eax, [rsp+32]
    test eax, eax
    jnz .L_add_normal
    mov rax, [rsp+40]
    mov rcx, [rsp+48]
    or rax, rcx
    jnz .L_add_normal
    // a zero
    mov eax, [rsp+64]
    test eax, eax
    jnz .L_add_a_zero_b_nonzero
    mov rax, rbx
    mov rcx, rbp
    or rax, rcx
    jnz .L_add_a_zero_b_nonzero
    // 双零
    mov eax, [rsp+24]
    cmp eax, [rsp+56]
    jne .L_add_ret_pos_zero
    mov r9d, [rsp+24]      // 同号零 → 存 sign_a 的零
    jmp .L_add_do_store_zero
.L_add_a_zero_b_nonzero:
    jmp .L_add_copy_b_ret0
.L_add_normal:
    // 保存 mant_b (rbx:rbp) 到 [rsp+72..88)，避开 sub 的 b 缓冲区
    // (此处特殊值检查已过，copy 路径不可达，缓冲区不再需要)
    mov [rsp+72], rbx
    mov [rsp+80], rbp
    // decompose a: mant_a 在 [rsp+40]:[rsp+48], exp_a_field 在 [rsp+32]
    mov rbx, [rsp+40]
    mov rbp, [rsp+48]
    mov eax, [rsp+32]
    test eax, eax
    jz .L_add_da_sub
    // 正规: m |= (1<<p); e = exp_field - bias
    cmp r12, 64
    jae .L_add_da_norm_128
    mov rax, 1
    mov ecx, r12d
    shl rax, cl
    or rbp, rax
    jmp .L_add_da_have_m
.L_add_da_norm_128:
    mov ecx, r12d
    sub ecx, 64
    mov rax, 1
    shl rax, cl
    or rbx, rax
    jmp .L_add_da_have_m
.L_add_da_sub:
    mov r8d, 1
    sub r8d, r13d
    jmp .L_add_da_after_exp
.L_add_da_have_m:
    mov r8d, [rsp+32]
    sub r8d, r13d
.L_add_da_after_exp:
    shld rbx, rbp, 3
    shl rbp, 3
    mov [rsp+32], r8       // exp_a (unbiased)
    mov [rsp+40], rbx
    mov [rsp+48], rbp
    // decompose b: 从栈恢复 mant_b → rbx:rbp, exp_b_field 在 [rsp+64]
    mov rbx, [rsp+72]
    mov rbp, [rsp+80]
    mov eax, [rsp+64]
    test eax, eax
    jz .L_add_db_sub
    cmp r12, 64
    jae .L_add_db_norm_128
    mov rax, 1
    mov ecx, r12d
    shl rax, cl
    or rbp, rax
    jmp .L_add_db_have_m
.L_add_db_norm_128:
    mov ecx, r12d
    sub ecx, 64
    mov rax, 1
    shl rax, cl
    or rbx, rax
    jmp .L_add_db_have_m
.L_add_db_sub:
    mov r8d, 1
    sub r8d, r13d
    jmp .L_add_db_after_exp
.L_add_db_have_m:
    mov r8d, [rsp+64]
    sub r8d, r13d
.L_add_db_after_exp:
    shld rbx, rbp, 3
    shl rbp, 3
    // db: r8d=exp_b(unbiased), rbx:rbp=mant_b
    // 保证 da.exp >= db.exp
    mov eax, [rsp+32]
    cmp eax, r8d
    jge .L_add_aligned
    // 交换 a/b
    mov ecx, r8d
    mov r8d, [rsp+32]
    mov [rsp+32], rcx      // exp_a = 原 exp_b
    // mant 交换
    mov rax, [rsp+40]
    mov rdx, [rsp+48]
    mov [rsp+40], rbx
    mov [rsp+48], rbp
    mov rbx, rax
    mov rbp, rdx
    // sign 交换
    mov eax, [rsp+24]
    mov ecx, [rsp+56]
    mov [rsp+24], rcx
    mov [rsp+56], eax
.L_add_aligned:
    // exp_a 在 [rsp+32], exp_b 在 r8d, mant_a 在 [rsp+40]:[rsp+48], mant_b 在 rbx:rbp
    mov ecx, [rsp+32]
    sub ecx, r8d
    call glue_float_shift_right_sticky  // rbx:rbp = shifted mant_b
    // 尾数加减
    mov rax, [rsp+40]      // mant_a_hi
    mov rdx, [rsp+48]      // mant_a_lo
    mov r10d, [rsp+24]     // sign_a
    mov r11d, [rsp+56]     // sign_b
    cmp r10d, r11d
    jne .L_add_diff_sign
    // 同号: mr = ma + mb
    add rdx, rbp
    adc rax, rbx
    mov r9d, r10d
    jmp .L_add_mr_done
.L_add_diff_sign:
    cmp rax, rbx
    jne .L_add_cmp_hi
    cmp rdx, rbp
    jne .L_add_cmp_lo
    jmp .L_add_ret_pos_zero  // ma == mb
.L_add_cmp_hi:
    ja .L_add_ma_larger
    jmp .L_add_mb_larger
.L_add_cmp_lo:
    cmp rdx, rbp
    ja .L_add_ma_larger
.L_add_mb_larger:
    sub rbp, rdx
    sbb rbx, rax
    mov rax, rbx
    mov rdx, rbp
    mov r9d, r11d
    jmp .L_add_mr_done
.L_add_ma_larger:
    sub rdx, rbp
    sbb rax, rbx
    mov r9d, r10d
.L_add_mr_done:
    // mr 在 rax:rdx (hi:lo), sr 在 r9d
    mov rcx, rax
    or rcx, rdx
    jnz .L_add_compose
    jmp .L_add_ret_pos_zero
.L_add_compose:
    mov rbx, rax
    mov rbp, rdx
    mov r8d, [rsp+32]
    mov rdi, [rsp+0]
    call glue_float_compose
    jmp .L_add_cleanup
.L_add_ret_nan:
    mov eax, 1
    jmp .L_add_cleanup
.L_add_copy_a_ret2:
    mov rsi, [rsp+8]
    mov rdi, [rsp+0]
    call glue_float_copy_bytes
    mov eax, 2
    jmp .L_add_cleanup
.L_add_copy_b_ret2:
    mov rsi, [rsp+16]
    mov rdi, [rsp+0]
    call glue_float_copy_bytes
    mov eax, 2
    jmp .L_add_cleanup
.L_add_copy_b_ret0:
    mov rsi, [rsp+16]
    mov rdi, [rsp+0]
    call glue_float_copy_bytes
    xor eax, eax
    jmp .L_add_cleanup
.L_add_do_store_zero:
    mov rdi, [rsp+0]
    call glue_float_store_zero
    xor eax, eax
    jmp .L_add_cleanup
.L_add_ret_pos_zero:
    xor r9d, r9d
    mov rdi, [rsp+0]
    call glue_float_store_zero
    xor eax, eax
.L_add_cleanup:
    add rsp, 0x58
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

// ============================================================
// u8 glue_sub_float([*]u8 out, [*]const u8 a, [*]const u8 b, u8 len)
// 实现: sub(a,b) = add(a, -b)。在栈缓冲拷贝 b 并翻转符号位，
//       然后 jmp .L_add_main 复用 add 的全部逻辑。
// ============================================================
.globl glue_sub_float
glue_sub_float:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 0x58
    mov [rsp+0], A1
    mov [rsp+8], A2
    movzx r10d, A4B
    call glue_float_load_params
    // 拷贝 b (A3) → [rsp+0x48] (16 字节缓冲)
    mov rsi, A3
    lea rdi, [rsp + 0x48]
    call glue_float_copy_bytes
    // 翻转符号位: 最高字节 ^= 0x80
    mov rax, r15          // nbytes
    dec rax
    xor byte ptr [rsp + 0x48 + rax], 0x80
    // b_ptr = &缓冲
    lea rax, [rsp + 0x48]
    mov [rsp+16], rax
    jmp .L_add_main

// ============================================================
// glue_float_normalize (内部)
// 规格化尾数至 implicit 位 (bit p+3) 置位。次正规数左移补齐，同步递减 exp。
// 输入: rbx:rbp = mantissa(hi:lo, 含GRS), r8d = exp(unbiased), r12d = p
// 输出: rbx:rbp 规格化, r8d 调整
// 破坏: rax, rcx, rdx, r11
// ============================================================
glue_float_normalize:
    mov rax, rbx
    or rax, rbp
    jz .L_norm_ret
    // implicit_bit = 1 << (p+3)
    mov ecx, r12d
    add ecx, 3
    cmp ecx, 64
    jae .L_norm_impl_hi
    // p+3 < 64: implicit_bit 在 rbp
    mov rax, 1
    shl rax, cl
    test rbx, rbx
    jnz .L_norm_ret           // hi != 0 → m >= implicit
    cmp rbp, rax
    jae .L_norm_ret           // m >= implicit
    jmp .L_norm_do
.L_norm_impl_hi:
    // p+3 >= 64: implicit_bit 在 rbx
    sub ecx, 64
    mov rax, 1
    shl rax, cl
    cmp rbx, rax
    jae .L_norm_ret
.L_norm_do:
    // clz(m)
    test rbx, rbx
    jnz .L_norm_clz_hi
    bsr rax, rbp
    mov ecx, 127
    sub ecx, eax              // clz = 127 - bsr(rbp)
    jmp .L_norm_clz_have
.L_norm_clz_hi:
    bsr rax, rbx
    mov ecx, 63
    sub ecx, eax              // clz = 63 - bsr(rbx)
.L_norm_clz_have:
    // ecx = clz; target_clz = 124 - p
    mov edx, 124
    sub edx, r12d
    sub ecx, edx              // shift_amt = clz - target_clz
    mov r11d, ecx
    // 128 位左移 r11
    cmp r11, 64
    jb .L_norm_shl_lt64
    je .L_norm_shl_eq64
    mov rcx, r11
    sub rcx, 64
    mov rbx, rbp
    shl rbx, cl
    xor rbp, rbp
    jmp .L_norm_shl_done
.L_norm_shl_eq64:
    mov rbx, rbp
    xor rbp, rbp
    jmp .L_norm_shl_done
.L_norm_shl_lt64:
    mov rcx, r11
    shld rbx, rbp, cl
    shl rbp, cl
.L_norm_shl_done:
    sub r8d, r11d             // e -= shift_amt
.L_norm_ret:
    ret

// ============================================================
// u8 glue_mul_float([*]u8 out, [*]const u8 a, [*]const u8 b, u8 len)
// 128×128→256 位乘法，IEEE 754 位运算实现。
// 栈布局 (sub rsp, 0xA8 = 168):
//   [rsp+0]=out, [rsp+8]=a, [rsp+16]=b,
//   [rsp+24]=sign_a→result_sign, [rsp+32]=exp_a_field→exp_a(unbiased),
//   [rsp+40]=mant_a_hi, [rsp+48]=mant_a_lo,
//   [rsp+56]=sign_b, [rsp+64]=exp_b_field,
//   [rsp+72]=mant_b_hi, [rsp+80]=mant_b_lo,
//   [rsp+88]=result_exp,
//   [rsp+96]=saved_p, [rsp+104]=saved_bias, [rsp+112]=saved_max_exp, [rsp+120]=saved_nbytes,
//   [rsp+128]=prod_p0, [rsp+136]=prod_p1, [rsp+144]=prod_p2, [rsp+152]=prod_p3, [rsp+160]=temp
// ============================================================
.globl glue_mul_float
glue_mul_float:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 0xA8
    mov [rsp+0], A1
    mov [rsp+8], A2
    mov [rsp+16], A3
    movzx r10d, A4B
    call glue_float_load_params

    // unpack a
    mov rsi, [rsp+8]
    call glue_float_unpack
    mov [rsp+24], r9          // sign_a
    mov [rsp+32], r8          // exp_a_field
    mov [rsp+40], rbx         // mant_a_hi
    mov [rsp+48], rbp         // mant_a_lo
    // unpack b
    mov rsi, [rsp+16]
    call glue_float_unpack
    mov [rsp+56], r9          // sign_b
    mov [rsp+64], r8          // exp_b_field
    mov [rsp+72], rbx         // mant_b_hi
    mov [rsp+80], rbp         // mant_b_lo

    // ---- 特殊值检查 ----
    // a 是 NaN/Inf? (exp_a == max_exp)
    mov eax, [rsp+32]
    cmp eax, r14d
    jne .L_mul_a_not_special
    mov rax, [rsp+40]
    or rax, [rsp+48]
    jnz .L_mul_ret_nan        // a NaN
    // a Inf
    mov eax, [rsp+64]
    cmp eax, r14d
    jne .L_mul_a_inf_b_finite
    // b 也是 special
    mov rax, [rsp+72]
    or rax, [rsp+80]
    jnz .L_mul_ret_nan        // b NaN
    jmp .L_mul_ret_inf        // Inf × Inf
.L_mul_a_inf_b_finite:
    // a Inf, b 有限. b zero → NaN, else Inf
    mov eax, [rsp+64]
    test eax, eax
    jnz .L_mul_ret_inf
    mov rax, [rsp+72]
    or rax, [rsp+80]
    jnz .L_mul_ret_inf
    jmp .L_mul_ret_nan        // Inf × 0 = NaN

.L_mul_a_not_special:
    mov eax, [rsp+64]
    cmp eax, r14d
    jne .L_mul_check_zero
    // b special (a 有限)
    mov rax, [rsp+72]
    or rax, [rsp+80]
    jnz .L_mul_ret_nan        // b NaN
    // b Inf
    mov eax, [rsp+32]
    test eax, eax
    jnz .L_mul_ret_inf
    mov rax, [rsp+40]
    or rax, [rsp+48]
    jnz .L_mul_ret_inf
    jmp .L_mul_ret_nan        // 0 × Inf = NaN

.L_mul_check_zero:
    // result_sign = sign_a ^ sign_b
    mov eax, [rsp+24]
    xor eax, [rsp+56]
    mov [rsp+24], eax         // [rsp+24] = result_sign
    // a zero?
    mov eax, [rsp+32]
    test eax, eax
    jnz .L_mul_decompose_a
    mov rax, [rsp+40]
    or rax, [rsp+48]
    jz .L_mul_ret_zero
.L_mul_decompose_a:
    // b zero?
    mov eax, [rsp+64]
    test eax, eax
    jnz .L_mul_decompose
    mov rax, [rsp+72]
    or rax, [rsp+80]
    jz .L_mul_ret_zero

.L_mul_decompose:
    // ---- decompose a ----
    mov rbx, [rsp+40]
    mov rbp, [rsp+48]
    mov eax, [rsp+32]
    test eax, eax
    jz .L_mul_da_sub
    cmp r12, 64
    jae .L_mul_da_norm_128
    mov rax, 1
    mov ecx, r12d
    shl rax, cl
    or rbp, rax
    jmp .L_mul_da_have_m
.L_mul_da_norm_128:
    mov ecx, r12d
    sub ecx, 64
    mov rax, 1
    shl rax, cl
    or rbx, rax
    jmp .L_mul_da_have_m
.L_mul_da_sub:
    mov r8d, 1
    sub r8d, r13d
    jmp .L_mul_da_after_exp
.L_mul_da_have_m:
    mov r8d, [rsp+32]
    sub r8d, r13d
.L_mul_da_after_exp:
    shld rbx, rbp, 3
    shl rbp, 3
    call glue_float_normalize
    mov [rsp+32], r8          // exp_a (unbiased, normalized)
    mov [rsp+40], rbx         // mant_a_hi
    mov [rsp+48], rbp         // mant_a_lo

    // ---- decompose b ----
    mov rbx, [rsp+72]
    mov rbp, [rsp+80]
    mov eax, [rsp+64]
    test eax, eax
    jz .L_mul_db_sub
    cmp r12, 64
    jae .L_mul_db_norm_128
    mov rax, 1
    mov ecx, r12d
    shl rax, cl
    or rbp, rax
    jmp .L_mul_db_have_m
.L_mul_db_norm_128:
    mov ecx, r12d
    sub ecx, 64
    mov rax, 1
    shl rax, cl
    or rbx, rax
    jmp .L_mul_db_have_m
.L_mul_db_sub:
    mov r8d, 1
    sub r8d, r13d
    jmp .L_mul_db_after_exp
.L_mul_db_have_m:
    mov r8d, [rsp+64]
    sub r8d, r13d
.L_mul_db_after_exp:
    shld rbx, rbp, 3
    shl rbp, 3
    call glue_float_normalize
    // r8d = exp_b (unbiased), rbx:rbp = mant_b (normalized)
    // result_exp = exp_a + exp_b
    mov eax, [rsp+32]
    add eax, r8d
    mov [rsp+88], eax         // result_exp

    // ---- 保存参数 (multiply 会用 r12-r15) ----
    mov [rsp+96], r12         // p
    mov [rsp+104], r13        // bias
    mov [rsp+112], r14        // max_exp
    mov [rsp+120], r15        // nbytes

    // ---- 128×128→256 schoolbook multiply ----
    // a = mant_a_hi:mant_a_lo = [rsp+40]:[rsp+48]
    // b = mant_b_hi:mant_b_lo = rbx:rbp (still in registers)
    mov r12, [rsp+48]         // a_lo
    mov r13, [rsp+40]         // a_hi
    mov r14, rbp              // b_lo
    mov r15, rbx              // b_hi

    // LL = a_lo * b_lo
    mov rax, r12
    mul r14                   // rdx:rax = LL
    mov [rsp+128], rax        // p0 = ll_lo
    mov r8, rdx               // ll_hi

    // LH = a_lo * b_hi
    mov rax, r12
    mul r15                   // rdx:rax = LH
    mov r9, rax               // lh_lo
    mov r10, rdx              // lh_hi

    // HL = a_hi * b_lo
    mov rax, r13
    mul r14                   // rdx:rax = HL
    mov r11, rax              // hl_lo
    mov [rsp+160], rdx        // hl_hi (temp save)

    // p1 = ll_hi + lh_lo + hl_lo
    add r8, r9                // ll_hi + lh_lo
    adc r10, 0                // propagate carry into lh_hi
    add r8, r11               // + hl_lo
    mov [rsp+136], r8         // p1
    // carry into p2: lh_hi + hl_hi + carry
    adc r10, qword ptr [rsp+160]  // c1 = lh_hi + hl_hi + carry

    // HH = a_hi * b_hi
    mov rax, r13
    mul r15                   // rdx:rax = HH
    // p2 = c1 + hh_lo
    add r10, rax              // p2
    mov [rsp+144], r10        // p2
    adc rdx, 0                // p3 = hh_hi + carry
    mov [rsp+152], rdx        // p3

    // ---- 恢复参数 ----
    mov r12, [rsp+96]         // p
    mov r13, [rsp+104]        // bias
    mov r14, [rsp+112]        // max_exp
    mov r15, [rsp+120]        // nbytes

    // ---- 进位检查: bit 2p+7 ----
    mov eax, r12d
    shl eax, 1
    add eax, 7                // eax = 2p+7
    cmp eax, 64
    jb .L_mul_carry_p0
    cmp eax, 128
    jb .L_mul_carry_p1
    cmp eax, 192
    jb .L_mul_carry_p2
    // in p3
    sub eax, 192
    mov ecx, eax
    mov rax, [rsp+152]
    bt rax, rcx
    jc .L_mul_do_carry
    jmp .L_mul_no_carry
.L_mul_carry_p2:
    sub eax, 128
    mov ecx, eax
    mov rax, [rsp+144]
    bt rax, rcx
    jc .L_mul_do_carry
    jmp .L_mul_no_carry
.L_mul_carry_p1:
    sub eax, 64
    mov ecx, eax
    mov rax, [rsp+136]
    bt rax, rcx
    jc .L_mul_do_carry
    jmp .L_mul_no_carry
.L_mul_carry_p0:
    mov ecx, eax
    mov rax, [rsp+128]
    bt rax, rcx
    jc .L_mul_do_carry
    jmp .L_mul_no_carry

.L_mul_do_carry:
    // 256-bit shift right 1 with sticky
    mov rax, [rsp+128]        // p0
    mov rcx, [rsp+136]        // p1
    mov rdx, [rsp+144]        // p2
    mov r8, [rsp+152]         // p3
    // lost = p0 & 1
    mov r9d, eax
    and r9d, 1
    shrd rax, rcx, 1          // p0' = (p0>>1) | (p1<<63)
    shrd rcx, rdx, 1          // p1' = (p1>>1) | (p2<<63)
    shrd rdx, r8, 1           // p2' = (p2>>1) | (p3<<63)
    shr r8, 1                 // p3' = p3>>1
    test r9d, r9d
    jz .L_mul_carry_store
    or rax, 1                 // sticky from lost bit
.L_mul_carry_store:
    mov [rsp+128], rax
    mov [rsp+136], rcx
    mov [rsp+144], rdx
    mov [rsp+152], r8
    inc dword ptr [rsp+88]    // result_exp++

.L_mul_no_carry:
    // ---- 提取 mant = product >> (p+3), 低 128 位 ----
    // low_width = p+3
    mov r11d, r12d
    add r11d, 3               // low_width = p+3
    cmp r11, 64
    jae .L_mul_extract_ge64

    // ---- low_width < 64 (f8/f16/f32/f64) ----
    // sticky = (p0 & ((1<<low_width)-1)) != 0
    mov rax, 1
    mov rcx, r11              // low_width
    shl rax, cl
    dec rax                   // mask = (1<<low_width)-1
    mov rdx, [rsp+128]        // p0
    and rax, rdx              // lost bits
    xor r10d, r10d            // sticky = 0
    test rax, rax
    jz .L_mul_ex_lt64_no_sticky
    inc r10d                  // sticky = 1
.L_mul_ex_lt64_no_sticky:
    // mant_lo = shrd(p0, p1, low_width)
    // mant_hi = shrd(p1, p2, low_width)
    mov rax, [rsp+128]        // p0
    mov rdx, [rsp+136]        // p1
    mov r8, [rsp+144]         // p2
    mov rcx, r11              // low_width → cl
    shrd rax, rdx, cl         // mant_lo
    shrd rdx, r8, cl          // mant_hi
    test r10d, r10d
    jz .L_mul_ex_lt64_done
    or rax, 1                 // OR sticky into bit 0
.L_mul_ex_lt64_done:
    mov rbp, rax              // mant_lo
    mov rbx, rdx              // mant_hi
    jmp .L_mul_compose

.L_mul_extract_ge64:
    // ---- low_width >= 64 (f128: low_width=115, s=51) ----
    sub r11, 64               // s = low_width - 64
    // sticky = (p0 != 0) || (p1 & ((1<<s)-1) != 0)
    mov rax, [rsp+128]        // p0
    test rax, rax
    jnz .L_mul_ex_ge64_sticky
    mov rax, 1
    mov rcx, r11              // s
    shl rax, cl
    dec rax                   // mask = (1<<s)-1
    mov rdx, [rsp+136]        // p1
    and rax, rdx
    test rax, rax
    jz .L_mul_ex_ge64_no_sticky
.L_mul_ex_ge64_sticky:
    mov r10d, 1
    jmp .L_mul_ex_ge64_do
.L_mul_ex_ge64_no_sticky:
    xor r10d, r10d
.L_mul_ex_ge64_do:
    // mant_lo = shrd(p1, p2, s)
    // mant_hi = shrd(p2, p3, s)
    mov rax, [rsp+136]        // p1
    mov rdx, [rsp+144]        // p2
    mov r8, [rsp+152]         // p3
    mov rcx, r11              // s → cl
    shrd rax, rdx, cl         // mant_lo
    shrd rdx, r8, cl          // mant_hi
    test r10d, r10d
    jz .L_mul_ex_ge64_done
    or rax, 1
.L_mul_ex_ge64_done:
    mov rbp, rax              // mant_lo
    mov rbx, rdx              // mant_hi

.L_mul_compose:
    // rbx:rbp = mantissa (hi:lo), r8d = result_exp, r9d = result_sign, rdi = out
    mov r8d, [rsp+88]         // result_exp
    mov r9d, [rsp+24]         // result_sign
    mov rdi, [rsp+0]          // out
    call glue_float_compose
    jmp .L_mul_cleanup

.L_mul_ret_nan:
    mov eax, 1
    jmp .L_mul_cleanup
.L_mul_ret_inf:
    mov r9d, [rsp+24]         // sign_a
    xor r9d, [rsp+56]         // result_sign = sign_a ^ sign_b
    mov r10d, r14d            // stored_exp = max_exp
    xor rbx, rbx
    xor rbp, rbp
    mov rdi, [rsp+0]
    call glue_float_pack
    mov eax, 2
    jmp .L_mul_cleanup
.L_mul_ret_zero:
    mov r9d, [rsp+24]         // result_sign
    mov rdi, [rsp+0]
    call glue_float_store_zero
    xor eax, eax
.L_mul_cleanup:
    add rsp, 0xA8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

// ============================================================
// u8 glue_div_float([*]u8 out, [*]const u8 a, [*]const u8 b, u8 len)
// 256÷128 位长除法，IEEE 754 位运算实现。
// 栈布局 (sub rsp, 0xA8 = 168):
//   [rsp+0]=out, [rsp+8]=a, [rsp+16]=b,
//   [rsp+24]=sign_a, [rsp+32]=exp_a_field→exp_a(unbiased),
//   [rsp+40]=mant_a_hi, [rsp+48]=mant_a_lo,
//   [rsp+56]=sign_b, [rsp+64]=exp_b_field,
//   [rsp+72]=mant_b_hi, [rsp+80]=mant_b_lo,
//   [rsp+88]=result_exp,
//   [rsp+96]=saved_p, [rsp+104]=saved_bias, [rsp+112]=saved_max_exp, [rsp+120]=saved_nbytes,
//   [rsp+128]=dh_hi, [rsp+136]=dh_lo, [rsp+144]=dl_hi, [rsp+152]=dl_lo
// ============================================================
.globl glue_div_float
glue_div_float:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 0xA8
    mov [rsp+0], A1
    mov [rsp+8], A2
    mov [rsp+16], A3
    movzx r10d, A4B
    call glue_float_load_params

    // unpack a
    mov rsi, [rsp+8]
    call glue_float_unpack
    mov [rsp+24], r9          // sign_a
    mov [rsp+32], r8          // exp_a_field
    mov [rsp+40], rbx         // mant_a_hi
    mov [rsp+48], rbp         // mant_a_lo
    // unpack b
    mov rsi, [rsp+16]
    call glue_float_unpack
    mov [rsp+56], r9          // sign_b
    mov [rsp+64], r8          // exp_b_field
    mov [rsp+72], rbx         // mant_b_hi
    mov [rsp+80], rbp         // mant_b_lo

    // ---- 特殊值检查 ----
    // a 是 NaN/Inf? (exp_a == max_exp)
    mov eax, [rsp+32]
    cmp eax, r14d
    jne .L_div_a_not_special
    mov rax, [rsp+40]
    or rax, [rsp+48]
    jnz .L_div_ret_nan        // a NaN
    // a Inf
    mov eax, [rsp+64]
    cmp eax, r14d
    jne .L_div_a_inf_b_finite
    // b 也 special
    mov rax, [rsp+72]
    or rax, [rsp+80]
    jnz .L_div_ret_nan        // b NaN
    jmp .L_div_ret_nan        // Inf/Inf = NaN
.L_div_a_inf_b_finite:
    // a Inf, b 有限 → Inf
    jmp .L_div_ret_inf

.L_div_a_not_special:
    mov eax, [rsp+64]
    cmp eax, r14d
    jne .L_div_check_zero
    // b special (a 有限)
    mov rax, [rsp+72]
    or rax, [rsp+80]
    jnz .L_div_ret_nan        // b NaN
    // b Inf, a 有限 → 0
    jmp .L_div_ret_zero

.L_div_check_zero:
    // a zero? (exp_a==0 AND mant_a==0)
    mov eax, [rsp+32]
    test eax, eax
    jnz .L_div_b_zero_check
    mov rax, [rsp+40]
    or rax, [rsp+48]
    jnz .L_div_b_zero_check
    // a is zero — b 也是零? (exp_b==0 AND mant_b==0)
    mov eax, [rsp+64]
    test eax, eax
    jnz .L_div_ret_zero       // b 正规 → 0/finite = 0
    mov rax, [rsp+72]
    or rax, [rsp+80]
    jz .L_div_ret_nan         // b 零 → 0/0 = NaN
    jmp .L_div_ret_zero       // b 次正规非零 → 0/subnormal = 0
.L_div_b_zero_check:
    // a nonzero, check b zero
    mov eax, [rsp+64]
    test eax, eax
    jnz .L_div_decompose
    mov rax, [rsp+72]
    or rax, [rsp+80]
    jz .L_div_ret_inf         // finite/0 = Inf
    // b subnormal nonzero → normal path
    jmp .L_div_decompose

.L_div_decompose:
    // ---- decompose a ----
    mov rbx, [rsp+40]
    mov rbp, [rsp+48]
    mov eax, [rsp+32]
    test eax, eax
    jz .L_div_da_sub
    cmp r12, 64
    jae .L_div_da_norm_128
    mov rax, 1
    mov ecx, r12d
    shl rax, cl
    or rbp, rax
    jmp .L_div_da_have_m
.L_div_da_norm_128:
    mov ecx, r12d
    sub ecx, 64
    mov rax, 1
    shl rax, cl
    or rbx, rax
    jmp .L_div_da_have_m
.L_div_da_sub:
    mov r8d, 1
    sub r8d, r13d
    jmp .L_div_da_after_exp
.L_div_da_have_m:
    mov r8d, [rsp+32]
    sub r8d, r13d
.L_div_da_after_exp:
    shld rbx, rbp, 3
    shl rbp, 3
    call glue_float_normalize
    mov [rsp+32], r8          // exp_a (unbiased)
    mov [rsp+40], rbx         // mant_a_hi
    mov [rsp+48], rbp         // mant_a_lo

    // ---- decompose b ----
    mov rbx, [rsp+72]
    mov rbp, [rsp+80]
    mov eax, [rsp+64]
    test eax, eax
    jz .L_div_db_sub
    cmp r12, 64
    jae .L_div_db_norm_128
    mov rax, 1
    mov ecx, r12d
    shl rax, cl
    or rbp, rax
    jmp .L_div_db_have_m
.L_div_db_norm_128:
    mov ecx, r12d
    sub ecx, 64
    mov rax, 1
    shl rax, cl
    or rbx, rax
    jmp .L_div_db_have_m
.L_div_db_sub:
    mov r8d, 1
    sub r8d, r13d
    jmp .L_div_db_after_exp
.L_div_db_have_m:
    mov r8d, [rsp+64]
    sub r8d, r13d
.L_div_db_after_exp:
    shld rbx, rbp, 3
    shl rbp, 3
    call glue_float_normalize
    // r8d = exp_b (unbiased), rbx:rbp = mant_b (normalized)
    // result_exp = exp_a - exp_b
    mov eax, [rsp+32]
    sub eax, r8d
    mov [rsp+88], eax         // result_exp

    // ---- 保存参数 ----
    mov [rsp+96], r12         // p
    mov [rsp+104], r13        // bias
    mov [rsp+112], r14        // max_exp
    mov [rsp+120], r15        // nbytes

    // ---- 构建 256 位被除数 = mant_a << (p+3) ----
    // mant_a: [rsp+40]=hi, [rsp+48]=lo
    mov ecx, r12d
    add ecx, 3                // shift = p+3
    mov rax, [rsp+48]         // mant_lo
    mov rdx, [rsp+40]         // mant_hi
    cmp ecx, 64
    jae .L_div_shift_ge64
    // ---- shift < 64 (f8/f16/f32/f64) ----
    mov r8d, 64
    sub r8d, ecx              // r8d = 64-shift
    // dl_lo = lo << shift
    mov r9, rax
    shl r9, cl
    mov [rsp+152], r9
    // dl_hi = (hi << shift) | (lo >> (64-shift))
    mov r9, rdx
    shl r9, cl
    mov rcx, r8               // 64-shift
    shr rax, cl
    or r9, rax
    mov [rsp+144], r9
    // dh_lo = hi >> (64-shift)
    shr rdx, cl
    mov [rsp+136], rdx
    // dh_hi = 0
    xor r9, r9
    mov [rsp+128], r9
    jmp .L_div_shift_done
.L_div_shift_ge64:
    // ---- shift >= 64 (f128: shift=115, s=51) ----
    sub ecx, 64               // s = shift-64
    mov r8d, 64
    sub r8d, ecx              // r8d = 64-s
    // dl_lo = 0
    xor r9, r9
    mov [rsp+152], r9
    // dl_hi = lo << s
    mov r9, rax
    shl r9, cl
    mov [rsp+144], r9
    // dh_lo = (hi << s) | (lo >> (64-s))
    mov r9, rdx
    shl r9, cl
    mov rcx, r8               // 64-s
    shr rax, cl
    or r9, rax
    mov [rsp+136], r9
    // dh_hi = hi >> (64-s)
    shr rdx, cl
    mov [rsp+128], rdx
.L_div_shift_done:

    // ---- 设置除法循环寄存器 ----
    // 除数 = mant_b (rbx:rbp → r10:r11)
    mov r10, rbx              // divisor_hi
    mov r11, rbp              // divisor_lo
    // 余数 = 0
    xor r8, r8
    xor r9, r9
    // 商 = 0
    xor rbx, rbx
    xor rbp, rbp
    // 计数器 = 256
    mov ecx, 256

    // ---- 256 次迭代 shift-subtract 长除法 ----
.L_div_loop:
    // 1. 256 位被除数左移 1, CF = MSB
    shl qword ptr [rsp+152], 1
    rcl qword ptr [rsp+144], 1
    rcl qword ptr [rsp+136], 1
    rcl qword ptr [rsp+128], 1
    // CF = bit

    // 2. 128 位余数左移 1, 插入 bit, CF = rem_carry
    rcl r9, 1
    rcl r8, 1
    // CF = rem_carry

    // 3. 保存 rem_carry 到 al
    setc al

    // 4. 商左移 1
    add rbp, rbp
    adc rbx, rbx

    // 5. 若 rem_carry 或 rem >= divisor: 减, 置商位
    test al, al
    jnz .L_div_sub
    cmp r8, r10
    ja .L_div_sub
    jb .L_div_nosub
    cmp r9, r11
    jb .L_div_nosub
.L_div_sub:
    sub r9, r11
    sbb r8, r10
    or rbp, 1                 // 置商 LSB
.L_div_nosub:
    dec ecx
    jnz .L_div_loop

    // ---- 恢复参数 ----
    mov r12, [rsp+96]         // p
    mov r13, [rsp+104]        // bias
    mov r14, [rsp+112]        // max_exp
    mov r15, [rsp+120]        // nbytes

    // ---- 保存余数非零标志 (sticky) ----
    mov rax, r8
    or rax, r9
    setnz al                  // al = (remainder != 0) ? 1 : 0

    // ---- 检查商 < implicit (1 << (p+3)) ----
    mov ecx, r12d
    add ecx, 3                // p+3
    cmp ecx, 64
    jae .L_div_qimpl_hi
    // p+3 < 64: implicit 在 rbp
    mov rdx, 1
    shl rdx, cl               // implicit_bit
    test rbx, rbx
    jnz .L_div_qnorm_done     // quot_hi != 0 → >= implicit
    cmp rbp, rdx
    jae .L_div_qnorm_done     // >= implicit
    jmp .L_div_qshift
.L_div_qimpl_hi:
    // p+3 >= 64: implicit 在 rbx
    sub ecx, 64
    mov rdx, 1
    shl rdx, cl
    cmp rbx, rdx
    jae .L_div_qnorm_done
.L_div_qshift:
    // 商 < implicit: 左移 1, result_exp--
    add rbp, rbp
    adc rbx, rbx
    dec dword ptr [rsp+88]
.L_div_qnorm_done:
    // ---- sticky: 余数非 0 → 置商 bit 0 ----
    test al, al
    jz .L_div_sticky_done
    or rbp, 1
.L_div_sticky_done:
    // ---- 调用 compose ----
    mov r8d, [rsp+88]         // result_exp
    mov r9d, [rsp+24]         // sign_a
    xor r9d, [rsp+56]         // result_sign
    mov rdi, [rsp+0]          // out
    // rbx:rbp = mantissa
    call glue_float_compose
    jmp .L_div_cleanup

.L_div_ret_nan:
    mov eax, 1
    jmp .L_div_cleanup
.L_div_ret_inf:
    mov r9d, [rsp+24]
    xor r9d, [rsp+56]         // result_sign
    mov r10d, r14d            // stored_exp = max_exp
    xor rbx, rbx
    xor rbp, rbp
    mov rdi, [rsp+0]
    call glue_float_pack
    mov eax, 2
    jmp .L_div_cleanup
.L_div_ret_zero:
    mov r9d, [rsp+24]
    xor r9d, [rsp+56]         // result_sign
    mov rdi, [rsp+0]
    call glue_float_store_zero
    xor eax, eax
.L_div_cleanup:
    add rsp, 0xA8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

// ============================================================
// glue_cmp_float
// 输入: A1=a_ptr, A2=b_ptr, A3=len
// 输出: eax = -1 (a<b), 0 (a==b), 1 (a>b)
// 语义: IEEE 754 totalOrder
//   -NaN < -Inf < ... < -0 < +0 < ... < +Inf < +NaN
//   同号 NaN: 负号在前；同号按尾数（quiet > signaling 简化为尾数大小）
// 栈布局 (sub rsp,0x58 = 88 字节; 6 push+ret=56, 56+88=144≡0 mod 16):
//   [rsp+0]=a_ptr  [rsp+8]=b_ptr
//   [rsp+16]=sign_a [rsp+24]=exp_a [rsp+32]=mant_a_hi [rsp+40]=mant_a_lo
//   [rsp+48]=sign_b [rsp+56]=exp_b [rsp+64]=mant_b_hi [rsp+72]=mant_b_lo
// ============================================================
.globl glue_cmp_float
glue_cmp_float:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 0x58

    // 保存输入指针
    mov [rsp+0], A1
    mov [rsp+8], A2

    // 加载参数 (3 参数函数: A1=a, A2=b, A3=len)
    // 用 movzx 单字节加载确保高位清零 (Windows ABI 不保证 u8 参数高位为 0)
    movzx r10d, A3B
    call glue_float_load_params  // r12=p, r13=bias, r14=max_exp, r15=nbytes

    // 解包 a
    mov rsi, [rsp+0]
    call glue_float_unpack       // 输出: r9d=sign, r8d=exp, rbx:rbp=mantissa
    mov [rsp+16], r9             // sign_a
    mov [rsp+24], r8             // exp_a
    mov [rsp+32], rbx            // mant_a_hi
    mov [rsp+40], rbp            // mant_a_lo

    // 解包 b
    mov rsi, [rsp+8]
    call glue_float_unpack
    mov [rsp+48], r9             // sign_b
    mov [rsp+56], r8             // exp_b
    mov [rsp+64], rbx            // mant_b_hi
    mov [rsp+72], rbp            // mant_b_lo

    // NaN 检查: a_nan = (exp_a==max_exp && mant_a!=0)
    xor r10d, r10d               // r10d = a_nan = 0
    mov eax, [rsp+24]            // exp_a
    cmp eax, r14d
    jne .L_cmp_a_not_nan
    mov rax, [rsp+32]
    or rax, [rsp+40]
    jz .L_cmp_a_not_nan
    mov r10d, 1                  // a_nan = 1
.L_cmp_a_not_nan:
    // b_nan = (exp_b==max_exp && mant_b!=0)
    xor r11d, r11d               // r11d = b_nan = 0
    mov eax, [rsp+56]            // exp_b
    cmp eax, r14d
    jne .L_cmp_b_not_nan
    mov rax, [rsp+64]
    or rax, [rsp+72]
    jz .L_cmp_b_not_nan
    mov r11d, 1                  // b_nan = 1
.L_cmp_b_not_nan:
    // 分派
    test r10d, r10d
    jnz .L_cmp_a_nan
    test r11d, r11d
    jnz .L_cmp_b_nan_only
    jmp .L_cmp_not_nan

.L_cmp_a_nan:
    test r11d, r11d
    jnz .L_cmp_both_nan
    // 仅 a 为 NaN: nan_sign = sign_a
    mov eax, [rsp+16]
    test eax, eax
    jnz .L_cmp_ret_neg1          // -NaN 最小
    jmp .L_cmp_ret_pos1          // +NaN 最大

.L_cmp_b_nan_only:
    // 仅 b 为 NaN: nan_sign = sign_b
    mov eax, [rsp+48]
    test eax, eax
    jnz .L_cmp_ret_pos1          // b 是 -NaN → a 更大
    jmp .L_cmp_ret_neg1          // b 是 +NaN → a 更小

.L_cmp_both_nan:
    // 同为 NaN: 符号不同则 sign=1 更小
    mov eax, [rsp+16]            // sign_a
    mov ecx, [rsp+48]            // sign_b
    cmp eax, ecx
    je .L_cmp_nan_same_sign
    test eax, eax
    jnz .L_cmp_ret_neg1
    jmp .L_cmp_ret_pos1
.L_cmp_nan_same_sign:
    // 同号 NaN: 按尾数比较 (hi 先比)
    mov rax, [rsp+32]            // mant_a_hi
    mov rcx, [rsp+64]            // mant_b_hi
    cmp rax, rcx
    jb .L_cmp_ret_neg1
    ja .L_cmp_ret_pos1
    mov rax, [rsp+40]            // mant_a_lo
    mov rcx, [rsp+72]            // mant_b_lo
    cmp rax, rcx
    jb .L_cmp_ret_neg1
    ja .L_cmp_ret_pos1
    jmp .L_cmp_ret_zero

.L_cmp_not_nan:
    // 双零检查: (exp_a==0 && mant_a==0) && (exp_b==0 && mant_b==0)
    mov eax, [rsp+24]            // exp_a
    test eax, eax
    jnz .L_cmp_sign_check
    mov rax, [rsp+32]
    or rax, [rsp+40]
    jnz .L_cmp_sign_check
    mov eax, [rsp+56]            // exp_b
    test eax, eax
    jnz .L_cmp_sign_check
    mov rax, [rsp+64]
    or rax, [rsp+72]
    jnz .L_cmp_sign_check
    jmp .L_cmp_ret_zero          // 双零 → eq

.L_cmp_sign_check:
    // 符号不同: sign=1 (负) 更小
    mov eax, [rsp+16]            // sign_a
    mov ecx, [rsp+48]            // sign_b
    cmp eax, ecx
    je .L_cmp_same_sign
    test eax, eax
    jnz .L_cmp_ret_neg1          // a 负 b 正 → a < b
    jmp .L_cmp_ret_pos1          // a 正 b 负 → a > b

.L_cmp_same_sign:
    // 同号非 NaN: 字节变换后无符号比较
    // 正数: 翻转符号位 (BTS 设 1); 负数: 全部取反 (NOT)
    // 加载原始字节到 rdx:rax (a) / r9:r8 (b)
    cmp r15, 16
    je .L_cmp_load_128
    cmp r15, 8
    je .L_cmp_load_64
    cmp r15, 4
    je .L_cmp_load_32
    cmp r15, 2
    je .L_cmp_load_16
    // len=1
    mov r10, [rsp+0]
    mov r11, [rsp+8]
    movzx rax, byte ptr [r10]
    movzx r8, byte ptr [r11]
    jmp .L_cmp_transform
.L_cmp_load_16:
    mov r10, [rsp+0]
    mov r11, [rsp+8]
    movzx rax, word ptr [r10]
    movzx r8, word ptr [r11]
    jmp .L_cmp_transform
.L_cmp_load_32:
    mov r10, [rsp+0]
    mov r11, [rsp+8]
    mov eax, dword ptr [r10]
    mov r8d, dword ptr [r11]
    jmp .L_cmp_transform
.L_cmp_load_64:
    mov r10, [rsp+0]
    mov r11, [rsp+8]
    mov rax, qword ptr [r10]
    mov r8, qword ptr [r11]
    jmp .L_cmp_transform
.L_cmp_load_128:
    mov r10, [rsp+0]
    mov r11, [rsp+8]
    mov rax, qword ptr [r10]     // a_lo
    mov rdx, qword ptr [r10+8]   // a_hi
    mov r8, qword ptr [r11]      // b_lo
    mov r9, qword ptr [r11+8]    // b_hi

.L_cmp_transform:
    mov ecx, [rsp+16]            // sign (sign_a == sign_b)
    test ecx, ecx
    jnz .L_cmp_negative

    // 正数: BTS 符号位 (MSB)
    cmp r15, 16
    je .L_cmp_pos_128
    mov ecx, r15d
    shl ecx, 3
    dec ecx                      // ecx = nbytes*8-1
    bts rax, rcx
    bts r8, rcx
    jmp .L_cmp_do_compare
.L_cmp_pos_128:
    bts rdx, 63
    bts r9, 63
    jmp .L_cmp_do_compare

.L_cmp_negative:
    // 负数: NOT 全部位
    cmp r15, 16
    je .L_cmp_neg_128
    not rax
    not r8
    jmp .L_cmp_do_compare
.L_cmp_neg_128:
    not rax
    not rdx
    not r8
    not r9

.L_cmp_do_compare:
    cmp r15, 16
    je .L_cmp_cmp_128
    // ≤64 位: 直接比 rax vs r8
    cmp rax, r8
    jb .L_cmp_ret_neg1
    ja .L_cmp_ret_pos1
    jmp .L_cmp_ret_zero
.L_cmp_cmp_128:
    // 128 位: hi 先比, lo 后比
    cmp rdx, r9
    jb .L_cmp_ret_neg1
    ja .L_cmp_ret_pos1
    cmp rax, r8
    jb .L_cmp_ret_neg1
    ja .L_cmp_ret_pos1
    jmp .L_cmp_ret_zero

.L_cmp_ret_neg1:
    mov eax, -1
    jmp .L_cmp_cleanup
.L_cmp_ret_zero:
    xor eax, eax
    jmp .L_cmp_cleanup
.L_cmp_ret_pos1:
    mov eax, 1
.L_cmp_cleanup:
    add rsp, 0x58
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

// Unix: 标记栈段不可执行 (避免 executable stack 警告)
#ifndef _WIN32
.section .note.GNU-stack,"",@progbits
#endif
