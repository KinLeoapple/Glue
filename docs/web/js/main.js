// docs/web/js/main.js — Glue 文档站主逻辑（优化版）

// === SVG 图标库 ===
const ICONS = {
    search: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="7" cy="7" r="5"/><path d="M11 11l3 3" stroke-linecap="round"/></svg>',
    github: '<svg viewBox="0 0 16 16" width="16" height="16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>',
    menu: '<svg viewBox="0 0 16 16" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M2 4h12M2 8h12M2 12h12"/></svg>',
    book: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M3 2v12c0-.55.45-1 1-1h3a2 2 0 012 2v-9a2 2 0 00-2-2H4c-.55 0-1 .45-1 1z"/><path d="M13 2v12c0-.55-.45-1-1-1H9a2 2 0 00-2 2v-9a2 2 0 012-2h3c.55 0 1 .45 1 1z"/></svg>',
    arrowRight: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8h10M9 4l4 4-4 4"/></svg>',
    chevronDown: '<svg viewBox="0 0 16 16" width="10" height="10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6l4 4 4-4"/></svg>',
    shield: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2l8 3v6c0 5-3.5 8.5-8 11-4.5-2.5-8-6-8-11V5l8-3z"/><path d="M9 12l2 2 4-4"/></svg>',
    alertCircle: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 8v4M12 16h.01"/></svg>',
    package: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2l9 5v10l-9 5-9-5V7l9-5z"/><path d="M3.5 7L12 12l8.5-5M12 12v10"/></svg>',
    info: '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/></svg>',
    lightbulb: '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18h6M10 21h4M12 2a7 7 0 00-4 12.7c.6.5 1 1.3 1 2.1V17h6v-.2c0-.8.4-1.6 1-2.1A7 7 0 0012 2z"/></svg>',
    warning: '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l9 16H3L12 3z"/><path d="M12 10v4M12 17h.01"/></svg>',
    arrowUp: '<svg viewBox="0 0 16 16" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 13V3M4 7l4-4 4 4"/></svg>',
    play: '<svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor"><path d="M4 3v10l8-5z"/></svg>',
    terminal: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><rect x="1.5" y="2.5" width="13" height="11" rx="1.5"/><path d="M4 6l2 2-2 2M8 10h3"/></svg>',
    copy: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="5" width="9" height="9" rx="1.5"/><path d="M3 11V3.5A1.5 1.5 0 014.5 2H11"/></svg>',
    check: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8l3.5 3.5L13 4"/></svg>',
    externalLink: '<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M9 2h5v5M14 2L8 8M11 9v4.5A1.5 1.5 0 019.5 15h-7A1.5 1.5 0 011 13.5v-7A1.5 1.5 0 012.5 5H7"/></svg>',
    zap: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M9 1L2 9h5l-1 6 7-8H8l1-6z"/></svg>',
    layers: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M8 1l7 4-7 4-7-4 7-4z"/><path d="M1 9l7 4 7-4M1 12.5l7 4 7-4"/></svg>',
    hash: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h10M3 10h10M6 2L4 14M12 2l-2 12"/></svg>',
    list: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M6 4h8M6 8h8M6 12h8M3 4h.01M3 8h.01M3 12h.01"/></svg>',
    compass: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="6.5"/><path d="M10.5 5.5l-2 4-4 2 2-4 4-2z"/></svg>',
    gitBranch: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><circle cx="4" cy="3" r="1.5"/><circle cx="4" cy="13" r="1.5"/><circle cx="12" cy="6" r="1.5"/><path d="M4 4.5v7M12 7.5c0 3-4 1.5-4 3.5"/></svg>',
    rocket: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M10 1c2 0 4 1 5 3-1 4-3 6-6 7l-3-3c1-3 3-6 4-7z"/><path d="M6 8L3 9l-1 3 2-1M9 11l-1 3-3 1 1-2"/><circle cx="11" cy="5" r="1"/></svg>',
    database: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="8" cy="3.5" rx="5.5" ry="2"/><path d="M2.5 3.5v9c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2v-9M2.5 8c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2"/></svg>',
    cpu: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="8" height="8" rx="1"/><path d="M6 1v2M10 1v2M6 13v2M10 13v2M1 6h2M1 10h2M13 6h2M13 10h2"/></svg>',
    globe: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="6.5"/><path d="M1.5 8h13M8 1.5c2 2 2 9 0 13M8 1.5c-2 2-2 9 0 13"/></svg>',
    chevronRight: '<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6 4l4 4-4 4"/></svg>',
    x: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8"/></svg>',
};

