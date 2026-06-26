# 移除 impl 语法 - 待完成任务

## 当前状态

### 已完成
- ✅ AST 中标记 `impl_decl` 为 `[DEPRECATED]` (src/ast.zig:966)
- ✅ 语法速查表已移除 `impl` 语法 (docs/syntax-cheatsheet.md)
- ✅ 确认 `fun modify(data: var i32)` 语法已实现

### 待移除的代码

#### 1. 解析器代码
- `src/parser.zig:1036` - `parseImplDecl` 函数
- `src/parser.zig:370` - 调用点
- `src/parser.zig:449` - 调用点

#### 2. AST 定义
- `src/ast.zig:966-984` - `impl_decl` 定义

#### 3. 测试文件（需要重写）
- `tests/phase2/src/Main.glue` - 14 个 impl 使用
- `tests/edge_pattern_trait_safety/src/Main.glue` - 2 个 impl 使用
- `tests/phase5.deprecated/` - 已废弃，可忽略

## 核心问题

**如何为内置类型（i32, f64 等）实现 trait？**

当前用法：
```glue
trait Comparable { fun compare(a, b): Ord }
impl Comparable<i32> {
    fun compare(a, b): Ord { ... }
}
```

可能的替代方案：
1. **type alias with trait?**
   ```glue
   type I32: Comparable = i32 with ... ?
   ```

2. **全局 trait 函数?**
   ```glue
   fun compare(a: i32, b: i32): Ord { ... }
   ```

3. **其他机制?**

## 建议的实施步骤

1. **确定替代方案** - 如何为内置类型实现 trait
2. **重写测试文件** - 用新语法替换 impl
3. **移除解析器代码** - 删除 parseImplDecl 等
4. **移除 AST 定义** - 删除 impl_decl
5. **验证所有测试** - 确保 35/35 仍然通过

## 等待决策

请确认：
- 为内置类型实现 trait 的正确替代语法是什么？
- 是否立即开始移除，还是先确定替代方案？
