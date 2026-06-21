#!/usr/bin/env bash
# 回归测试：遍历 tests/*/ 项目目录，对每个执行 `glue run`，断言 exit 0。
# 用法：bash run_tests.sh   （在项目根运行）
set -u
EXE="${GLUE_EXE:-F:/Projects/Zig/Glue/zig-out/bin/glue.exe}"
ROOT="$(cd "$(dirname "$0")" && pwd)"

pass=0; fail=0
run_project() {
  local dir="$1"
  [ -f "$dir/glue.toml" ] || return 0
  if ( cd "$dir" && timeout 120 "$EXE" run >/dev/null 2>&1 ); then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL: $dir"
  fi
}

for d in "$ROOT"/tests/*/; do
  run_project "$d"
done
# 多模块项目
run_project "$ROOT/test_module_trait"

echo "projects: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