// === 全局状态 ===
let heroAnimTimer = null;
let scrollProgressEl = null;
let backToTopEl = null;
let psTrack = null;
let psThumb = null;
let psDragState = null;
let psHideTimer = null;

// === 平台检测 ===
let detectedPlatform = 'mac';

function detectPlatform() {
    const ua = navigator.userAgent.toLowerCase();
    if (ua.includes('win')) return 'windows';
    if (ua.includes('linux')) return 'linux';
    return 'mac';
}

// 根据平台返回代码块窗口控制按钮 HTML
function platformWindowDots() {
    if (detectedPlatform === 'windows') {
        // Windows 风格：最小化 / 最大化 / 关闭
        return `<div class="code-dots code-dots-win">
            <span class="win-btn win-min"><svg viewBox="0 0 12 12" width="10" height="10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M2 6h8"/></svg></span>
            <span class="win-btn win-max"><svg viewBox="0 0 12 12" width="10" height="10" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="2" y="2" width="8" height="8" rx="1"/></svg></span>
            <span class="win-btn win-close"><svg viewBox="0 0 12 12" width="10" height="10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M3 3l6 6M9 3l-6 6"/></svg></span>
        </div>`;
    }
    if (detectedPlatform === 'linux') {
        // Linux 风格：简约圆点（灰度）
        return `<div class="code-dots code-dots-linux">
            <span class="lin-dot"></span><span class="lin-dot"></span><span class="lin-dot"></span>
        </div>`;
    }
    // macOS 风格：红黄绿交通灯（默认）
    return `<div class="code-dots">
        <span class="red"></span><span class="yellow"></span><span class="green"></span>
    </div>`;
}

// ═══════════════════════════════════════════
// Part 1: 侧栏渲染
// ═══════════════════════════════════════════

function renderSidebar() {
    const nav = document.getElementById('sidebar-nav');
    nav.innerHTML = '';

    const groups = ['tutorial', 'reference'];

    groups.forEach((group, gi) => {
        if (gi > 0) {
            const divider = document.createElement('div');
            divider.className = 'sidebar-divider';
            nav.appendChild(divider);
        }

        const label = document.createElement('div');
        label.className = 'sidebar-group-label';
        label.textContent = tGroupLabel(group);
        nav.appendChild(label);

        CHAPTERS.filter(c => c.group === group).forEach(ch => {
            const section = document.createElement('div');
            section.className = 'sidebar-section';

            if (ch.sections.length > 0) {
                const toggle = document.createElement('div');
                toggle.className = 'sidebar-toggle';
                toggle.setAttribute('role', 'button');
                toggle.setAttribute('tabindex', '0');
                toggle.setAttribute('aria-expanded', 'true');
                toggle.innerHTML = `<span class="arrow">${ICONS.chevronDown}</span> ${tChapter(ch.id)}`;
                toggle.dataset.chapter = ch.id;

                const toggleSection = () => {
                    const children = section.querySelector('.sidebar-children');
                    const isCollapsed = children.classList.toggle('collapsed');
                    toggle.classList.toggle('collapsed', isCollapsed);
                    toggle.setAttribute('aria-expanded', !isCollapsed);
                };

                toggle.onclick = toggleSection;
                toggle.onkeydown = e => {
                    if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault();
                        toggleSection();
                    }
                };
                section.appendChild(toggle);

                const children = document.createElement('div');
                children.className = 'sidebar-children';
                ch.sections.forEach(sec => {
                    const item = document.createElement('a');
                    item.className = 'sidebar-item';
                    item.href = `#/${ch.id}/${sec.id}`;
                    item.dataset.chapter = ch.id;
                    item.dataset.section = sec.id;
                    item.textContent = tSection(ch.id, sec.id);
                    item.setAttribute('role', 'treeitem');
                    children.appendChild(item);
                });
                section.appendChild(children);
            } else {
                const item = document.createElement('a');
                item.className = 'sidebar-item';
                item.href = `#/${ch.id}`;
                item.dataset.chapter = ch.id;
                item.textContent = tChapter(ch.id);
                item.setAttribute('role', 'treeitem');
                section.appendChild(item);
            }

            nav.appendChild(section);
        });
    });
}

// 自动展开当前章节的侧栏分组
function autoExpandSidebar(chapter) {
    document.querySelectorAll('.sidebar-toggle').forEach(toggle => {
        if (toggle.dataset.chapter === chapter) {
            const children = toggle.nextElementSibling;
            if (children && children.classList.contains('collapsed')) {
                children.classList.remove('collapsed');
                toggle.classList.remove('collapsed');
                toggle.setAttribute('aria-expanded', 'true');
            }
        }
    });

    // 滚动侧栏到激活项
    setTimeout(() => {
        const active = document.querySelector('.sidebar-item.active');
        if (active) {
            active.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
        }
    }, 100);
}

