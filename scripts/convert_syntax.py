#!/usr/bin/env python3
"""
将 Glue 测试文件从旧语法转换为新语法：
1. 将 `use` 改为 `import`
2. 将用户定义类型的 `impl TraitName<TypeName>` 转换为在 type 定义时实现

注意：内建类型（i32, f64, str等）的 impl 保留不变
"""

import re
import sys

def is_builtin_type(type_name):
    """检查是否为内建类型"""
    builtin_types = {
        'i8', 'i16', 'i32', 'i64', 'i128',
        'u8', 'u16', 'u32', 'u64', 'u128',
        'f32', 'f64', 'bool', 'str', 'char', 'Unit'
    }
    return type_name in builtin_types

def convert_use_to_import(content):
    """将 use 改为 import"""
    return re.sub(r'^use\s+', 'import ', content, flags=re.MULTILINE)

def extract_impls(content):
    """提取所有 impl 声明"""
    # 匹配: impl TraitName<TypeName> with ... { methods }
    # 或: impl TraitName<TypeName> { methods }
    impl_pattern = r'impl\s+(\w+)<([\w<>, ]+)>(?:\s+with\s+([\w<>, ]+))?\s*\{([\s\S]*?)^\}'

    impls = []
    for match in re.finditer(impl_pattern, content, re.MULTILINE):
        trait_name = match.group(1)
        type_spec = match.group(2).strip()
        with_clause = match.group(3)
        methods = match.group(4)

        # 提取实际的类型名（去掉泛型参数）
        type_name = re.match(r'(\w+)', type_spec).group(1)

        impls.append({
            'full_match': match.group(0),
            'trait_name': trait_name,
            'type_name': type_name,
            'type_spec': type_spec,
            'with_clause': with_clause,
            'methods': methods,
            'start': match.start(),
            'end': match.end()
        })

    return impls

def main():
    if len(sys.argv) < 2:
        print("Usage: convert_syntax.py <glue_file>")
        sys.exit(1)

    filepath = sys.argv[1]

    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    # 1. 转换 use 为 import
    content = convert_use_to_import(content)

    # 2. 提取 impl 信息（用于后续手动合并到 type 定义）
    impls = extract_impls(content)

    print(f"File: {filepath}")
    print(f"Found {len(impls)} impl blocks:")

    for impl in impls:
        type_name = impl['type_name']
        trait_name = impl['trait_name']
        is_builtin = is_builtin_type(type_name)

        print(f"  - impl {trait_name}<{impl['type_spec']}> {'(builtin, keep as-is)' if is_builtin else '(user-defined, needs merge)'}")

    # 写回文件（目前只转换 use）
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)

    print(f"\nConverted 'use' to 'import' in {filepath}")
    print("Note: impl blocks for user-defined types need manual merging with type definitions")

if __name__ == '__main__':
    main()
