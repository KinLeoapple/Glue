#!/usr/bin/env python3
"""简化的测试运行器 - 避免编码问题"""

import os
import subprocess
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).parent
TESTS_DIR = ROOT_DIR / "tests"
GLUE_EXE = ROOT_DIR / "zig-out" / "bin" / "glue.exe"

def run_test(test_dir):
    """运行单个测试"""
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
        return False, "Exception"

def main():
    test_dirs = sorted([d for d in TESTS_DIR.iterdir()
                        if d.is_dir()
                        and (d / "glue.toml").exists()
                        and not d.name.endswith('.deprecated')
                        and not d.name.endswith('.pending')])

    passed = []
    failed = []

    for test_dir in test_dirs:
        name = test_dir.name
        success, stderr = run_test(test_dir)

        if success:
            passed.append(name)
            print(f"PASS: {name}")
        else:
            failed.append(name)
            print(f"FAIL: {name}")

    print(f"\n{'='*80}")
    print(f"Results: {len(passed)} passed, {len(failed)} failed out of {len(test_dirs)} tests")
    print(f"\nPassed tests ({len(passed)}):")
    for name in passed:
        print(f"  - {name}")

    print(f"\nFailed tests ({len(failed)}):")
    for name in failed:
        print(f"  - {name}")

    return 0 if not failed else 1

if __name__ == "__main__":
    sys.exit(main())
