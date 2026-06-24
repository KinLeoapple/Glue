#!/usr/bin/env bash
# 内存泄漏和正确性深度验证
# 使用 glue debug 模式运行所有测试，检查内存泄漏

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GLUE="${GLUE:-$PROJECT_ROOT/zig-out/bin/glue.exe}"

echo -e "${BLUE}=== Glue VM 内存泄漏深度检测 ===${NC}"
echo "模式: glue debug (内存检查 + 运行时错误位置追踪)"
echo "日期: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 创建输出目录
RESULTS_DIR="$SCRIPT_DIR/memory_check_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

# 确保已构建Debug版本
echo -e "${YELLOW}构建Debug版本...${NC}"
cd "$PROJECT_ROOT"
zig build

echo ""
echo -e "${BLUE}【内存泄漏检测】${NC}"
echo ""

cd "$PROJECT_ROOT/tests"

total=0
passed=0
leaked=0

for test_dir in */; do
    test_name="${test_dir%/}"

    if [ ! -f "$test_dir/glue.toml" ]; then
        continue
    fi

    total=$((total + 1))
    echo -n "检测 $test_name: "

    cd "$PROJECT_ROOT/tests/$test_name"

    # VM模式运行debug
    if GLUE_VM=1 "$GLUE" debug > "$RESULTS_DIR/${test_name}_debug.out" 2>&1; then
        # 检查是否有LEAK报告
        if grep -q "LEAK:" "$RESULTS_DIR/${test_name}_debug.out"; then
            echo -e "${RED}✗ 内存泄漏${NC}"
            leaked=$((leaked + 1))
            grep "LEAK:" "$RESULTS_DIR/${test_name}_debug.out" > "$RESULTS_DIR/${test_name}_leaks.txt"
        else
            echo -e "${GREEN}✓ 无泄漏${NC}"
            passed=$((passed + 1))
        fi
    else
        echo -e "${RED}✗ 运行失败${NC}"
    fi
done

echo ""
echo -e "${BLUE}内存检测统计:${NC}"
echo "  总测试数:   $total"
echo "  无泄漏:     $passed"
echo "  有泄漏:     $leaked"
echo "  失败:       $((total - passed - leaked))"

if [ $leaked -gt 0 ]; then
    echo ""
    echo -e "${RED}发现内存泄漏的测试:${NC}"
    for leak_file in "$RESULTS_DIR"/*_leaks.txt; do
        if [ -f "$leak_file" ]; then
            test_name=$(basename "$leak_file" _leaks.txt)
            echo "  - $test_name"
            head -5 "$leak_file"
        fi
    done
fi

echo ""
echo -e "${GREEN}结果已保存到: $RESULTS_DIR${NC}"
