# Bug Fix: Memory Corruption in Type Checker

## Issue

Type declarations with methods were not working in the VM, causing fallback to the Tree Walker. The root cause was a memory corruption bug in the type checker.

## Root Cause

**File**: `src/sema/type_check.zig:4142`

The code was directly using `HashMap.put()` to add method parameters to the type environment:

```zig
method_env.bindings.put(param.name, scheme) catch continue;
```

However, `TypeEnv` expects to **own** the keys in its HashMap. When `TypeEnv.deinit()` is called, it frees all keys:

```zig
pub fn deinit(self: *TypeEnv) void {
    var iter = self.bindings.iterator();
    while (iter.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);  // ← Frees the key!
        self.allocator.free(entry.value_ptr.quantified_vars);
    }
    self.bindings.deinit();
}
```

By using `put()` directly with `param.name` (which points to the parser's memory), the type checker was:
1. Storing a pointer to parser-allocated memory in the HashMap
2. Potentially corrupting that memory during HashMap rehashing
3. Freeing the parser's memory when `TypeEnv.deinit()` was called

This caused parameter names to become corrupted, leading to compilation failures in the VM.

## Solution

Use the `TypeEnv.define()` method instead of direct `put()`. The `define()` method properly duplicates the key before storing it:

```zig
pub fn define(self: *TypeEnv, name: []const u8, scheme: TypeScheme) !void {
    if (self.bindings.contains(name)) {
        return error.DuplicateDefinition;
    }
    const key = try self.allocator.dupe(u8, name);  // ← Duplicates the key
    try self.bindings.put(key, scheme);
}
```

**Fixed code** (line 4143):
```zig
method_env.define(param.name, scheme) catch continue;
```

## Impact

- ✅ Type methods now work correctly in the VM with full type checking
- ✅ 184/185 tests pass (same as before)
- ✅ No performance impact
- ✅ Proper memory safety maintained

## Testing

Test case with multiple types and methods with parameters:

```glue
trait Greet {
    fun hello(self): str
    fun greet(self, name: str): str
}

type Cat: Greet = Cat(name: str) {
    fun hello(self): str {
        self.name
    }

    fun greet(self, greeting: str): str {
        greeting + ", " + self.name
    }
}

type Dog: Greet = Dog(name: str, age: i32) {
    fun hello(self): str {
        self.name + " (age: " + str(self.age) + ")"
    }

    fun greet(self, greeting: str): str {
        greeting + ", I'm " + self.name
    }
}
```

Expected output:
```
Whiskers
Hello, Whiskers
Buddy (age: 5)
Hi, I'm Buddy
```

Result: ✅ All outputs correct

## Lessons Learned

1. **Never bypass container ownership semantics**: When a data structure expects to own its keys, always use the provided API (e.g., `define()`) rather than direct manipulation (e.g., `put()`)

2. **HashMap key ownership**: In Zig, StringHashMap does not automatically duplicate keys. The caller must ensure proper ownership semantics.

3. **Memory safety patterns**: This bug is similar to use-after-free and double-free bugs in C/C++. Even in Zig, manual memory management requires careful attention to ownership.

## Related Code

- `src/sema/type_check.zig:421-477` - TypeEnv definition and memory management
- `src/sema/type_check.zig:4090-4168` - Type method checking
- `src/sema/type_check.zig:4143` - Bug fix location

## Date

2025-06-25
