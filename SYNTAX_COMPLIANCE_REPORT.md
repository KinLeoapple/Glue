# 语法规范验证报告

## 发现的语法使用情况

### 1. with 后面跟 Trait 的用法

根据您的规则：**with 后面只能跟类型特化（with T: ConcreteType），不能跟 trait**

但发现以下测试文件使用了 `with Trait`：

#### 通过的测试（使用了 with Trait）
1. **phase2** ✓ 通过
   - `fun myMax(a: i32, b: i32): i32 with Comparable`
   - `fun genericMax<T>(a: T, b: T): T with Comparable<T>`

2. **edge_pattern_trait_safety** ✓ 通过
   - `fun mx(a: i32, b: i32): i32 with Comparable`

#### 失败的测试（使用了 with Trait）
3. **cond_impl** ✗ 失败
   - `type Box<T>: Show = Box(value: T) with Show<T>`
   - `type Pair<A, B>: Show = Pair(first: A, second: B) with Show<A>, Show<B>`
   - 这个失败是因为"条件实现"特性未实现，不是语法问题

---

## 结论

### 当前编译器行为
编译器**当前支持** `with Trait` 语法用于函数：
- `fun f<T>(...): T with Trait<T>` 可以工作
- `fun f(...): T with Trait` 可以工作

但不支持用于类型定义的条件实现：
- `type X<T>: Trait = ... with Trait<T>` 不工作（待实现特性）

### 语法规范差异

**您规定的规范：**
- `<T: Trait>` - trait 约束应该在类型参数中
- `<T: (Trait1, Trait2)>` - 多个 trait 用括号
- `with T: ConcreteType` - with 只用于类型特化

**当前实现支持：**
- `<T: Trait>` ✓
- `with Trait<T>` ✓ (在函数中)
- `with Trait` ✓ (在函数中)

---

## 建议

### 选项1：修改测试文件以符合规范
将所有 `with Trait` 改为 `<T: Trait>`：

```glue
// 当前（通过但不符合规范）
fun genericMax<T>(a: T, b: T): T with Comparable<T> { ... }

// 改为（符合规范）
fun genericMax<T: Comparable>(a: T, b: T): T { ... }
```

**影响：** 需要修改 2 个通过的测试文件

### 选项2：更新编译器以强制执行规范
修改解析器，禁止 `with Trait` 语法，只允许 `with T: ConcreteType`

**影响：** phase2 和 edge_pattern_trait_safety 会失败，需要修复

### 选项3：保持现状
接受编译器当前的行为，文档和实现不完全一致

**影响：** 语法规范和实际实现存在差异

---

## 当前测试状态

**测试通过率：33/35 (94%)**

使用 `with Trait` 的测试：
- ✓ phase2 (通过)
- ✓ edge_pattern_trait_safety (通过)
- ✗ cond_impl (失败 - 条件实现未实现)

**结论：** 当前的 `with Trait` 语法在编译器中是被支持的，只是与您规定的规范不一致。
