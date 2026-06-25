# 浮点数溢出检查与类型推断

## 概述

Glue 语言对浮点数实现了严格的溢出检查和基于精确性的类型推断，确保数值计算的安全性和精确性。

## 特性

### 1. 精确优先的类型推断

当浮点字面量**没有类型后缀**时，编译器会自动选择**能精确表示该值的最小类型**。

#### 推断规则

使用"往返检查"（round-trip check）算法：
- 尝试将 f128 值转换为更小的类型（f16/f32/f64），再转回 f128
- 如果值完全相等且不是 NaN/Inf，则使用该较小类型
- 否则继续尝试下一个更大的类型

```glue
val a = 1.5        // → f16 (可精确表示)
val b = 100.0      // → f16 (可精确表示)
val c = 100000.0   // → f32 (超出 f16 范围)
val d = 1.0e38     // → f128 (f32 精度不足)
```

### 2. 溢出检查

#### 编译时检查（字面量）

带类型后缀的字面量会在编译时检查是否超出范围：

```glue
val a = 1e100f32   // ❌ 编译错误：超出 f32 最大值 (~3.4e38)
val b = 3.5e38f32  // ❌ 编译错误：超出 f32 范围
val c = 3.4e38f32  // ✅ 合法
val d = 65505.0f16 // ❌ 编译错误：超出 f16 最大值 (65504)
```

#### 运行时检查（算术运算）

所有浮点运算结果会检查是否溢出：

```glue
val max = 3.4e38f32
val result = max * 2.0f32  // ❌ 运行时错误：arithmetic overflow
```

支持的运算：
- 加法、减法、乘法、除法、取模
- 取负运算

```glue
val a = 60000.0f16
val b = a * 1.5f16  // ❌ 运行时错误：结果 90000 超出 f16 范围
```

### 3. 类型范围

| 类型 | 位宽 | 最小值 | 最大值 |
|------|------|--------|--------|
| f16  | 16   | -65504 | 65504  |
| f32  | 32   | -3.4e38 | 3.4e38 |
| f64  | 64   | -1.8e308 | 1.8e308 |
| f128 | 128  | -1.2e4932 | 1.2e4932 |

### 4. 类型提升

混合精度运算会自动提升为较大类型：

```glue
val a = 1.5        // f16
val b = 1000.0f32  // f32
val c = a + b      // → f32 (提升到较大类型)
```

## 最佳实践

### 何时使用显式类型标注

```glue
// ✅ 需要特定精度和性能
val distance = 1.0e20f32  // 接受精度损失，使用 f32

// ✅ 明确范围要求
val tiny = 0.001f16  // 节省内存

// ✅ API 要求特定类型
fun process_f32(x: f32) { ... }
val input = 100.0f32
process_f32(input)
```

### 何时使用类型推断

```glue
// ✅ 需要精确表示
val pi = 3.141592653589793  // 自动选择足够精确的类型

// ✅ 数学常量
val e = 2.718281828459045

// ✅ 不确定精度需求
val ratio = 1.5 / 3.0  // 让编译器选择合适类型
```

## 实现细节

### API

在 `src/value.zig` 中：

```zig
pub const FloatType = enum {
    f16, f32, f64, f128,
    
    // 返回类型的最小值（负的最大值）
    pub fn minFloat(self: FloatType) f128;
    
    // 返回类型的最大值
    pub fn maxFloat(self: FloatType) f128;
    
    // 检查值是否在类型范围内（拒绝 NaN/Inf）
    pub fn inRange(self: FloatType, val: f128) bool;
};

// 推断能精确表示 val 的最小类型
pub fn inferFloatType(val: f128) FloatType;
```

### 检查点

1. **字面量解析** (`src/vm/compiler.zig`):
   - 显式类型：检查 `inRange`
   - 无类型后缀：调用 `inferFloatType`

2. **运行时算术** (`src/vm/vm.zig`):
   - 所有算术运算后检查 `inRange`
   - 包括取负运算

## 错误消息

```
// 编译时
src/Main.glue: error: compilation failed: Unsupported

// 运行时
src/Main.glue:6:22: runtime panic: arithmetic overflow: floating-point operation out of range
```

## 与整数的一致性

浮点数和整数现在有相同的溢出安全保证：

```glue
// 整数
val i = 128i8       // ❌ 编译错误：超出 i8 范围 [-128, 127]
val j = 100i8 + 50i8  // ❌ 运行时错误：溢出

// 浮点数
val f = 1e100f32    // ❌ 编译错误：超出 f32 范围
val g = 3.4e38f32 * 2.0f32  // ❌ 运行时错误：溢出
```

## 测试

完整测试位于 `tests/float_overflow_test/`，包括：
- 精确推断测试
- 编译时溢出检查
- 运行时溢出检查
- 类型提升测试
- 边界值测试
