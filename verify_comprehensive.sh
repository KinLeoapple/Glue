#!/bin/bash
# VM 与 Tree Walker 全面对齐验证
# 测试所有language-design.md中定义的特性

GLUE="F:/Projects/Zig/Glue/zig-out/bin/glue.exe"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "=== VM 与 Tree Walker 全面对齐验证 ==="
echo "临时目录: $TMPDIR"
echo ""

cd "$TMPDIR"
mkdir -p src
cat > glue.toml <<EOF
[project]
name = "comprehensive_test"
version = "0.1.0"
EOF

pass_vm=0
pass_tw=0
fail_vm=0
fail_tw=0
mismatch=0

# 测试辅助函数 - 同时运行VM和Tree Walker并对比
test_both() {
    local name="$1"
    local code="$2"
    local expected="$3"

    echo -n "[$name] "
    echo "$code" > "$TMPDIR/src/Main.glue"
    cd "$TMPDIR"

    # Tree Walker 模式
    tw_output=$("$GLUE" run 2>&1 || echo "FAILED")

    # VM 模式
    vm_output=$(GLUE_VM=1 "$GLUE" run 2>&1 || echo "FAILED")

    local tw_ok=false
    local vm_ok=false

    # 检查 Tree Walker
    if [ "$tw_output" = "$expected" ]; then
        tw_ok=true
        ((pass_tw++))
    else
        ((fail_tw++))
    fi

    # 检查 VM
    if [ "$vm_output" = "$expected" ]; then
        vm_ok=true
        ((pass_vm++))
    else
        ((fail_vm++))
    fi

    # 输出结果
    if $tw_ok && $vm_ok; then
        echo "✓ (TW+VM)"
    elif $tw_ok && ! $vm_ok; then
        echo "✗ (TW✓ VM✗: $vm_output)"
        ((mismatch++))
    elif ! $tw_ok && $vm_ok; then
        echo "✗ (TW✗ VM✓: $tw_output)"
        ((mismatch++))
    else
        echo "✗ (TW✗ VM✗)"
    fi
}

echo "=== §2.1 基本类型和字面量 ==="

test_both "int-literals" \
'fun main() {
    println(42i8)
    println(255u8)
    println(1000i32)
    println(9999999999i64)
}' \
"42
255
1000
9999999999"

test_both "float-literals" \
'fun main() {
    println(3.14f32)
    println(2.718f64)
}' \
"3.14
2.718"

test_both "bool-literals" \
'fun main() {
    println(true)
    println(false)
}' \
"true
false"

test_both "string-escape" \
'fun main() {
    println("hello\nworld")
    println("tab\there")
}' \
"hello
world
tab	here"

echo ""
echo "=== §2.2 变量绑定 ==="

test_both "val-immutable" \
'fun main() {
    val x = 42i64
    println(x)
}' \
"42"

test_both "var-mutable" \
'fun main() {
    var x = 1i64
    x = 2i64
    println(x)
}' \
"2"

test_both "shadowing" \
'fun main() {
    val x = 1i64
    {
        val x = 2i64
        println(x)
    }
    println(x)
}' \
"2
1"

echo ""
echo "=== §2.3 Nullable 类型 ==="

test_both "nullable-some" \
'fun main() {
    val x: i64? = 42i64
    match x {
        null => println("none"),
        v => println(v)
    }
}' \
"42"

test_both "nullable-none" \
'fun main() {
    val x: i64? = null
    match x {
        null => println("none"),
        v => println(v)
    }
}' \
"none"

test_both "nullable-propagate" \
'fun get(): i64? { null }
fun main() {
    val x = get()?
    println("unreachable")
}' \
""

test_both "nullable-coalesce" \
'fun main() {
    val x: i64? = null
    println(x ?? 42i64)
}' \
"42"

test_both "nullable-coalesce-some" \
'fun main() {
    val x: i64? = 10i64
    println(x ?? 42i64)
}' \
"10"

echo ""
echo "=== §2.4 Throw 类型 ==="

test_both "throw-error" \
'fun fail(): Throw<i64, str> { throw "error" }
fun main() {
    val r = fail()
    match r {
        Error(e) => println(e),
        Ok(v) => println(v)
    }
}' \
"error"

test_both "throw-ok" \
'fun succeed(): Throw<i64, str> { 42i64 }
fun main() {
    val r = succeed()
    match r {
        Error(e) => println(e),
        Ok(v) => println(v)
    }
}' \
"42"

test_both "throw-propagate" \
'fun fail(): Throw<i64, str> { throw "error" }
fun chain(): Throw<i64, str> { fail()? + 1i64 }
fun main() {
    val r = chain()
    match r {
        Error(e) => println(e),
        Ok(v) => println(v)
    }
}' \
"error"

test_both "throw-ok-unwrap" \
'fun succeed(): Throw<i64, str> { 42i64 }
fun main() { println(succeed()?) }' \
"42"

