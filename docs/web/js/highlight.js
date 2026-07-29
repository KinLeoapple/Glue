// docs/web/js/highlight.js — Glue 语法高亮 tokenizer

const GLUE_KEYWORDS = new Set([
    'fun', 'async', 'type', 'trait', 'override', 'pack', 'pub', 'import', 'with', 'as',
    'val', 'var',
    'match', 'if', 'else',
    'channel', 'select', 'atomic',
    'loop', 'for', 'in', 'while', 'break', 'continue', 'return',
    'true', 'false', 'null',
    'throw', 'defer', 'lazy',
]);

const GLUE_TYPES = new Set([
    'i8', 'i16', 'i32', 'i64', 'i128', 'isize',
    'u8', 'u16', 'u32', 'u64', 'u128', 'usize',
    'f16', 'f32', 'f64', 'f128',
    'bool', 'char', 'str', 'void',
    'Self',
]);

const GLUE_BUILTINS = new Set([
    'println', 'print', 'eprintln', 'eprint', 'scanln', 'scan',
    'cast', 'str', 'type', 'Panic', 'Ok', 'Error', 'CastError',
    'channel', 'atomic', 'timeout',
]);

// 将代码字符串转为 HTML（含 span 高亮）
function highlightGlue(code) {
    let result = '';
    let i = 0;
    while (i < code.length) {
        const ch = code[i];

        // 注释 // 单行
        if (ch === '/' && code[i + 1] === '/') {
            let end = code.indexOf('\n', i);
            if (end === -1) end = code.length;
            result += `<span class="tok-comment">${escapeHtml(code.slice(i, end))}</span>`;
            i = end;
            continue;
        }

        // 注释 /* */ 多行（支持嵌套）
        if (ch === '/' && code[i + 1] === '*') {
            let depth = 1, j = i + 2;
            while (j < code.length && depth > 0) {
                if (code[j] === '/' && code[j + 1] === '*') { depth++; j += 2; }
                else if (code[j] === '*' && code[j + 1] === '/') { depth--; j += 2; }
                else { j++; }
            }
            result += `<span class="tok-comment">${escapeHtml(code.slice(i, j))}</span>`;
            i = j;
            continue;
        }

        // 字符串 "..." 含插值 {expr}
        if (ch === '"') {
            let j = i + 1;
            result += '<span class="tok-string">"';
            while (j < code.length && code[j] !== '"') {
                if (code[j] === '\\' && j + 1 < code.length) {
                    result += escapeHtml(code.slice(j, j + 2));
                    j += 2;
                } else if (code[j] === '{' && code[j + 1] !== '{') {
                    // 插值开始：先关闭 string span
                    result += '</span>';
                    let braceDepth = 1, k = j + 1;
                    while (k < code.length && braceDepth > 0) {
                        if (code[k] === '{') braceDepth++;
                        else if (code[k] === '}') { braceDepth--; if (braceDepth === 0) break; }
                        k++;
                    }
                    result += `<span class="tok-interp">{</span>`;
                    result += highlightGlue(code.slice(j + 1, k));
                    result += `<span class="tok-interp">}</span>`;
                    result += '<span class="tok-string">';
                    j = k + 1;
                } else {
                    result += escapeHtml(code[j]);
                    j++;
                }
            }
            result += '"</span>';
            i = j + 1;
            continue;
        }

        // 字符 '...'
        if (ch === "'" && code[i + 1] !== '') {
            // 匹配 'x' 或 '\x' 或 '\u{...}'
            let j = i + 1;
            if (code[j] === '\\') {
                j++;
                if (code[j] === 'u' && code[j + 1] === '{') {
                    j = code.indexOf('}', j) + 1;
                } else { j++; }
            } else { j++; }
            if (code[j] === "'") {
                result += `<span class="tok-char">${escapeHtml(code.slice(i, j + 1))}</span>`;
                i = j + 1;
                continue;
            }
        }

        // 数字
        if (/[0-9]/.test(ch)) {
            let j = i;
            // 前缀 0x 0o 0b
            if (ch === '0' && /[xob]/.test(code[j + 1])) {
                j += 2;
                while (j < code.length && /[0-9a-fA-F_]/.test(code[j])) j++;
            } else {
                while (j < code.length && /[0-9_]/.test(code[j])) j++;
                if (code[j] === '.' && /[0-9]/.test(code[j + 1])) {
                    j++;
                    while (j < code.length && /[0-9_]/.test(code[j])) j++;
                }
            }
            // 类型后缀
            while (j < code.length && /[a-zA-Z0-9]/.test(code[j])) j++;
            result += `<span class="tok-number">${escapeHtml(code.slice(i, j))}</span>`;
            i = j;
            continue;
        }

        // 标识符 / 关键字 / 类型
        if (/[a-zA-Z_]/.test(ch)) {
            let j = i;
            while (j < code.length && /[a-zA-Z0-9_]/.test(code[j])) j++;
            const word = code.slice(i, j);
            if (GLUE_KEYWORDS.has(word)) {
                result += `<span class="tok-keyword">${word}</span>`;
            } else if (GLUE_TYPES.has(word)) {
                result += `<span class="tok-type">${word}</span>`;
            } else if (GLUE_BUILTINS.has(word)) {
                result += `<span class="tok-builtin">${word}</span>`;
            } else if (/^[A-Z]/.test(word)) {
                // 大写开头：类型名或构造器
                result += `<span class="tok-type">${word}</span>`;
            } else if (code[j] === '(') {
                // 后跟括号：函数调用
                result += `<span class="tok-fn">${word}</span>`;
            } else {
                result += word;
            }
            i = j;
            continue;
        }

        // 其他字符直接输出
        result += escapeHtml(ch);
        i++;
    }
    return result;
}

function escapeHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