// ═══════════════════════════════════════════
// Part 2: 路由
// ═══════════════════════════════════════════

function getRoute() {
    const hash = location.hash.slice(1);
    if (!hash || hash === '/') return { chapter: 'home', section: null };
    const parts = hash.slice(1).split('/');
    return { chapter: parts[0] || 'home', section: parts[1] || null };
}

function navigate() {
    const { chapter, section } = getRoute();
    updateActiveSidebar(chapter, section);
    autoExpandSidebar(chapter);
    renderContent(chapter, section);

    // 平滑滚动到顶部
    window.scrollTo({ top: 0, behavior: 'smooth' });

    // 内容切换后刷新自建滚动条尺寸
    requestAnimationFrame(() => { psUpdate(); refreshInnerScrollbars(); });
    setTimeout(() => { psUpdate(); refreshInnerScrollbars(); }, 300);
}

function updateActiveSidebar(chapter, section) {
    document.querySelectorAll('.sidebar-item').forEach(item => {
        item.classList.remove('active');
        if (section) {
            if (item.dataset.chapter === chapter && item.dataset.section === section) {
                item.classList.add('active');
            }
        } else {
            if (item.dataset.chapter === chapter && !item.dataset.section) {
                item.classList.add('active');
            }
        }
    });
}

// ═══════════════════════════════════════════
// Part 3: 内容渲染
// ═══════════════════════════════════════════

function renderContent(chapter, section) {
    const content = document.getElementById('content');
    const data = CONTENT[chapter];

    if (chapter === 'home') {
        content.innerHTML = renderHome();
        initHeroAnimation();
        return;
    }

    if (!data) {
        content.innerHTML = `<h1>${t('not_found_title')}</h1><p>${t('not_found_desc')}</p>`;
        return;
    }

    let html = '';
    if (section && data.sections && data.sections[section]) {
        html = `<h1>${tSection(chapter, section)}</h1>`;
        html += renderBlocks(data.sections[section].blocks);
    } else {
        html = `<h1>${tChapter(chapter)}</h1>`;
        if (data.intro) html += renderBlocks(data.intro);
        if (data.sections) {
            const order = data.sectionOrder || Object.keys(data.sections);
            order.forEach(secId => {
                const sec = data.sections[secId];
                html += `<h2 id="${secId}">${tSection(chapter, secId)}</h2>`;
                html += renderBlocks(sec.blocks);
            });
        }
    }
    content.innerHTML = html;
}

function renderBlocks(blocks) {
    if (!blocks) return '';
    return blocks.map(renderBlock).join('');
}

function renderBlock(block) {
    switch (block.type) {
        case 'p':   return `<p>${inline(block.text)}</p>`;
        case 'h3':  return `<h3 id="${block.id || ''}">${block.text}</h3>`;
        case 'code': return renderCodeBlock(block.code, block.filename, block.snippet);
        case 'ul':  return `<ul>${block.items.map(i => `<li>${inline(i)}</li>`).join('')}</ul>`;
        case 'ol':  return `<ol>${block.items.map(i => `<li>${inline(i)}</li>`).join('')}</ol>`;
        case 'table': return renderTable(block);
        case 'tip': return renderCallout(block, 'tip');
        case 'info':return renderCallout(block, 'info');
        case 'warn':return renderCallout(block, 'warn');
        case 'quote':return `<blockquote>${inline(block.text)}</blockquote>`;
        default: return '';
    }
}

function renderTable(block) {
    let html = '<div class="table-wrap"><table><thead><tr>';
    html += block.headers.map(h => `<th>${inline(h)}</th>`).join('');
    html += '</tr></thead><tbody>';
    block.rows.forEach(row => {
        html += '<tr>' + row.map(c => `<td>${inline(c)}</td>`).join('') + '</tr>';
    });
    html += '</tbody></table></div>';
    return html;
}

function renderCallout(block, kind) {
    const iconMap = { tip: 'lightbulb', info: 'info', warn: 'warning' };
    const labelKey = { tip: 'callout_tip', info: 'callout_info', warn: 'callout_warn' };
    const icon = ICONS[iconMap[kind] || 'info'];
    const label = t(labelKey[kind] || 'callout_info');
    return `<div class="callout callout-${kind}"><span class="callout-icon">${icon}</span><div class="callout-body"><span class="callout-label">${label}</span>${inline(block.text)}</div></div>`;
}