echo ""
echo "=== §2.5 ADT 类型 ==="

test_both "adt-enum-simple" \
'type Color = | Red | Green | Blue
fun main() {
    val c = Red
    match c {
        Red => println("red"),
        Green => println("green"),
        Blue => println("blue")
    }
}' \
"red"

test_both "adt-enum-with-data" \
'type Shape = | Circle(f64) | Rectangle(f64, f64)
fun area(s: Shape): f64 {
    match s {
        Circle(r) => 3.14f64 * r * r,
        Rectangle(w, h) => w * h
    }
}
fun main() { println(area(Rectangle(4.0f64, 5.0f64))) }' \
"20"

test_both "adt-tuple-type" \
'type Point = (x: i64, y: i64)
fun main() {
    val p = Point(3i64, 4i64)
    println(p.x)
    println(p.y)
}' \
"3
4"

test_both "adt-nested-pattern" \
'type Tree = | Leaf(i64) | Node(Tree, Tree)
fun sum(t: Tree): i64 {
    match t {
        Leaf(x) => x,
        Node(Leaf(a), Leaf(b)) => a + b,
        Node(l, r) => sum(l) + sum(r)
    }
}
fun main() { println(sum(Node(Leaf(1i64), Node(Leaf(2i64), Leaf(3i64))))) }' \
"6"

echo ""
echo "=== §2.6 模式匹配 ==="

test_both "pattern-literal" \
'fun check(x: i64): str {
    match x {
        0i64 => "zero",
        1i64 => "one",
        _ => "other"
    }
}
fun main() { println(check(1i64)) }' \
"one"

test_both "pattern-wildcard" \
'type Option<T> = | Some(T) | None
fun main() {
    val x = None
    match x {
        Some(_) => println("some"),
        None => println("none")
    }
}' \
"none"

test_both "pattern-guard" \
'type Option<T> = | Some(T) | None
fun check(x: Option<i64>): str {
    match x {
        Some(v) if v > 0i64 => "positive",
        Some(v) if v < 0i64 => "negative",
        Some(_) => "zero",
        None => "none"
    }
}
fun main() { println(check(Some(5i64))) }' \
"positive"

# 注意：Glue不支持匿名元组，记录必须有命名字段
# test_both "pattern-tuple-destruct" - 已移除（语言设计不支持）

echo ""
echo "=== §2.7 Trait 系统 ==="

test_both "trait-basic" \
'trait Show { fun show(self): str }
type Point = | Point(i64, i64)
impl Show<Point> {
    fun show(self): str {
        "point"
    }
}
fun main() { println(Point(1i64, 2i64).show()) }' \
"point"

test_both "trait-default-impl" \
'trait Greet { fun greet(self): str { "hello" } }
type Person = | Person
impl Greet<Person> {}
fun main() { println(Person.greet()) }' \
"hello"

test_both "trait-override" \
'trait A { fun f(self): str { "A" } }
trait B { fun f(self): str { "B" } }
trait C(A, B) { override fun f(self): str { "C" } }
type T = | T
impl A<T> { fun f(self): str { "A" } }
impl B<T> { fun f(self): str { "B" } }
impl C<T> {}
fun main() { println(T.f()) }' \
"C"

echo ""
echo "=== §2.8 泛型 ==="

test_both "generic-function" \
'fun id<T>(x: T): T { x }
fun main() { println(id(42i64)) }' \
"42"

test_both "generic-type" \
'type Box<T> = | Box(T)
fun main() {
    val b = Box(42i64)
    match b {
        Box(v) => println(v)
    }
}' \
"42"

echo ""
echo "=== §2.15 类型转换 ==="

test_both "explicit-cast-widen" \
'fun main() {
    val x: i64 = i64(42i32)
    println(x)
}' \
"42"

test_both "explicit-cast-narrow" \
'fun main() {
    val x: i32 = i32(42i64)
    println(x)
}' \
"42"

test_both "no-implicit-convert" \
'fun f(x: i64) { println(x) }
fun main() { f(i64(42i32)) }' \
"42"

echo ""
echo "=== §3 并发特性 ==="

test_both "spawn-basic" \
'fun main() {
    val s = spawn { 42i64 }
    println(s.await())
}' \
"42"

test_both "spawn-snapshot" \
'fun main() {
    var x = 1i64
    val s = spawn { x }
    x = 2i64
    println(s.await())
}' \
"1"

test_both "atomic-basic" \
'fun main() {
    var counter: Atomic<i64> = atomic 0i64
    counter = counter + 1i64
    println(counter)
}' \
"1"

test_both "atomic-spawn" \
'fun main() {
    var counter: Atomic<i64> = atomic 0i64
    val s = spawn { counter = counter + 1i64 }
    s.await()
    println(counter)
}' \
"1"

test_both "channel-send-recv" \
'fun main() {
    val ch: Channel<i64> = channel<i64>(0)
    val s = spawn { ch.sender.send(42i64) }
    println(ch.receiver.recv())
    s.await()
}' \
"42"

