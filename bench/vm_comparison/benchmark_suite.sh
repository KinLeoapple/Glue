#!/usr/bin/env bash
# VM vs Tree Walker 性能与内存对比测试套件
# 严格按照language-design.md规范设计

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GLUE="${GLUE:-$PROJECT_ROOT/zig-out/bin/glue.exe}"

echo -e "${BLUE}=== Glue VM vs Tree Walker 全面对比测试 ===${NC}"
echo "构建模式: ReleaseFast"
echo "测试机器: $(uname -s) $(uname -m)"
echo "日期: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 确保已构建
if [ ! -f "$GLUE" ]; then
    echo -e "${YELLOW}构建Glue解释器...${NC}"
    cd "$PROJECT_ROOT"
    zig build -Doptimize=ReleaseFast
fi

# 创建输出目录
RESULTS_DIR="$SCRIPT_DIR/results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo -e "${GREEN}结果将保存到: $RESULTS_DIR${NC}"
echo ""

# ============ 性能基准测试 ============

echo -e "${BLUE}【第一部分】性能基准测试${NC}"
echo ""

declare -A BENCHMARKS=(
    ["fib"]="递归调用密集 - fib(32)"
    ["lookup"]="变量查找密集 - 5000x1000次查找"
    ["record"]="复合值构造 - 100万次record操作"
    ["comprehensive"]="全面特性覆盖"
)

declare -A VM_TIMES
declare -A TREE_TIMES

for bench in fib lookup record; do
    if [ ! -d "$PROJECT_ROOT/bench/$bench" ]; then
        echo -e "${YELLOW}跳过不存在的bench: $bench${NC}"
        continue
    fi

    echo -e "${YELLOW}运行 $bench: ${BENCHMARKS[$bench]}${NC}"

    # Tree Walker模式 (GLUE_VM=0)
    echo -n "  Tree Walker: "
    cd "$PROJECT_ROOT/bench/$bench"
    start_ms=$(date +%s%3N)
    GLUE_VM=0 "$GLUE" run > "$RESULTS_DIR/${bench}_tree.out" 2>&1 || true
    end_ms=$(date +%s%3N)
    tree_time=$((end_ms - start_ms))
    TREE_TIMES[$bench]=$tree_time
    echo -e "${tree_time}ms"

    # VM模式 (GLUE_VM=1, 默认)
    echo -n "  VM:          "
    start_ms=$(date +%s%3N)
    GLUE_VM=1 "$GLUE" run > "$RESULTS_DIR/${bench}_vm.out" 2>&1 || true
    end_ms=$(date +%s%3N)
    vm_time=$((end_ms - start_ms))
    VM_TIMES[$bench]=$vm_time
    echo -e "${vm_time}ms"

    # 计算提速比
    if [ $tree_time -gt 0 ]; then
        speedup=$(echo "scale=2; $tree_time / $vm_time" | bc)
        echo -e "  ${GREEN}提速: ${speedup}x${NC}"
    fi

    # 验证输出一致性
    if diff -q "$RESULTS_DIR/${bench}_tree.out" "$RESULTS_DIR/${bench}_vm.out" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓ 输出一致${NC}"
    else
        echo -e "  ${RED}✗ 输出不一致！${NC}"
        diff "$RESULTS_DIR/${bench}_tree.out" "$RESULTS_DIR/${bench}_vm.out" > "$RESULTS_DIR/${bench}_diff.txt" || true
    fi
    echo ""
done

# 测试全面对齐测试
if [ -d "$PROJECT_ROOT/tests/comprehensive_vm_alignment" ]; then
    echo -e "${YELLOW}运行 comprehensive: ${BENCHMARKS[comprehensive]}${NC}"

    cd "$PROJECT_ROOT/tests/comprehensive_vm_alignment"

    echo -n "  Tree Walker: "
    start_ms=$(date +%s%3N)
    GLUE_VM=0 "$GLUE" run > "$RESULTS_DIR/comprehensive_tree.out" 2>&1 || true
    end_ms=$(date +%s%3N)
    tree_time=$((end_ms - start_ms))
    TREE_TIMES[comprehensive]=$tree_time
    echo -e "${tree_time}ms"

    echo -n "  VM:          "
    start_ms=$(date +%s%3N)
    GLUE_VM=1 "$GLUE" run > "$RESULTS_DIR/comprehensive_vm.out" 2>&1 || true
    end_ms=$(date +%s%3N)
    vm_time=$((end_ms - start_ms))
    VM_TIMES[comprehensive]=$vm_time
    echo -e "${vm_time}ms"

    if [ $tree_time -gt 0 ]; then
        speedup=$(echo "scale=2; $tree_time / $vm_time" | bc)
        echo -e "  ${GREEN}提速: ${speedup}x${NC}"
    fi

    if diff -q "$RESULTS_DIR/comprehensive_tree.out" "$RESULTS_DIR/comprehensive_vm.out" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓ 输出一致${NC}"
    else
        echo -e "  ${RED}✗ 输出不一致！${NC}"
        diff "$RESULTS_DIR/comprehensive_tree.out" "$RESULTS_DIR/comprehensive_vm.out" > "$RESULTS_DIR/comprehensive_diff.txt" || true
    fi
    echo ""
