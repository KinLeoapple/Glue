# AST 管线优化设计

## 目标

优化 lexer → parser → module_loader → sema 管线的内存分配效率与数据布局，消除 9 个已识别瓶颈。

## 当前管线数据流

```
source ([]const u8, c_allocator 持有)
  → Lexer: 产出 []Token (lexeme 零拷贝指向 source)
  → Parser: init 时 dupe 整个 []Token 到 arena; 每个节点 arena.create(T) 单独分配
  → ModuleLoader: 转移 parser arena 保活; 模块名多处 dupe
  → TypeInferencer: 通用 allocator 逐个 create/destroy *Type/*TypeVar
```

## 第 1 轮：Parser 热路径（瓶颈 1-4）

### 1.1 移除 Token 全量 dupe

**改动**: `Parser.init` 不再 `dupe([]Token)`，直接持有外部切片。删除 `owns_tokens` 字段。

**`expectCloseAngle` 处理**: 不再就地修改 token 类型。改为在 `parseTypeNode` 中用前瞻逻辑：遇到 `gt_eq` 时当作 `gt` + `eq` 两步，不修改原数组。

**文件**: parser.zig (init, expectCloseAngle, owns_tokens 删除)

### 1.2 unescapeString 快路径

**改动**: `unescapeString` 入口先扫描是否含 `\`、`{{`、`}}`。无则直接返回原 content 切片。

**文件**: parser.zig (unescapeString)

### 1.3 插值表达式简化

**改动**: 配合 1.1，嵌套 Parser.init 不再 dupe tokens。保留嵌套 Lexer+Parser 结构（Lexer 必须新建，因为插值是子串），但 dupe 开销已消除。

**文件**: parser.zig (parseInterpolationExpr)

### 1.4 AST 节点 chunk 批量分配

**改动**: 为 Expr/Stmt/TypeNode/Pattern/Kind 各维护一个 chunk 分配器：

```zig
fn NodeChunk(comptime T: type) type {
    return struct {
        const CHUNK_SIZE = 64;
        chunks: std.ArrayList([]T),
        idx: usize = 0,
        current: ?[]T = null,
        arena: std.mem.Allocator,
        fn alloc(self: *@This()) !*T { ... bump or new chunk ... }
    };
}
```

`allocExpr`/`allocStmt`/`allocType`/`allocPattern`/`allocKind` 内部改为从对应 chunk 分配。接口不变。

**文件**: parser.zig (新增 NodeChunk, Parser 结构体增加 5 个 chunk 字段, allocExpr 等改造)

## 第 2 轮：内存布局重整（瓶颈 5-7）

### 2.1 SourceLocation 提取

**改动**: 为每类节点定义 `NodeSlot(T)` 包装：

```zig
fn NodeSlot(comptime T: type) type {
    return struct { loc: SourceLocation, node: T };
}
```

`allocExpr` 返回 `*Expr`，但底层 chunk 按 `NodeSlot(Expr)` 布局，loc 存在 node 前的固定偏移。通过 `@fieldParentPtr` 从 `*Expr` 反查 `*NodeSlot(Expr)` 获取 loc。

各 union 变体中删除 `location` 字段。`exprLocation`/`stmtLocation` 等 helper 改为通过 `@fieldParentPtr` 获取。

**影响面**: ast.zig 删除所有变体的 location 字段; parser.zig 构造节点时分离 loc; 所有读取 location 的代码改用 helper。

**文件**: ast.zig, parser.zig, type_check.zig 及所有读取 location 的文件

### 2.2 已知长度列表预分配

**改动**: 在能从语法结构预估长度的场景调用 `ensureTotalCapacity`：
- `parseFunctionType`: params 数量已知
- `parseRecordDecl`: 字段数可从 `}` 前的 token 数粗估
- `parseCallArgs`: 遇到 `)` 前无法预知，跳过

**文件**: parser.zig

### 2.3 负数字面量直接拼接

**改动**: 将 `allocPrint("-{s}", .{raw})` 改为：

```zig
const neg_raw = try arena.alloc(u8, raw_len + 1);
neg_raw[0] = '-';
@memcpy(neg_raw[1..], raw);
```

**文件**: parser.zig (2 处: 整数和浮点)

## 第 3 轮：生命周期/Sema 一致化（瓶颈 8-9）

### 3.1 模块名 intern 池

**改动**: ModuleLoader 增加 `StringInterner`：

```zig
const StringInterner = struct {
    map: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    fn intern(self: *StringInterner, s: []const u8) ![]const u8 {
        if (self.map.get(s)) |existing| return existing;
        const owned = try self.allocator.dupe(u8, s);
        try self.map.put(owned, owned);
        return owned;
    }
    fn deinit(self: *StringInterner) void { ... }
};
```

ModuleLoader 中 5+ 处 `allocator.dupe(u8, name)` 改为 `interner.intern(name)`。

**文件**: module_loader.zig

### 3.2 TypeInferencer 改用 arena

**改动**: TypeInferencer 增加内部 `arena: std.heap.ArenaAllocator`（backing 为外部 allocator）。

- `*Type`/`*TypeVar` 分配: `self.allocator.create(Type)` → `self.arena.allocator().create(Type)`
- hashmap key dupe: 改为 arena 分配（无需单独 free）
- `deinit`: 简化为 `arena.deinit()` + 释放非 arena 容器元数据

**跨生命期数据处理**: `exported_schemes`/`module_member_sigs` 中的 `*Type` 若需跨 TypeInferencer 生命期保留，则这些 Type 仍从外部 allocator 分配（通过 `TypeInferencer` 的 `backing_allocator` 字段），不走 arena。具体策略：`makeType` 内部判断 Type 是否需要导出，需要导出的用 backing allocator，临时的用 arena。

**简化方案**: 所有 `*Type` 都从 arena 分配。`exported_schemes`/`module_member_sigs` 在 TypeInferencer.deinit 前由 ModuleLoader 深拷贝到外部 allocator。但这增加复杂度。

**推荐**: 所有 `*Type` 都从 arena 分配，ModuleLoader 持有 TypeInferencer 的 arena 所有权转移（类似 parser arena 转移），确保 sema 产出的 Type 与 TypeInferencer 同生命期。

**文件**: type_check.zig

## 实施顺序

1. 第 1 轮 (1.1-1.4) → 验证 `zig build && zig build test`
2. 第 2 轮 (2.1-2.3) → 验证
3. 第 3 轮 (3.1-3.2) → 验证

每轮独立验证，失败不阻塞前序已完成的轮次。

## 风险评估

| 改动 | 风险 | 缓解 |
|------|------|------|
| 1.1 移除 dupe | expectCloseAngle 逻辑变化 | 前瞻测试覆盖 |
| 1.4 chunk 分配 | chunk 内存归属 arena | chunk 内存从 arena 分配 |
| 2.1 SourceLocation 提取 | 影响面大，全管线 location 读取 | 分离 loc 不改 helper 接口 |
| 3.2 TypeInferencer arena | 跨生命期 Type 悬垂 | arena 所有权转移给 ModuleLoader |