echo ""
echo "=== §4 函数特性 ==="

test_both "function-basic" \
'fun add(a: i64, b: i64): i64 { a + b }
fun main() { println(add(1i64, 2i64)) }' \
"3"

# 注意：表达式体函数（fun f() = expr）在文档中定义但parser未实现
# test_both "function-expression-body" - 标记为待实现特性
test_both "function-expression-body" \
'fun add(a: i64, b: i64): i64 = a + b
fun main() { println(add(1i64, 2i64)) }' \
"3"

test_both "closure-capture" \
'fun main() {
    val x = 42i64
    val f = fun() { x }
    println(f())
}' \
"42"

test_both "closure-parameter" \
'fun apply(f: i64 -> i64, x: i64): i64 { f(x) }
fun main() { println(apply(fun(x) { x + 1i64 }, 41i64)) }' \
"42"

echo ""
echo "=== §6 控制流 ==="

test_both "if-else" \
'fun main() {
    val x = 5i64
    if x > 0i64 {
        println("positive")
    } else {
        println("non-positive")
    }
}' \
"positive"

test_both "if-expression" \
'fun main() {
    val x = 5i64
    val result = if x > 0i64 { "positive" } else { "non-positive" }
    println(result)
}' \
"positive"

test_both "loop-while" \
'fun main() {
    var i = 0i64
    while i < 3i64 {
        println(i)
        i = i + 1i64
    }
}' \
"0
1
2"

test_both "loop-for-range" \
'fun main() {
    for i in [1i64, 2i64, 3i64] {
        println(i)
    }
}' \
"1
2
3"

test_both "loop-capture-independent" \
'fun main() {
    var fns = []
    for i in [1i64, 2i64, 3i64] {
        val captured = i
        fns = fns ++ [fun() { captured }]
    }
    println(fns[0]())
    println(fns[1]())
    println(fns[2]())
}' \
"1
2
3"

test_both "defer-basic" \
'fun main() {
    defer { println("2") }
    println("1")
}' \
"1
2"

test_both "defer-lifo" \
'fun main() {
    defer { println("3") }
    defer { println("2") }
    println("1")
}' \
"1
2
3"

echo ""
echo "=== §6.11 运算符 ==="

test_both "arithmetic-ops" \
'fun main() {
    println(1i64 + 2i64)
    println(5i64 - 3i64)
    println(3i64 * 4i64)
    println(10i64 / 2i64)
    println(10i64 % 3i64)
}' \
"3
2
12
5
1"

test_both "comparison-ops" \
'fun main() {
    println(1i64 < 2i64)
    println(2i64 > 1i64)
    println(2i64 == 2i64)
    println(2i64 != 3i64)
    println(2i64 <= 2i64)
    println(2i64 >= 2i64)
}' \
"true
true
true
true
true
true"

test_both "logical-ops" \
'fun main() {
    println(true && true)
    println(true && false)
    println(true || false)
    println(false || false)
    println(!true)
    println(!false)
}' \
"true
false
true
false
false
true"

test_both "bitwise-ops" \
'fun main() {
    println(5i64 & 3i64)
    println(5i64 | 3i64)
    println(5i64 ^ 3i64)
}' \
"1
7
6"

test_both "string-concat" \
'fun main() { println("hello" + " " + "world") }' \
"hello world"

test_both "list-concat" \
'fun main() { println([1i64, 2i64] ++ [3i64, 4i64]) }' \
"[1, 2, 3, 4]"

echo ""
echo "=== 综合测试 ==="

test_both "fibonacci-recursive" \
'fun fib(n: i64): i64 {
    if n <= 1i64 {
        n
    } else {
        fib(n - 1i64) + fib(n - 2i64)
    }
}
fun main() { println(fib(10i64)) }' \
"55"

test_both "list-operations" \
'fun main() {
    val xs = [1i64, 2i64, 3i64]
    println(xs[0])
    println(xs[1])
    println(xs[2])
}' \
"1
2
3"

# 注意：Glue不支持Map字面量语法（如 {"a": 1}）
# test_both "map-operations" - 已移除（语言设计不支持）

echo ""
echo "=== 验证结果 ==="
echo "Tree Walker: 通过 $pass_tw, 失败 $fail_tw"
echo "VM:          通过 $pass_vm, 失败 $fail_vm"
echo "不一致:      $mismatch 项"
echo "总计:        $((pass_tw + fail_tw)) 项测试"
echo ""

if [ $mismatch -eq 0 ] && [ $fail_vm -eq 0 ] && [ $fail_tw -eq 0 ]; then
    echo "✓ VM 与 Tree Walker 完全一致"
    exit 0
elif [ $mismatch -gt 0 ]; then
    echo "✗ 发现 $mismatch 项行为不一致"
    exit 1
else
    echo "⚠ 部分测试失败（但VM与TW行为一致）"
    exit 2
fi