fi

# ============ 内存使用对比 ============

echo -e "${BLUE}【第二部分】内存使用对比${NC}"
echo ""

# 使用time命令获取内存峰值 (如果可用)
if command -v /usr/bin/time &> /dev/null; then
    echo -e "${YELLOW}使用time命令测量内存峰值...${NC}"

    for bench in fib lookup record; do
        if [ ! -d "$PROJECT_ROOT/bench/$bench" ]; then
            continue
        fi

        echo -e "${YELLOW}$bench 内存使用:${NC}"
        cd "$PROJECT_ROOT/bench/$bench"

        # Tree Walker
        echo -n "  Tree Walker: "
        GLUE_VM=0 /usr/bin/time -f "%M KB" "$GLUE" run > /dev/null 2> "$RESULTS_DIR/${bench}_tree_mem.txt" || true
        cat "$RESULTS_DIR/${bench}_tree_mem.txt" | tail -1

        # VM
        echo -n "  VM:          "
        GLUE_VM=1 /usr/bin/time -f "%M KB" "$GLUE" run > /dev/null 2> "$RESULTS_DIR/${bench}_vm_mem.txt" || true
        cat "$RESULTS_DIR/${bench}_vm_mem.txt" | tail -1

        echo ""
    done
else
    echo -e "${YELLOW}time命令不可用，跳过内存测量${NC}"
fi

# ============ 功能覆盖率测试 ============

echo -e "${BLUE}【第三部分】功能覆盖率测试${NC}"
echo ""

cd "$PROJECT_ROOT/tests"

total_tests=0
vm_passed=0
tree_passed=0
both_passed=0

for test_dir in */; do
    test_name="${test_dir%/}"

    if [ ! -f "$test_dir/glue.toml" ]; then
        continue
    fi

    total_tests=$((total_tests + 1))

    echo -n "测试 $test_name: "

    # Tree Walker
    cd "$PROJECT_ROOT/tests/$test_name"
    if GLUE_VM=0 "$GLUE" run > "$RESULTS_DIR/test_${test_name}_tree.out" 2>&1; then
        tree_passed=$((tree_passed + 1))
        tree_status="${GREEN}✓${NC}"
    else
        tree_status="${RED}✗${NC}"
    fi

    # VM
    if GLUE_VM=1 "$GLUE" run > "$RESULTS_DIR/test_${test_name}_vm.out" 2>&1; then
        vm_passed=$((vm_passed + 1))
        vm_status="${GREEN}✓${NC}"
    else
        vm_status="${RED}✗${NC}"
    fi

    # 检查输出一致性
    if diff -q "$RESULTS_DIR/test_${test_name}_tree.out" "$RESULTS_DIR/test_${test_name}_vm.out" > /dev/null 2>&1; then
        both_passed=$((both_passed + 1))
        echo -e "Tree[$tree_status] VM[$vm_status] ${GREEN}输出一致${NC}"
    else
        echo -e "Tree[$tree_status] VM[$vm_status] ${YELLOW}输出不同${NC}"
        diff "$RESULTS_DIR/test_${test_name}_tree.out" "$RESULTS_DIR/test_${test_name}_vm.out" > "$RESULTS_DIR/test_${test_name}_diff.txt" 2>&1 || true
    fi
done

echo ""
echo -e "${BLUE}覆盖率统计:${NC}"
echo "  总测试数:      $total_tests"
echo "  Tree Walker:   $tree_passed / $total_tests"
echo "  VM:            $vm_passed / $total_tests"
echo "  输出一致:      $both_passed / $total_tests"

# ============ 生成报告 ============

echo ""
echo -e "${BLUE}【生成详细报告】${NC}"

