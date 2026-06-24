# Glue 语法更新进度

## 目标
将 Glue 语言从 `impl` 分离语法迁移到在 `type` 定义时实现 trait 的新语法。

## 已完成

### ✅ 任务1：更新 AST 定义
- [x] 添加 `TypeConstraint` 类型（用于 `with T: ConcreteType` 语法）
- [x] 修改 `type_decl` 结构，添加：
  - `implemented_traits: []TraitBound` - 实现的 trait 列表
  - `type_constraints: []TypeConstraint` - 类型特化约束
  - `methods: []MethodDecl` - 方法实现块
- [x] 添加 `self_type` 到 `TypeNode`（支持 `Self` 类型）
- [x] 将 `use_decl` 重命名为 `import_decl`
- [x] 将 `UseItem` 重命名为 `ImportItem`
- [x] 标记 `impl_decl` 为 DEPRECATED（保留以便报错）
- [x] 修复所有文件中的引用：
  - parser.zig
  - eval/eval.zig
  - main.zig
  - sema/resolve.zig
  - sema/type_check.zig
  - sema/kind_check.zig

### ✅ 任务2：更新 Parser
- [x] 修改 `parseTypeDecl` 支持新语法：
  ```
  type Name<T>: Trait1, Trait2 = Definition with T: ConcreteType {
      fun method1(self) { ... }
      fun method2(self) { ... }
  }
  ```
- [x] 实现 `parseTypeConstraints` - 解析 `with` 约束
- [x] 实现 `parseTypeConstraint` - 解析单个类型约束
- [x] 实现 `parseMethodBlock` - 解析方法块
- [x] 复用现有的 `parseMethodDecl` - 解析单个方法
- [x] 修复所有编译错误

### ✅ 任务3：更新类型检查
- [x] 实现 `Self` 类型的正确解析和检查
  - 添加 `current_self_type` 字段到 TypeInferencer
  - 在 type 方法检查时设置 current_self_type
  - 在 trait 方法检查时创建 Self 类型变量
- [x] 支持类型特化约束的验证（框架已就绪）
- [x] 添加 type 方法的类型检查逻辑
- [x] 确保方法参数和返回类型正确处理

### ✅ 任务4：更新 trait 解析
- [x] 创建 `checkTypeTraitImplementations` 函数
- [x] 实现 Orphan 实例检查
- [x] 实现 Overlapping 实例检查
- [x] 验证所有 trait 方法都已实现
- [x] 将 trait 方法注册到类型环境

### ✅ 任务5：更新模块系统
- [x] 将 lexer 中的 `kw_use` 改为 `kw_import`
- [x] 更新 parser 中所有 `kw_use` 引用
- [x] 编译验证通过

## 待完成

### 📋 任务6：更新测试文件
- [ ] 修改所有测试文件使用新语法
- [ ] 将 `impl` 改为在 `type` 中实现
- [ ] 将 `use` 改为 `import`
- [ ] 确保所有测试通过

### 📋 任务7：更新标准库
- [ ] 修改标准库代码使用新语法
- [ ] 更新所有类型定义

### 📋 任务8：去除 tree walker
- [ ] 移除 `src/eval/` 目录
- [ ] 清理 main.zig 中的 tree walker 相关代码
- [ ] 确保只保留 VM 实现
- [ ] 更新构建配置

## 新语法示例

### 旧语法（已废弃）
```glue
type Point = (x: f64, y: f64)

impl Show<Point> {
    fun show(self): str = "(${self.x}, ${self.y})"
}
```

### 新语法
```glue
type Point: Show = (x: f64, y: f64) {
    fun show(self): str = "(${self.x}, ${self.y})"
}
```

### 带类型约束
```glue
type Container<T>: Show = (value: T) with T: Show {
    fun show(self): str = "Container(${self.value.show()})"
}
```

### Self 类型
```glue
type Builder: Buildable = (state: State) {
    fun with_value(self, v: i32): Self = Builder((state: self.state.add(v)))
}
```

## 技术细节

### AST 变化
- `Decl.type_decl` 现在包含 trait 实现和方法
- `Decl.impl_decl` 标记为 DEPRECATED
- `TypeNode` 新增 `self_type` 变体
- 新增 `TypeConstraint` 结构

### Parser 变化
- `parseTypeDecl` 现在解析更复杂的语法
- 新增辅助函数处理约束和方法块
- 保持向后兼容（`impl` 会报错提示迁移）

### 类型检查变化（待实现）
- 需要在类型定义时进行 trait 实现检查
- `Self` 类型需要在方法上下文中解析为当前类型
- 类型约束需要在实例化时验证

## 编译状态
✅ 当前编译通过（Zig 0.16.0）

## 下一步
1. 实现 Self 类型的完整支持（任务3）
2. 迁移 trait 解析逻辑（任务4）
3. 开始更新测试文件（任务6）
