# VM Type Syntax Workaround

## Problem

`type` declarations with methods were not working in the VM, causing fallback to the Tree Walker.

## Root Cause

The `checkModule` function in `src/sema/type_check.zig` corrupts memory through a buffer overflow or similar memory safety bug. This corruption affects:
- Parameter names copied by the parser
- Other heap-allocated data structures

### Evidence

1. Parameter names are correctly copied by the parser at parse time
2. Memory remains valid until `checkModule` is called
3. After `checkModule` executes, parameter name memory contains garbage
4. The same memory address contains valid data before and garbage after

This indicates a memory safety bug (likely buffer overflow) in the type checker.

## Temporary Workaround

**File**: `src/main.zig:503`

```zig
// WORKAROUND: Skip type checking in VM path due to memory corruption bug
// TODO: Fix memory safety bug in checkModule
// Original code should call: ev.prepareModuleForVm(module)
```

The VM path now skips `prepareModuleForVm`, which means:
- ✅ Basic `type` methods work in VM
- ⚠️ No type checking in VM path
- ⚠️ No trait resolution in VM path
- ⚠️ No use/import handling in VM path

## Impact

- VM can now compile and execute basic `type` declarations with methods
- 184/185 tests pass
- Programs without complex type system features work correctly

## TODO

1. **Critical**: Find and fix the memory corruption bug in `checkModule`
   - Likely in `src/sema/type_check.zig`
   - Check for:
     - Buffer overflows in string operations
     - Use-after-free bugs
     - Incorrect pointer arithmetic
     - Missing bounds checks

2. **After fix**: Re-enable `prepareModuleForVm` in VM path

3. **Testing**: Add memory sanitizer tests to catch similar bugs

## Related Files

- `src/main.zig`: Workaround location
- `src/sema/type_check.zig`: Bug location (checkModule)
- `src/parser.zig`: Parameter name copying (defensive measure)
- `src/vm/compiler.zig`: Additional parameter name copying (didn't help)

## Date

2025-06-25
