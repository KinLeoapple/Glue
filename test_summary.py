#!/usr/bin/env python3
"""生成测试状态摘要"""

import subprocess
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).parent
TESTS_DIR = ROOT_DIR / "tests"
GLUE_EXE = ROOT_DIR / "zig-out" / "bin" / "glue.exe"

def classify_error(stderr):
    """分类错误类型"""
    if not stderr:
        return "unknown"

    stderr_lower = stderr.lower()

    if "parse error" in stderr_lower:
        return "parse_error"
    elif "compilation failed" in stderr_lower or "unsupported" in stderr_lower:
        return "compilation_error"
    elif "stack overflow" in stderr_lower:
        return "stack_overflow"
    elif "comparison requires numeric operands" in stderr_lower:
        return "type_refinement_bug"
    elif "error trait methods" in stderr_lower:
        return "error_trait_bug"
    elif "filenotfound" in stderr_lower:
        return "file_not_found"
    elif "runtime panic" in stderr_lower:
        return "runtime_panic"
    else:
        return "other"

def run_test(test_dir):
    try:
        result = subprocess.run(
            [str(GLUE_EXE), "run"],
            cwd=test_dir,
            capture_output=True,
            timeout=30,
            encoding='utf-8',
            errors='replace'
        )
        return result.returncode == 0, result.stderr
    except:
        return False, "timeout_or_exception"

def main():
    test_dirs = sorted([d for d in TESTS_DIR.iterdir() if d.is_dir() and (d / "glue.toml").exists()])

    passed = []
    failed_by_type = {}

    for test_dir in test_dirs:
        name = test_dir.name
        success, stderr = run_test(test_dir)

        if success:
            passed.append(name)
        else:
            error_type = classify_error(stderr)
            if error_type not in failed_by_type:
                failed_by_type[error_type] = []
            failed_by_type[error_type].append(name)

    print(f"Test Summary: {len(passed)}/{len(test_dirs)} passed ({len(passed)*100//len(test_dirs)}%)")
    print(f"\nPassed: {len(passed)} tests")

    print(f"\nFailed: {sum(len(v) for v in failed_by_type.values())} tests")
    for error_type, tests in sorted(failed_by_type.items()):
        print(f"\n  {error_type} ({len(tests)} tests):")
        for test in tests:
            print(f"    - {test}")

if __name__ == "__main__":
    main()
