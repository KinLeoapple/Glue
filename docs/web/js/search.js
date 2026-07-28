// docs/web/js/search.js — 全文检索

let searchIndex = [];
let selectedIndex = 0;

// 构建搜索索引：遍历 CONTENT 的所有 chapter/section
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
        });

        // section 级别
        if (data.sections) {
            Object.entries(data.sections).forEach(([secId, sec]) => {
                searchIndex.push({
                    title: sec.title,
                    path: `#/${ch.id}/${secId}`,
                    chapter: ch.title,
                });
            });
        }

        // intro 中的 h3
        if (data.intro) {
            data.intro.forEach(block => {
                if (block.type === 'h3') {
                    searchIndex.push({
                        title: block.text,
                        path: `#/${ch.id}#${block.id}`,
                        chapter: ch.title,
                    });
                }
            });
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
        item.chapter.toLowerCase().includes(q)
    ).slice(0, 20);

    if (results.length === 0) {
        container.innerHTML = '<div class="search-result" style="color:var(--text-muted)">无匹配结果</div>';
        return;
    }

    container.innerHTML = results.map((r, i) => {
        const title = highlightMatch(r.title, q);
        return `<div class="search-result ${i === selectedIndex ? 'selected' : ''}" data-path="${r.path}" data-index="${i}">
            <div class="search-result-title">${title}</div>
            <div class="search-result-path">${r.chapter}</div>
        </div>`;
    }).join('');

    // 绑定点击
    container.querySelectorAll('.search-result').forEach(el => {
        el.onclick = () => {
            location.hash = el.dataset.path;
            closeSearch();
        };
    });
}

function highlightMatch(text, query) {
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
}
