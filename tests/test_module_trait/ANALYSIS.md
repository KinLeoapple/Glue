# test_module_trait 失败原因分析

## 问题
测试 `test_module_trait` 失败，错误为 `FileNotFound`

## 根本原因
**模块加载器尚未实现文件系统模块加载**

### 代码证据
`src/loader/module_loader.zig:167-184`
```zig
// 文件系统加载：TODO - 需要实现跨平台的文件打开
// 当前暂时禁用，只支持 stdlib

// 回退到 stdlib 查找
if (module_path.len == 1) {
    if (stdlib.lookup(module_path[0])) |source| {
        // ... 加载 stdlib 模块
        return;
    }
}

return error.FileNotFound;  // 所有非 stdlib 模块都失败
```

## 测试内容
`test_module_trait` 尝试加载用户定义的模块：
```glue
import Store  // 文件系统模块，位于 src/Store/

trait KVStore { ... }
fun run(s: KVStore) { ... }
fun main() {
    run(Store.Memory)  // 文件模块作为 Trait 值
}
```

## 当前支持的模块
**只支持内嵌的 stdlib 模块：**
- Compare (Eq, Ord, Show traits)
- List (函数式链表) - 注：使用条件实现语法，目前也不可用

## 未实现的功能
1. 从文件系统加载用户模块
2. 解析 `src/ModuleName/pack.glue`
3. 支持模块嵌套（`Store.Memory`）

## 结论
这不是一个bug，而是一个**待实现的特性**。

## 工作量估算
实现文件系统模块加载需要：
1. 实现跨平台的文件读取
2. 构建模块路径解析逻辑
3. 处理 pack.glue 文件
4. 支持嵌套模块访问

**估计工作量：2-3天**

## 优先级
**中等** - 这是一个重要的特性，但当前项目可以只使用 stdlib 模块。

## 建议
1. 在文档中明确说明当前只支持 stdlib 模块
2. 将 test_module_trait 标记为 "待实现特性测试"
3. 在实现文件系统模块加载后再启用此测试