// 内联格式：`code` → <code class="inline">，**bold** → <strong>
function inline(text) {
    return text
        .replace(/`([^`]+)`/g, '<code class="inline">$1</code>')
        .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
}

// ═══════════════════════════════════════════
// Part 4: 导航下拉菜单
// ═══════════════════════════════════════════

function renderNavMenus() {
    const tutMenu = document.getElementById('nav-tutorial');
    const refMenu = document.getElementById('nav-reference');
    tutMenu.innerHTML = '<div class="nav-menu-inner"></div>';
    refMenu.innerHTML = '<div class="nav-menu-inner"></div>';
    const tutInner = tutMenu.querySelector('.nav-menu-inner');
    const refInner = refMenu.querySelector('.nav-menu-inner');
    CHAPTERS.forEach(ch => {
        const a = document.createElement('a');
        a.textContent = tChapter(ch.id);
        a.href = `#/${ch.id}`;
        a.setAttribute('role', 'menuitem');
        if (ch.group === 'tutorial') tutInner.appendChild(a);
        else refInner.appendChild(a);
    });
}

// ═══════════════════════════════════════════
// Part 4b: 静态 HTML 元素图标注入
// ═══════════════════════════════════════════

function initNavIcons() {
    // 搜索触发按钮
    const searchTrigger = document.getElementById('search-trigger');
    if (searchTrigger && !searchTrigger.dataset.iconInit) {
        searchTrigger.dataset.iconInit = '1';
        searchTrigger.insertAdjacentHTML('afterbegin', `<span class="nav-icon">${ICONS.search}</span>`);
    }

    // GitHub 链接 — 纯图标，无文字
    const githubLink = document.querySelector('.github-link');
    if (githubLink && !githubLink.dataset.iconInit) {
        githubLink.dataset.iconInit = '1';
        githubLink.innerHTML = `<span class="nav-icon">${ICONS.github}</span>`;
    }

    // 导航下拉按钮 — 替换 ▾ 为 chevronDown 图标
    document.querySelectorAll('.nav-btn').forEach(btn => {
        if (btn.dataset.iconInit) return;
        btn.dataset.iconInit = '1';
        btn.innerHTML = btn.innerHTML.replace(' ▾', ` <span class="nav-chevron">${ICONS.chevronDown}</span>`);
    });

    // 汉堡菜单
    const menuToggle = document.getElementById('menu-toggle');
    if (menuToggle && !menuToggle.dataset.iconInit) {
        menuToggle.dataset.iconInit = '1';
        menuToggle.innerHTML = ICONS.menu;
    }

    // 回到顶部
    const backToTop = document.getElementById('back-to-top');
    if (backToTop && !backToTop.dataset.iconInit) {
        backToTop.dataset.iconInit = '1';
        backToTop.innerHTML = ICONS.arrowUp;
    }

    // 搜索框图标
    const searchInputIcon = document.getElementById('search-input-icon');
    if (searchInputIcon && !searchInputIcon.dataset.iconInit) {
        searchInputIcon.dataset.iconInit = '1';
        searchInputIcon.innerHTML = ICONS.search;
    }

    // 搜索关闭按钮
    const searchClose = document.getElementById('search-close');
    if (searchClose && !searchClose.dataset.iconInit) {
        searchClose.dataset.iconInit = '1';
        searchClose.innerHTML = ICONS.x;
        searchClose.onclick = closeSearch;
    }
}

// ═══════════════════════════════════════════
// Part 5: 代码块渲染
// ═══════════════════════════════════════════

