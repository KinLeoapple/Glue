# Memory Corruption Analysis in checkModule

## Debug Output Evidence

### Timeline of Memory Corruption

```
parseParam: copying 'self' from ptr=u8@24e2c8a045b
parseParam: copied to ptr=u8@24e2cb51b78
After parsing, 3 decls
  Found type_decl 'Cat', 1 methods
    method 'hello', param[0].ptr=u8@24e2cb51b78, name='self'    ✓ VALID

tryRunOnVM: entry, checking params
  type 'Cat', param[0].ptr=u8@24e2cb51b78, name='self'          ✓ VALID

After prepareModuleForVm, checking params:
  type 'Cat', param[0].ptr=u8@24e2cb51b78, name='����'          ✗ CORRUPTED

compileMethodBody: param.ptr=u8@24e2cb51b78, name='����'        ✗ CORRUPTED
```

### Key Observations

1. **Memory address unchanged**: `u8@24e2cb51b78` remains the same throughout
2. **Content corrupted**: 'self' (4 bytes) → '����' (garbage)
3. **Corruption point**: Between `tryRunOnVM: entry` and `After prepareModuleForVm`
4. **Corrupting function**: `ev.prepareModuleForVm(module)` → `checkModule(&module)`

### Memory Layout Analysis

Original string: `'self'`
- Byte 0: 's' (0x73)
- Byte 1: 'e' (0x65)
- Byte 2: 'l' (0x6C)
- Byte 3: 'f' (0x66)

Corrupted string: `'����'` (4-byte UTF-8 replacement characters)
- Indicates non-ASCII byte values
- Suggests random memory write or freed memory

### Defensive Measures Tried

1. **Parser-level copying** (`src/parser.zig`):
   - Copy parameter names during parsing
   - Result: Copied memory still gets corrupted ✗

2. **Compiler-level copying** (`src/vm/compiler.zig`):
   - Copy parameter names again before use
   - Result: Source is already corrupted ✗

3. **Skipping checkModule**:
   - Skip `prepareModuleForVm` entirely
   - Result: Memory remains valid ✓

## Suspect Areas in checkModule

### Call Chain
```
tryRunOnVM
  → ev.prepareModuleForVm(module)
    → self.prepareModuleInner(module)
      → self.type_inferencer.checkModule(&module)
```

### Likely Bug Locations

1. **Type inference string operations**
   - Building type names
   - Concatenating trait names
   - Error message construction

2. **Environment/scope management**
   - HashMap operations
   - Stack operations on linear_scope_stack
   - Copying or moving AST nodes

3. **ADT/Trait registry**
   - Storing type information
   - Pointer handling in recursive structures

### Specific Functions to Audit

In `src/sema/type_check.zig`:
- `checkModule` (line 3036)
- `checkModuleWithName` (line 3041)
- `resetForNextModule` (line 842)
- Any function that allocates/deallocates strings
- Any function that copies AST structures

## Reproduction Steps

1. Create a simple `type` declaration with a method that has parameters
2. Run with VM enabled
3. Observe memory corruption after `checkModule` executes

## Test Case

```glue
trait Greet {
    fun hello(self): str
}

type Cat: Greet = Cat(name: str) {
    fun hello(self): str {
        self.name
    }
}

fun main() {
    val c = Cat("Whiskers")
    println(c.hello())
}
```

## Memory Sanitizer Recommendation

Run with:
- Valgrind (if Linux)
- AddressSanitizer (clang/gcc `-fsanitize=address`)
- Zig's safety checks (already enabled in Debug builds)

Look for:
- Buffer overflows
- Use-after-free
- Invalid pointer dereferences
- Stack corruption

## Next Steps

1. Add extensive logging to `checkModule` to narrow down exact location
2. Run under memory sanitizer
3. Check all ArrayList/HashMap operations for size calculations
4. Verify allocator usage is consistent (same allocator for alloc/free)
5. Check for any manual pointer arithmetic

## Date

2025-06-25
