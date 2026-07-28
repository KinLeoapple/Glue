// docs/web/js/search.js — 全文检索（优化版：含正文索引 + 预览）

let searchIndex = [];
let selectedIndex = 0;

// 提取 block 中的纯文本
function blockToText(block) {
    switch (block.type) {
        case 'p': return block.text;
        case 'ul':
        case 'ol': return block.items.join(' ');
        case 'table':
            return block.headers.join(' ') + ' ' + block.rows.map(r => r.join(' ')).join(' ');
        case 'tip':
        case 'info':
        case 'warn': return block.text;
        case 'code': return block.code;
        case 'h3': return block.text;
        case 'quote': return block.text;
        default: return '';
    }
}

// 构建搜索索引：遍历 CONTENT 的所有 chapter/section + 正文内容
function buildSearchIndex() {
    searchIndex = [];
    CHAPTERS.forEach(ch => {
        if (ch.id === 'home') return;
        const data = CONTENT[ch.id];
        if (!data) return;

        // chapter 级别
        searchIndex.push({
            title: data.title || ch.title,
            path: `#/${ch.id}`,
            chapter: ch.title,
            preview: '',
        });

        // section 级别 + 正文内容索引
        if (data.sections) {
            Object.entries(data.sections).forEach(([secId, sec]) => {
                // 收集该 section 的正文文本
                const fullText = (sec.blocks || []).map(blockToText).join(' ');
                searchIndex.push({
                    title: sec.title,
                    path: `#/${ch.id}/${secId}`,
                    chapter: ch.title,
                    preview: fullText,
                });
            });
        }

        // intro 中的 h3 + 后续内容
        if (data.intro) {
            let currentH3 = null;
            let currentText = [];
            data.intro.forEach(block => {
                if (block.type === 'h3') {
                    if (currentH3) {
                        searchIndex.push({
                            title: currentH3,
                            path: `#/${ch.id}#${block.id || ''}`,
                            chapter: ch.title,
                            preview: currentText.join(' '),
                        });
                    }
                    currentH3 = block.text;
                    currentText = [];
                } else {
                    currentText.push(blockToText(block));
                }
            });
            if (currentH3) {
                searchIndex.push({
                    title: currentH3,
                    path: `#/${ch.id}`,
                    chapter: ch.title,
                    preview: currentText.join(' '),
                });
            }
        }
    });
}

function openSearch() {
    const modal = document.getElementById('search-modal');
    const input = document.getElementById('search-input');
    modal.classList.add('active');
    input.value = '';
    input.focus();
    selectedIndex = 0;
    renderSearchResults('');
}

function closeSearch() {
    document.getElementById('search-modal').classList.remove('active');
}

function renderSearchResults(query) {
    const container = document.getElementById('search-results');
    if (!query) {
        container.innerHTML = '';
        return;
    }

    const q = query.toLowerCase();
    const results = searchIndex.filter(item =>
        item.title.toLowerCase().includes(q) ||
        item.chapter.toLowerCase().includes(q) ||
        (item.preview && item.preview.toLowerCase().includes(q))
    ).slice(0, 20);

    if (results.length === 0) {
        const emptyMsg = typeof t !== 'undefined' ? t('search_empty') : '无匹配结果';
        container.innerHTML = `<div class="search-result search-empty"><span class="search-empty-icon"></span>${emptyMsg}</div>`;
        const emptyIcon = container.querySelector('.search-empty-icon');
        if (emptyIcon && typeof ICONS !== 'undefined') emptyIcon.innerHTML = ICONS.alertCircle;
        return;
    }

    container.innerHTML = results.map((r, i) => {
        const title = highlightMatch(r.title, q);
        // 提取匹配上下文作为预览
        let preview = '';
        if (r.preview) {
            const lowerPreview = r.preview.toLowerCase();
            const matchIdx = lowerPreview.indexOf(q);
            if (matchIdx !== -1) {
                const start = Math.max(0, matchIdx - 30);
                const end = Math.min(r.preview.length, matchIdx + q.length + 50);
                preview = (start > 0 ? '...' : '') + r.preview.slice(start, end) + (end < r.preview.length ? '...' : '');
                preview = highlightMatch(preview, q);
            }
        }
        return `<div class="search-result ${i === selectedIndex ? 'selected' : ''}" data-path="${r.path}" data-index="${i}" role="option">
            <span class="search-result-icon"></span>
            <div class="search-result-content">
                <div class="search-result-title">${title}</div>
                <div class="search-result-path">${r.chapter}</div>
                ${preview ? `<div class="search-result-preview">${preview}</div>` : ''}
            </div>
            <span class="search-result-arrow"></span>
        </div>`;
    }).join('');

    // 注入图标
    if (typeof ICONS !== 'undefined') {
        container.querySelectorAll('.search-result-icon').forEach(el => el.innerHTML = ICONS.hash);
        container.querySelectorAll('.search-result-arrow').forEach(el => el.innerHTML = ICONS.chevronRight);
    }

    // 绑定点击
    container.querySelectorAll('.search-result').forEach(el => {
        el.onclick = () => {
            location.hash = el.dataset.path;
            closeSearch();
        };
    });
}

function highlightMatch(text, query) {
    if (!text) return text;
    const idx = text.toLowerCase().indexOf(query);
    if (idx === -1) return text;
    return text.slice(0, idx) +
           `<mark>${text.slice(idx, idx + query.length)}</mark>` +
           text.slice(idx + query.length);
}

// 搜索输入
document.addEventListener('DOMContentLoaded', () => {
    buildSearchIndex();

    document.getElementById('search-input').addEventListener('input', e => {
        selectedIndex = 0;
        renderSearchResults(e.target.value);
    });

    // 搜索触发按钮
    document.getElementById('search-trigger').onclick = openSearch;

    // 点击模态背景关闭
    document.getElementById('search-modal').addEventListener('click', e => {
        if (e.target.id === 'search-modal') closeSearch();
    });

    // 键盘快捷键
    document.addEventListener('keydown', e => {
        if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
            e.preventDefault();
            const modal = document.getElementById('search-modal');
            if (modal.classList.contains('active')) closeSearch();
            else openSearch();
        }
        if (e.key === 'Escape') closeSearch();

        // 搜索结果导航
        const modal = document.getElementById('search-modal');
        if (modal.classList.contains('active')) {
            const results = document.querySelectorAll('.search-result');
            if (e.key === 'ArrowDown') {
                e.preventDefault();
                selectedIndex = Math.min(selectedIndex + 1, results.length - 1);
                updateSearchSelection();
            } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                selectedIndex = Math.max(selectedIndex - 1, 0);
                updateSearchSelection();
            } else if (e.key === 'Enter') {
                e.preventDefault();
                if (results[selectedIndex]) {
                    location.hash = results[selectedIndex].dataset.path;
                    closeSearch();
                }
            }
        }
    });
});

function updateSearchSelection() {
    document.querySelectorAll('.search-result').forEach((el, i) => {
        el.classList.toggle('selected', i === selectedIndex);
    });
    // 确保选中项可见
    const selected = document.querySelector('.search-result.selected');
    if (selected) {
        selected.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
}