function renderCodeBlock(code, filename, snippet) {
    const id = 'code-' + Math.random().toString(36).slice(2, 11);
    const fn = filename || 'example.glue';
    const dots = platformWindowDots();
    const isWin = detectedPlatform === 'windows';

    // snippet 折叠模式：折叠显示关键片段，展开显示完整可执行代码
    const hasSnippet = snippet && snippet.trim().length > 0;

    // 复制按钮始终复制完整代码
    const copyTargetId = hasSnippet ? 'full-' + id : id;
    const copyBtn = `<button class="copy-btn" data-code-id="${copyTargetId}" aria-label="${t('code_copy')}"><span class="copy-icon">${ICONS.copy}</span><span class="copy-text">${t('code_copy')}</span></button>`;

    const dotsLeft = isWin ? '' : dots;
    const dotsRight = isWin ? dots : '';
    const copyLeft = isWin ? copyBtn : '';
    const copyRight = isWin ? '' : copyBtn;

    if (hasSnippet) {
        // 折叠态：显示 snippet；展开态：显示完整 code
        const snippetHtml = highlightGlue(snippet);
        const fullHtml = highlightGlue(code);
        const expandBtn = `<button class="code-expand-btn" data-block-id="block-${id}" aria-label="${t('code_expand')}"><span class="chevron">${ICONS.chevronDown}</span><span class="expand-text">${t('code_expand')}</span></button>`;
        return `
        <div class="code-block collapsible" id="block-${id}">
            <div class="code-header">
                ${dotsLeft}
                ${copyLeft}
                <span class="code-filename">${ICONS.terminal} ${fn}</span>
                ${copyRight}
                ${dotsRight}
            </div>
            <div class="code-body">
                <pre id="${id}" class="code-snippet">${snippetHtml}</pre>
                <pre id="full-${id}" class="code-full" style="display:none">${fullHtml}</pre>
            </div>
            ${expandBtn}
        </div>`;
    }

    // 无 snippet：普通渲染，不折叠
    const highlighted = highlightGlue(code);
    return `
        <div class="code-block">
            <div class="code-header">
                ${dotsLeft}
                ${copyLeft}
                <span class="code-filename">${ICONS.terminal} ${fn}</span>
                ${copyRight}
                ${dotsRight}
            </div>
            <div class="code-body">
                <pre id="${id}">${highlighted}</pre>
            </div>
        </div>`;
}

// 统一绑定复制按钮（事件委托）
function initCopyButtons() {
    document.addEventListener('click', e => {
        const btn = e.target.closest('.copy-btn');
        if (!btn) return;
        const pre = document.getElementById(btn.dataset.codeId);
        if (!pre) return;
        const text = pre.textContent;
        navigator.clipboard.writeText(text).then(() => {
            const icon = btn.querySelector('.copy-icon');
            const txt = btn.querySelector('.copy-text');
            if (icon) icon.innerHTML = ICONS.check;
            if (txt) txt.textContent = t('code_copied');
            btn.classList.add('copied');
            setTimeout(() => {
                if (icon) icon.innerHTML = ICONS.copy;
                if (txt) txt.textContent = t('code_copy');
                btn.classList.remove('copied');
            }, 1500);
        });
    });
}

// snippet 折叠/展开（事件委托）：切换 snippet / full pre 显隐
function initExpandButtons() {
    document.addEventListener('click', e => {
        const btn = e.target.closest('.code-expand-btn');
        if (!btn) return;
        const block = document.getElementById(btn.dataset.blockId);
        if (!block) return;
        const snippetPre = block.querySelector('.code-snippet');
        const fullPre = block.querySelector('.code-full');
        if (!snippetPre || !fullPre) return;
        const expanded = block.classList.toggle('expanded');
        snippetPre.style.display = expanded ? 'none' : 'block';
        fullPre.style.display = expanded ? 'block' : 'none';
        const txt = btn.querySelector('.expand-text');
        if (txt) txt.textContent = expanded ? t('code_collapse') : t('code_expand');
    });
}

// ═══════════════════════════════════════════
// Part 6: 首页 Hero
// ═══════════════════════════════════════════

function renderHome() {
    return `
    <div class="hero">
        <div class="hero-title">▸ Glue<span class="hero-cursor"></span></div>
        <div class="hero-tagline">${t('hero_tagline')}</div>
        <div class="hero-tagline-sub">${t('hero_tagline_sub')}</div>
        <div class="hero-cta">
            <a href="#/start/what" class="cta-btn cta-primary">${ICONS.play} ${t('hero_cta_start')}</a>
            <a href="#/r1-cheatsheet" class="cta-btn cta-secondary">${ICONS.book} ${t('hero_cta_cheatsheet')}</a>
            <a href="https://github.com" class="cta-btn cta-ghost" target="_blank" rel="noopener">${ICONS.github} ${t('hero_cta_github')}</a>
        </div>
        <div class="hero-terminal">
            ${renderCodeBlock('$ glue init app\n  created src/Main.glue\n  created glue.toml\n$ cd app\n$ glue run\nHello, Glue!', '~/app')}
        </div>
        <div class="hero-features">
            <div class="feature-card">
                <div class="feature-icon">${ICONS.shield}</div>
                <div class="feature-title">${t('feature_safety_title')}</div>
                <div class="feature-desc">${t('feature_safety_desc')}</div>
            </div>
            <div class="feature-card">
                <div class="feature-icon">${ICONS.alertCircle}</div>
                <div class="feature-title">${t('feature_error_title')}</div>
                <div class="feature-desc">${t('feature_error_desc')}</div>
            </div>
            <div class="feature-card">
                <div class="feature-icon">${ICONS.package}</div>
                <div class="feature-title">${t('feature_stdlib_title')}</div>
                <div class="feature-desc">${t('feature_stdlib_desc')}</div>
            </div>
            <div class="feature-card">
                <div class="feature-icon">${ICONS.zap}</div>
                <div class="feature-title">${t('feature_zero_title')}</div>
                <div class="feature-desc">${t('feature_zero_desc')}</div>
            </div>
        </div>
    </div>`;
}

