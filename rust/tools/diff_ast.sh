#!/bin/bash
# AST diff 验证脚本
# 对每个 .glue 文件运行 Rust 和 Zig 两版 AST 打印器，diff 输出
# 用法: cd rust && bash tools/diff_ast.sh [file_or_dir...]

set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUST_DIR="$PROJECT_ROOT/rust"
ZIG_BIN="$PROJECT_ROOT/zig-out/bin/ast_printer"

# 确保两个二进制都是最新的
echo "Building Zig ast_printer..."
cd "$PROJECT_ROOT" && zig build 2>/dev/null
echo "Building Rust glue..."
cd "$RUST_DIR" && cargo build --quiet 2>/dev/null

# 收集 .glue 文件
if [ $# -gt 0 ]; then
    GLUE_FILES=()
    for arg in "$@"; do
        if [ -d "$arg" ]; then
            while IFS= read -r f; do
                GLUE_FILES+=("$f")
            done < <(find "$arg" -name "*.glue" | sort)
        elif [ -f "$arg" ]; then
            GLUE_FILES+=("$arg")
        fi
    done
else
    GLUE_FILES=()
    while IFS= read -r f; do
        GLUE_FILES+=("$f")
    done < <(find "$PROJECT_ROOT/tests" "$PROJECT_ROOT/builtin" "$PROJECT_ROOT/src/builtin" "$PROJECT_ROOT/src/std" -name "*.glue" 2>/dev/null | sort)
fi

TOTAL=${#GLUE_FILES[@]}
PASS=0
FAIL=0
ERRORS=0

echo "Testing $TOTAL .glue files..."
echo ""

for f in "${GLUE_FILES[@]}"; do
    # 运行 Rust 侧
    RUST_OUT=$(cd "$RUST_DIR" && cargo run --quiet -- parse "$f" 2>/dev/null)
    RUST_RC=$?
    # 运行 Zig 侧
    ZIG_OUT=$("$ZIG_BIN" "$f" 2>/dev/null)
    ZIG_RC=$?

    if [ $RUST_RC -ne 0 ] || [ $ZIG_RC -ne 0 ]; then
        ERRORS=$((ERRORS + 1))
        if [ $RUST_RC -ne 0 ]; then
            echo "RUST ERROR: $f"
        fi
        if [ $ZIG_RC -ne 0 ]; then
            echo "ZIG ERROR: $f"
        fi
        continue
    fi

    if [ "$RUST_OUT" == "$ZIG_OUT" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "DIFF: $f"
        diff <(echo "$RUST_OUT") <(echo "$ZIG_OUT") | head -30
        echo "---"
    fi
done

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL diff, $ERRORS error ==="
exit $FAIL