REPORT="$RESULTS_DIR/REPORT.md"

cat > "$REPORT" << EOF
# Glue VM vs Tree Walker 全面对比报告

生成时间: $(date '+%Y-%m-%d %H:%M:%S')
测试机器: $(uname -s) $(uname -m)
构建模式: ReleaseFast

---

## 性能对比总结

| Benchmark | Tree Walker | VM | 提速比 | 说明 |
|-----------|-------------|-----|--------|------|
EOF

for bench in fib lookup record comprehensive; do
    if [ -n "${TREE_TIMES[$bench]:-}" ] && [ -n "${VM_TIMES[$bench]:-}" ]; then
        tree_t=${TREE_TIMES[$bench]}
        vm_t=${VM_TIMES[$bench]}
        speedup=$(echo "scale=2; $tree_t / $vm_t" | bc)
        desc="${BENCHMARKS[$bench]:-}"
        echo "| $bench | ${tree_t}ms | ${vm_t}ms | ${speedup}x | $desc |" >> "$REPORT"
    fi
done

cat >> "$REPORT" << EOF

---

## 功能覆盖率

- 总测试数: $total_tests
- Tree Walker通过: $tree_passed / $total_tests ($(echo "scale=1; $tree_passed * 100 / $total_tests" | bc)%)
- VM通过: $vm_passed / $total_tests ($(echo "scale=1; $vm_passed * 100 / $total_tests" | bc)%)
- 输出一致: $both_passed / $total_tests ($(echo "scale=1; $both_passed * 100 / $total_tests" | bc)%)

---

## 详细测试结果

所有测试输出和diff文件保存在: \`$RESULTS_DIR\`

### 性能测试输出

EOF

for bench in fib lookup record comprehensive; do
    if [ -f "$RESULTS_DIR/${bench}_tree.out" ]; then
        echo "#### $bench" >> "$REPORT"
        echo "" >> "$REPORT"
        echo "**Tree Walker输出:**" >> "$REPORT"
        echo "\`\`\`" >> "$REPORT"
        head -20 "$RESULTS_DIR/${bench}_tree.out" >> "$REPORT" || true
        echo "\`\`\`" >> "$REPORT"
        echo "" >> "$REPORT"
        echo "**VM输出:**" >> "$REPORT"
        echo "\`\`\`" >> "$REPORT"
        head -20 "$RESULTS_DIR/${bench}_vm.out" >> "$REPORT" || true
        echo "\`\`\`" >> "$REPORT"
        echo "" >> "$REPORT"
    fi
done

echo ""
echo -e "${GREEN}✓ 报告已生成: $REPORT${NC}"
echo -e "${GREEN}✓ 所有结果已保存到: $RESULTS_DIR${NC}"
echo ""

# 打印关键指标摘要
echo -e "${BLUE}=== 关键指标摘要 ===${NC}"
echo ""

if [ -n "${TREE_TIMES[fib]:-}" ] && [ -n "${VM_TIMES[fib]:-}" ]; then
    fib_speedup=$(echo "scale=2; ${TREE_TIMES[fib]} / ${VM_TIMES[fib]}" | bc)
    echo -e "fib (递归调用):      ${GREEN}${fib_speedup}x${NC} 提速"
fi

if [ -n "${TREE_TIMES[lookup]:-}" ] && [ -n "${VM_TIMES[lookup]:-}" ]; then
    lookup_speedup=$(echo "scale=2; ${TREE_TIMES[lookup]} / ${VM_TIMES[lookup]}" | bc)
    echo -e "lookup (变量查找):   ${GREEN}${lookup_speedup}x${NC} 提速"
fi

if [ -n "${TREE_TIMES[record]:-}" ] && [ -n "${VM_TIMES[record]:-}" ]; then
    record_speedup=$(echo "scale=2; ${TREE_TIMES[record]} / ${VM_TIMES[record]}" | bc)
    echo -e "record (复合值):     ${GREEN}${record_speedup}x${NC} 提速"
fi

echo ""
echo -e "VM功能覆盖率:        ${GREEN}$vm_passed / $total_tests${NC} ($(echo "scale=1; $vm_passed * 100 / $total_tests" | bc)%)"
echo -e "输出一致性:          ${GREEN}$both_passed / $total_tests${NC} ($(echo "scale=1; $both_passed * 100 / $total_tests" | bc)%)"

echo ""
echo -e "${BLUE}=== 测试完成 ===${NC}"