function initHeroAnimation() {
    // 清除之前的定时器，防止泄漏
    if (heroAnimTimer) {
        clearInterval(heroAnimTimer);
        heroAnimTimer = null;
    }

    const term = document.querySelector('.hero-terminal pre');
    if (!term) return;

    const lines = [
        '$ glue init app',
        '  created src/Main.glue',
        '  created glue.toml',
        '$ cd app',
        '$ glue run',
        'Hello, Glue!',
    ];
    const text = lines.join('\n');
    let idx = 0;
    term.textContent = '';

    heroAnimTimer = setInterval(() => {
        if (idx >= text.length) {
            clearInterval(heroAnimTimer);
            heroAnimTimer = null;
            return;
        }
        idx += 2;
        term.textContent = text.slice(0, idx);
    }, 25);
}

// ═══════════════════════════════════════════
// Part 7: 滚动进度 + 回到顶部
// ═══════════════════════════════════════════

function initScrollFeatures() {
    scrollProgressEl = document.getElementById('scroll-progress');
    backToTopEl = document.getElementById('back-to-top');

    const onScroll = () => {
        const scrollTop = window.scrollY;
        const docHeight = document.documentElement.scrollHeight - window.innerHeight;
        const progress = docHeight > 0 ? (scrollTop / docHeight) * 100 : 0;
        scrollProgressEl.style.width = progress + '%';

        if (scrollTop > 400) {
            backToTopEl.classList.add('visible');
        } else {
            backToTopEl.classList.remove('visible');
        }
    };

    window.addEventListener('scroll', onScroll, { passive: true });

    backToTopEl.onclick = () => {
        window.scrollTo({ top: 0, behavior: 'smooth' });
    };
}

// ═══════════════════════════════════════════
// Part 7b: 自建滚动条 — PerfectScrollbar 风格
//   HTML: .ps-track > .ps-thumb（显示）
//   CSS:  轨道/滑块样式 + 过渡（样式）
//   JS:   滚动同步 / 拖拽 / 空闲淡出（行为）
// ═══════════════════════════════════════════

function initCustomScrollbar() {
    // 创建 DOM 结构
    psTrack = document.createElement('div');
    psTrack.className = 'ps-track';
    psThumb = document.createElement('div');
    psThumb.className = 'ps-thumb';
    psTrack.appendChild(psThumb);
    document.body.appendChild(psTrack);

    psUpdate();

    // 滚动 → 更新位置 + 显示，停止后淡出
    window.addEventListener('scroll', () => {
        psUpdate();
        psShow();
        psScheduleHide();
    }, { passive: true });

    window.addEventListener('resize', psUpdate);

    // 监听内容高度变化（路由切换、图片加载等）
    if (window.ResizeObserver) {
        const ro = new ResizeObserver(psUpdate);
        ro.observe(document.body);
        const contentEl = document.getElementById('content');
        if (contentEl) ro.observe(contentEl);
    }

    // 拖拽交互
    psThumb.addEventListener('mousedown', e => {
        e.preventDefault();
        psDragState = {
            startY: e.clientY,
            startScroll: window.scrollY,
            maxScroll: document.documentElement.scrollHeight - window.innerHeight,
        };
        psThumb.classList.add('dragging');
        document.body.style.userSelect = 'none';
        psShow();
    });

    document.addEventListener('mousemove', e => {
        if (!psDragState) return;
        const trackHeight = psTrack.clientHeight;
        const thumbHeight = psThumb.offsetHeight;
        const dy = e.clientY - psDragState.startY;
        const scrollableTrack = trackHeight - thumbHeight;
        if (scrollableTrack <= 0) return;
        const scrollableDoc = psDragState.maxScroll;
        const newScroll = psDragState.startScroll + (dy / scrollableTrack) * scrollableDoc;
        window.scrollTo(0, Math.max(0, Math.min(scrollableDoc, newScroll)));
    });

    document.addEventListener('mouseup', () => {
        if (!psDragState) return;
        psDragState = null;
        psThumb.classList.remove('dragging');
        document.body.style.userSelect = '';
        psScheduleHide();
    });
}

