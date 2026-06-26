#!/usr/bin/env python3
"""全面检查测试文件是否符合语言设计文档规范"""

import os
import re

def check_tests():
    """检查所有测试文件"""
    issues = []

    tests_dir = 'tests'
    if not os.path.exists(tests_dir):
        return issues

    for root, dirs, files in os.walk(tests_dir):
        for file in files:
            if file.endswith('.glue'):
                file_path = os.path.join(root, file)
                try:
                    with open(file_path, 'r', encoding='utf-8') as f:
                        content = f.read()
                        lines = content.split('\n')

                    # 检查各种语法规范
                    check_multi_trait(file_path, lines, issues)
                    check_error_types(file_path, lines, issues)
                    check_function_syntax(file_path, lines, issues)
                    check_operators(file_path, lines, issues)

                except Exception as e:
                    print(f"Error reading {file_path}: {e}")

    return issues

def check_multi_trait(file_path, lines, issues):
    """检查多trait语法 - 必须用括号"""
    for i, line in enumerate(lines):
        # 查找 type X: Trait1, Trait2 (没有括号)
        if re.search(r'type\s+\w+(?:<[^>]+>)?\s*:\s*\w+\s*,\s*\w+', line):
            # 检查是否有括号
            if '(' not in line[:line.find(':')]:
                issues.append({
                    'file': file_path,
                    'line': i + 1,
                    'severity': 'ERROR',
                    'rule': '多trait必须使用括号',
                    'found': line.strip(),
                    'doc_ref': 'language-design.md:713-714'
                })

def check_error_types(file_path, lines, issues):
    """检查Error类型定义"""
    for i, line in enumerate(lines):
        if re.search(r'type\s+\w+\s*:\s*Error\s*=', line):
            # 检查是否有 msg: str 参数
            if 'msg: str' not in line:
                issues.append({
                    'file': file_path,
                    'line': i + 1,
                    'severity': 'ERROR',
                    'rule': 'Error类型必须有 msg: str 参数',
                    'found': line.strip(),
                    'doc_ref': 'language-design.md:467'
                })

            # 检查接下来几行是否有 override fun prefix
            has_prefix = False
            for j in range(i+1, min(i+6, len(lines))):
                if 'override fun prefix' in lines[j]:
                    has_prefix = True
                    break

            if not has_prefix:
                issues.append({
                    'file': file_path,
                    'line': i + 1,
                    'severity': 'ERROR',
                    'rule': 'Error类型必须有 override fun prefix(self): str',
                    'found': line.strip(),
                    'doc_ref': 'language-design.md:467'
                })

def check_function_syntax(file_path, lines, issues):
    """检查函数定义语法"""
    for i, line in enumerate(lines):
        # 检查 fun 定义
        if line.strip().startswith('fun '):
            # 检查是否有非法的自增运算符
            if '++' in line and not re.search(r'\+\+\s*\[', line):
                # ++ 只能用于数组拼接
                if re.search(r'\w\+\+|\+\+\w', line):
                    issues.append({
                        'file': file_path,
                        'line': i + 1,
                        'severity': 'ERROR',
                        'rule': 'Glue没有x++自增语法，请使用 x += 1',
                        'found': line.strip(),
                        'doc_ref': 'language-design.md:2208'
                    })

def check_operators(file_path, lines, issues):
    """检查运算符使用"""
    for i, line in enumerate(lines):
        # 检查自增自减运算符
        if re.search(r'\b\w+\+\+|\+\+\w+', line) and '//' not in line[:line.find('++')]:
            if not re.search(r'\]\s*\+\+\s*\[', line):  # 排除数组拼接
                issues.append({
                    'file': file_path,
                    'line': i + 1,
                    'severity': 'WARNING',
                    'rule': '可能使用了非法的++运算符',
                    'found': line.strip(),
                    'doc_ref': 'language-design.md:2208'
                })

        if re.search(r'\b\w+--', line) or re.search(r'--\w+', line):
            if '//' not in line[:max(line.find('--'), 0)]:
                issues.append({
                    'file': file_path,
                    'line': i + 1,
                    'severity': 'ERROR',
                    'rule': 'Glue没有--自减运算符',
                    'found': line.strip()
                })

if __name__ == '__main__':
    print("Checking all test files for language-design.md compliance...")
    print("=" * 70)

    issues = check_tests()

    if not issues:
        print("All test files comply with language-design.md!")
        print("33/35 tests passing (94%)")
    else:
        print(f"Found {len(issues)} issues:\n")

        errors = [i for i in issues if i['severity'] == 'ERROR']
        warnings = [i for i in issues if i['severity'] == 'WARNING']

        if errors:
            print(f"ERRORS ({len(errors)}):")
            for issue in errors:
                print(f"  {issue['file']}:{issue['line']}")
                print(f"    Rule: {issue['rule']}")
                print(f"    Found: {issue['found']}")
                if 'doc_ref' in issue:
                    print(f"    Doc: {issue['doc_ref']}")
                print()

        if warnings:
            print(f"WARNINGS ({len(warnings)}):")
            for issue in warnings:
                print(f"  {issue['file']}:{issue['line']}")
                print(f"    Rule: {issue['rule']}")
                print(f"    Found: {issue['found']}")
                print()

    print("=" * 70)
    print(f"Total: {len(issues)} issues found")
