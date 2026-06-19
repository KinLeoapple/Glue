# Glue 性能优化基线 (ReleaseFast)

测量环境: Windows 11, ReleaseFast 构建, 取多次运行最快值。
测量日期: 2026-06-19。基线 commit: 6b06c16 (master) + var 注解修复。

## 基线数字

| Benchmark | 负载 | 最快墙钟 | 单位成本估算 |
|---|---|---|---|
| fib    | fib(32),约 700 万次非尾递归调用 | **65697ms** | ~9.4µs/调用 |
| lookup | 5000×1000=500 万次内层循环,多变量跨作用域查找 | **91654ms** | ~18µs/内层迭代 |
| record | 100 万次记录构造+match+字段访问 | **25539ms** | ~25µs/轮 |

## 解读

- fib ~9.4µs/调用:确认瓶颈在每次调用的固有成本(createChild 新建 StringHashMap +
  define 时 dupe 参数名 + 变量查找沿父链 HashMap)。与记忆续12 实测 ~4.5µs 同量级
  (那次是尾递归 countDown,这里 fib 非尾递归无 TCO,每次真建帧故更慢)。
- lookup 最慢:每轮内层引用 a/b/c/d/acc/i 六个变量,每个都走 environment.get 沿父链
  StringHashMap 查找。词法地址解析(De Bruijn)应在此负载收益最大。
- record:复合值 churn 走 refcount/COW + SlabPool,单位成本最高(装箱+rc+模式匹配)。

## 优化目标顺序(对应任务 #1-4)

1. ✅ 建 benchmark + 量基线(本文件)
2. 词法地址解析(De Bruijn):evalIdentifier 从 HashMap 查找改数组索引 — lookup 收益最大
3. ✅ 名字 intern + 整数键环境:消除每次 define 的 dupe/free + 每次 lookup 的字符串哈希
4. 帧池化复用 + 小整数缓存:freelist 复用帧,小整数避免重复装箱

每层优化后重跑这三个 bench 对照,验证真实收益。

## 优化结果

### 任务 #3:名字 intern + 整数键环境(2026-06-19 完成)

变量名 intern 成 u32 id,Environment 从 StringHashMap 改 AutoHashMap(u32)。
消除每次 define 的 key dupe/free + 每次 lookup 的字符串哈希。

| Benchmark | 基线 | intern 后 | 提速 |
|---|---|---|---|
| fib    | 65697ms | **31883ms** | **2.06×** |
| lookup | 91654ms | **44137ms** | **2.08×** |
| record | 25539ms | **7475ms**  | **3.42×** |

调用/查找吞吐翻倍;record churn 3.4×(热路径无 per-define 字符串 dupe/free)。
连带修复一个既存 string 数组迭代 double-free(array_iterator next 用 retain 而非 retainOwned)。

### 任务 #4:帧池化复用(2026-06-19,负结果,已还原)

试图池化退出作用域的 Environment 帧(freelist + clearRetainingCapacity 保留 map/list 后备),
免去每次 createChild 的 AutoHashMap 后备分配+rehash。**实测零提速**(fib 31.9→32.1s、
lookup/record 持平,均在噪声内)。根因:SlabPool 已让帧 create/destroy 成 O(1) freelist,
且小帧的 AutoHashMap 首次 put 才分配单个小 slab——SlabPool 本就廉价回收,clearRetainingCapacity
省的那点被淹没。**已还原**(零收益不值得给最脆弱的 releaseEnv 加「池化活帧」的静默损坏风险面)。
教训:小整数缓存也作废(IntValue 是 union 内联值类型,整数创建不分配)。

性能下一步只剩 De Bruijn(#2,词法地址),但那是高风险大改(需扁平数组环境+闭包 upvalue 两层方案)。

### 任务 #2:De Bruijn 词法地址(2026-06-19,负结果,默认关闭/休眠)

局部变量 (depth,slot) 数组寻址替代父链哈希查找。完整实现(resolve scope 栈 + env slot 数组 +
identifier.resolved 三级引用 local/upvalue/global + 自校验回退)。**实测 lookup 44.1→43.2s(~2%,
噪声内),fib/record 持平**。根因同 #4:#3 的 intern 把 key 换成 u32 后哈希探测已近免费,De Bruijn
省的那点 + 两条路径都仍 pointer-chase 父链,收益被淹没。
**安全已解决**:getLocal 自校验 slot 的 name_id,错配/越界返回 null → 回退 map(所有构建模式,
非仅 Debug 断言),即使 resolver 有 bug 也只是走慢路径、绝不静默读错变量。
**决策**:默认关闭(use_lexical_addressing=false),休眠代码零成本(flag 关时 evalIdentifier 走 map)。
保留代码以便日后若改底层表示(消除父链 walk)再重开。

**性能优化链结论**:唯一真实收益来自 #3 名字 intern(2-3.4×)。#4 帧池化、#2 De Bruijn 均负结果
(intern 后底层已足够快)。树遍历解释器的下一个数量级需字节码 VM(另立项)。

### 续:热路径剖析 + B1 shadow_stack 短路(2026-06-19,第三个负结果)

剖析隔离实验(均 ReleaseFast):
- **P1**(全 depth-0 本块变量)42.4s vs **P2**(原 lookup,引用 depth-1)43.2s → **父链 walk 不是瓶颈(<2%)**。
- **Q1**(每轮~2 二元运算,3000万轮)122s vs **Q2**(每轮~8 个)190s → **每个二元运算 ~2.3µs**。

读码定位 2.3µs:evalBinary 每个运算做 pushRoot/popRoot(给**主路径恒 null 的 GC** 的 shadow_stack
做 ArrayList append+pop)+ 两次 release(整数 no-op 但仍 tag switch)+ 两次递归 evalExpr 分发。

**B1:pushRoot/popRoot/popRoots 在 gc==null 时短路**(主求值器 gc 恒 null;spawn 协程 gc 非 null 行为不变)。
实测三 bench **全部持平**(fib 复测 31.9s 排除噪声)。**第三个负结果**。B1 保留(正确的死代码清理,
33/33 + 并发正常,主路径不再对死 GC 做 ArrayList 操作),只是不提速。

**最终实证结论**:2.3µs/节点不在变量查找/帧分配/shadow_stack(全排除),在**树遍历本身不可削减的机制**:
每节点递归 evalExpr 调用 + ~40 分支 union-tag switch + EvalResult try 传播 + 64 字节 Value 按值拷贝。
**增量优化在 intern 后彻底到顶,下一数量级只能靠字节码 VM(AST→线性 IR→switch-threaded VM,重写求值器核心)。**





## 重跑命令

```bash
GLUE=./zig-out/bin/glue.exe
zig build -Doptimize=ReleaseFast
for b in fib lookup record; do
  s=$(date +%s%N); (cd bench/$b && "$GLUE" run >/dev/null 2>&1); e=$(date +%s%N)
  echo "$b: $(( (e-s)/1000000 ))ms"
done
```

正确性参考值: fib=2178309, lookup=410780000, record=666666666666000000