// 更新滑块尺寸与位置
function psUpdate() {
    if (!psTrack || !psThumb) return;

    const scrollTop = window.scrollY;
    const docHeight = document.documentElement.scrollHeight;
    const viewportHeight = window.innerHeight;
    const trackHeight = psTrack.clientHeight;
    const scrollable = docHeight - viewportHeight;

    // 内容不足一屏 → 隐藏
    if (scrollable <= 4) {
        psTrack.classList.add('hidden');
        return;
    }
    psTrack.classList.remove('hidden');

    // 滑块高度 ∝ 视口/文档
    const thumbHeight = Math.max(36, (viewportHeight / docHeight) * trackHeight);
    const scrollableTrack = trackHeight - thumbHeight;
    const thumbTop = scrollable > 0 ? (scrollTop / scrollable) * scrollableTrack : 0;

    psThumb.style.height = thumbHeight + 'px';
    psThumb.style.transform = `translateY(${thumbTop}px)`;
}

// 显示轨道（滚动中 / 悬停 / 拖拽），并在停止后淡出
function psShow() {
    if (psHideTimer) { clearTimeout(psHideTimer); psHideTimer = null; }
    psTrack.classList.add('visible');
}

function psScheduleHide() {
    if (psHideTimer) clearTimeout(psHideTimer);
    psHideTimer = setTimeout(() => {
        psTrack.classList.remove('visible');
        psHideTimer = null;
    }, 800);
}

// 鼠标离开轨道时安排淡出
function initPsHoverBehavior() {
    if (!psTrack) return;
    psTrack.addEventListener('mouseenter', psShow);
    psTrack.addEventListener('mouseleave', () => {
        if (!psDragState) psScheduleHide();
    });
}

// ═══════════════════════════════════════════
// Part 7c: 内嵌容器自建滚动条（通用）
//   为任意 overflow 容器挂载 .ps-track-inner > .ps-thumb-inner
//   axis: 'vertical' | 'horizontal'
// ═══════════════════════════════════════════

const psInnerInstances = [];

function initInnerScrollbar(container, axis, trackParent) {
    if (!container) return;
    // 避免重复挂载
    if (container.dataset.psInit === axis) return;
    container.dataset.psInit = axis;

    // track 挂载到 trackParent（非滚动父容器）或 container 本身
    const trackOwner = trackParent || container;
    const cs = getComputedStyle(trackOwner);
    if (cs.position === 'static') trackOwner.style.position = 'relative';

    const track = document.createElement('div');
    track.className = 'ps-track-inner ' + axis;
    const thumb = document.createElement('div');
    thumb.className = 'ps-thumb-inner';
    track.appendChild(thumb);
    trackOwner.appendChild(track);

    let hideTimer = null;
    let dragState = null;

    const show = () => {
        if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
        track.classList.add('visible');
    };
    const scheduleHide = () => {
        if (hideTimer) clearTimeout(hideTimer);
        hideTimer = setTimeout(() => {
            track.classList.remove('visible');
            hideTimer = null;
        }, 700);
    };

    const update = () => {
        const isVert = axis === 'vertical';
        const scrollPos = isVert ? container.scrollTop : container.scrollLeft;
        const scrollSize = isVert ? container.scrollHeight : container.scrollWidth;
        const clientSize = isVert ? container.clientHeight : container.clientWidth;
        const trackSize = isVert ? track.clientHeight : track.clientWidth;
        const scrollable = scrollSize - clientSize;

        if (scrollable <= 2) {
            track.classList.add('hidden');
            return;
        }
        track.classList.remove('hidden');

        const thumbMin = isVert ? 28 : 28;
        const thumbSize = Math.max(thumbMin, (clientSize / scrollSize) * trackSize);
        const scrollableTrack = trackSize - thumbSize;
        const thumbPos = scrollable > 0 ? (scrollPos / scrollable) * scrollableTrack : 0;

        if (isVert) {
            thumb.style.height = thumbSize + 'px';
            thumb.style.transform = `translateY(${thumbPos}px)`;
        } else {
            thumb.style.width = thumbSize + 'px';
            thumb.style.transform = `translateX(${thumbPos}px)`;
        }
    };

    // 滚动同步
    container.addEventListener('scroll', () => {
        update();
        show();
        scheduleHide();
    }, { passive: true });

    // 悬停
    track.addEventListener('mouseenter', show);
    track.addEventListener('mouseleave', () => { if (!dragState) scheduleHide(); });
    container.addEventListener('mouseenter', () => { update(); show(); });
    container.addEventListener('mouseleave', () => { if (!dragState) scheduleHide(); });

    // 拖拽
    thumb.addEventListener('mousedown', e => {
        e.preventDefault();
        e.stopPropagation();
        const isVert = axis === 'vertical';
        dragState = {
            startMouse: isVert ? e.clientY : e.clientX,
            startScroll: isVert ? container.scrollTop : container.scrollLeft,
            maxScroll: isVert ? container.scrollHeight - container.clientHeight
                              : container.scrollWidth - container.clientWidth,
        };
        thumb.classList.add('dragging');
        document.body.style.userSelect = 'none';
        show();
    });

    const onMove = e => {
        if (!dragState) return;
        const isVert = axis === 'vertical';
        const trackSize = isVert ? track.clientHeight : track.clientWidth;
        const thumbSize = isVert ? thumb.offsetHeight : thumb.offsetWidth;
        const d = (isVert ? e.clientY : e.clientX) - dragState.startMouse;
        const scrollableTrack = trackSize - thumbSize;
        if (scrollableTrack <= 0) return;
        const newScroll = dragState.startScroll + (d / scrollableTrack) * dragState.maxScroll;
        if (isVert) container.scrollTop = Math.max(0, Math.min(dragState.maxScroll, newScroll));
        else container.scrollLeft = Math.max(0, Math.min(dragState.maxScroll, newScroll));
    };

    const onUp = () => {
        if (!dragState) return;
        dragState = null;
        thumb.classList.remove('dragging');
        document.body.style.userSelect = '';
        scheduleHide();
    };

    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);

    // 监听容器内容变化
    if (window.ResizeObserver) {
        const ro = new ResizeObserver(update);
        ro.observe(container);
    }

    update();
    psInnerInstances.push({ container, update, track });
}

