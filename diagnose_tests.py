#!/usr/bin/env python3
"""测试诊断工具 - 详细输出每个失败测试的错误信息"""

import subprocess
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).parent
TESTS_DIR = ROOT_DIR / "tests"
GLUE_EXE = ROOT_DIR / "zig-out" / "bin" / "glue.exe"

def run_test(test_dir):
    """运行单个测试并返回详细信息"""
    try:
        result = subprocess.run(
            [str(GLUE_EXE), "run"],
            cwd=test_dir,
            capture_output=True,
            timeout=30,
            encoding='utf-8',
            errors='replace'
        )
        return result.returncode == 0, result.stdout, result.stderr
    except Exception as e:
        return False, "", str(e)

def main():
    if len(sys.argv) > 1:
        # 诊断特定测试
        test_names = sys.argv[1:]
        test_dirs = [TESTS_DIR / name for name in test_names]
    else:
        # 诊断所有失败的测试
        test_dirs = sorted([d for d in TESTS_DIR.iterdir() if d.is_dir() and (d / "glue.toml").exists()])

    for test_dir in test_dirs:
        if not test_dir.exists():
            print(f"Test not found: {test_dir.name}")
            continue

        name = test_dir.name
        success, stdout, stderr = run_test(test_dir)

        if not success:
            print(f"\n{'='*80}")
            print(f"FAILED: {name}")
            print('='*80)
            if stderr:
                print("STDERR:")
                print(stderr[:1000])  # 限制输出长度
            if stdout:
                print("\nSTDOUT:")
                print(stdout[:1000])
            print()

if __name__ == "__main__":
    main()