// 为页面所有内嵌滚动容器挂载自建滚动条
function initAllInnerScrollbars() {
    // 侧栏（纵向）— track 挂载到 sidebar（非滚动父容器）
    const sidebar = document.getElementById('sidebar');
    const sidebarNav = document.getElementById('sidebar-nav');
    initInnerScrollbar(sidebarNav, 'vertical', sidebar);
    // 顶部下拉菜单（纵向）— track 挂载到 nav-menu（非滚动父容器）
    document.querySelectorAll('.nav-menu').forEach(el => {
        const inner = el.querySelector('.nav-menu-inner');
        if (inner) initInnerScrollbar(inner, 'vertical', el);
    });
    // 代码块（横向）
    document.querySelectorAll('.code-body').forEach(el => initInnerScrollbar(el, 'horizontal'));
    // 表格（横向）
    document.querySelectorAll('.table-wrap').forEach(el => initInnerScrollbar(el, 'horizontal'));
    // 搜索结果（纵向）
    initInnerScrollbar(document.getElementById('search-results'), 'vertical');
}

// 内容切换后重新挂载（新渲染的代码块/表格）
function refreshInnerScrollbars() {
    document.querySelectorAll('.code-body').forEach(el => initInnerScrollbar(el, 'horizontal'));
    document.querySelectorAll('.table-wrap').forEach(el => initInnerScrollbar(el, 'horizontal'));
    // 下拉菜单可能在语言切换后重建
    document.querySelectorAll('.nav-menu').forEach(el => {
        const inner = el.querySelector('.nav-menu-inner');
        if (inner) initInnerScrollbar(inner, 'vertical', el);
    });
}

// ═══════════════════════════════════════════
// Part 8: 初始化
// ═══════════════════════════════════════════

document.addEventListener('DOMContentLoaded', () => {
    initLang();
    detectedPlatform = detectPlatform();
    renderSidebar();
    renderNavMenus();
    initNavIcons();
    applyLangToStatic();
    initCopyButtons();
    initExpandButtons();
    initScrollFeatures();
    initCustomScrollbar();
    initPsHoverBehavior();
    initAllInnerScrollbars();

    // 语言切换按钮
    const langBtn = document.getElementById('lang-toggle');
    if (langBtn) langBtn.onclick = toggleLang;

    navigate();
});

window.addEventListener('hashchange', navigate);

// 汉堡菜单
document.addEventListener('DOMContentLoaded', () => {
    const menuToggle = document.getElementById('menu-toggle');
    const sidebar = document.getElementById('sidebar');

    menuToggle.onclick = () => sidebar.classList.toggle('open');

    // 点击侧栏项后关闭菜单（移动端）
    sidebar.addEventListener('click', e => {
        if (e.target.classList.contains('sidebar-item') && window.innerWidth <= 900) {
            sidebar.classList.remove('open');
        }
    });
});

// ESC 关闭搜索
document.addEventListener('keydown', e => {
    if (e.key === 'Escape') {
        const sidebar = document.getElementById('sidebar');
        if (sidebar.classList.contains('open')) {
            sidebar.classList.remove('open');
        }
    }
});
