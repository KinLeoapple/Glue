// docs/web/js/main.js — Glue 文档站主逻辑（优化版）

// === 全局状态 ===
let heroAnimTimer = null;
let scrollProgressEl = null;
let backToTopEl = null;
let psTrack = null;
let psThumb = null;
let psDragState = null;
let psHideTimer = null;

// ═══════════════════════════════════════════
// Part 1: 侧栏渲染
// ═══════════════════════════════════════════

function renderSidebar() {
    const nav = document.getElementById('sidebar-nav');
    nav.innerHTML = '';

    const groups = ['tutorial', 'reference'];
    const groupLabels = { tutorial: '教程', reference: '参考' };

    groups.forEach((group, gi) => {
        if (gi > 0) {
            const divider = document.createElement('div');
            divider.className = 'sidebar-divider';
            nav.appendChild(divider);
        }

        const label = document.createElement('div');
        label.className = 'sidebar-group-label';
        label.textContent = groupLabels[group];
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
                toggle.innerHTML = `<span class="arrow">▾</span> ${ch.title}`;
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
                    item.textContent = sec.title;
                    item.setAttribute('role', 'treeitem');
                    children.appendChild(item);
                });
                section.appendChild(children);
            } else {
                const item = document.createElement('a');
                item.className = 'sidebar-item';
                item.href = `#/${ch.id}`;
                item.dataset.chapter = ch.id;
                item.textContent = ch.title;
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
    requestAnimationFrame(() => psUpdate());
    setTimeout(psUpdate, 300);
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
        content.innerHTML = '<h1>页面不存在</h1><p>请从侧边栏选择一个章节。</p>';
        return;
    }

    let html = '';
    if (section && data.sections && data.sections[section]) {
        html = `<h1>${data.sections[section].title}</h1>`;
        html += renderBlocks(data.sections[section].blocks);
    } else {
        html = `<h1>${data.title}</h1>`;
        if (data.intro) html += renderBlocks(data.intro);
        if (data.sections) {
            const order = data.sectionOrder || Object.keys(data.sections);
            order.forEach(secId => {
                const sec = data.sections[secId];
                html += `<h2 id="${secId}">${sec.title}</h2>`;
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
        case 'code': return renderCodeBlock(block.code, block.filename);
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
    const label = kind.toUpperCase();
    return `<div class="callout callout-${kind}"><span class="callout-label">${label}</span>${inline(block.text)}</div>`;
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
    tutMenu.innerHTML = '';
    refMenu.innerHTML = '';
    CHAPTERS.forEach(ch => {
        const a = document.createElement('a');
        a.textContent = ch.title;
        a.href = `#/${ch.id}`;
        a.setAttribute('role', 'menuitem');
        if (ch.group === 'tutorial') tutMenu.appendChild(a);
        else refMenu.appendChild(a);
    });
}

// ═══════════════════════════════════════════
// Part 5: 代码块渲染
// ═══════════════════════════════════════════

function renderCodeBlock(code, filename) {
    const id = 'code-' + Math.random().toString(36).slice(2, 11);
    const fn = filename || 'example.glue';
    const highlighted = highlightGlue(code);
    return `
        <div class="code-block">
            <div class="code-header">
                <div class="code-dots">
                    <span class="red"></span><span class="yellow"></span><span class="green"></span>
                </div>
                <span class="code-filename">${fn}</span>
                <button class="copy-btn" data-code-id="${id}" aria-label="复制代码">复制</button>
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
            btn.textContent = '已复制!';
            btn.classList.add('copied');
            setTimeout(() => {
                btn.textContent = '复制';
                btn.classList.remove('copied');
            }, 1500);
        });
    });
}

// ═══════════════════════════════════════════
// Part 6: 首页 Hero
// ═══════════════════════════════════════════

function renderHome() {
    return `
    <div class="hero">
        <div class="hero-title">▸ Glue<span class="hero-cursor"></span></div>
        <div class="hero-tagline">安全、自然、高效的并行函数式语言</div>
        <div class="hero-tagline-sub">组合优于继承 · 显式优于隐式 · 运行时并行安全</div>
        <div class="hero-cta">
            <a href="#/start/what" class="cta-btn cta-primary">5 分钟入门</a>
            <a href="#/r1-cheatsheet" class="cta-btn cta-secondary">语法速查</a>
        </div>
        <div class="hero-terminal">
            ${renderCodeBlock('$ glue init app\n  created src/Main.glue\n  created glue.toml\n$ cd app\n$ glue run\nHello, Glue!', '~/app')}
        </div>
        <div class="hero-features">
            <div class="feature-card">
                <div class="feature-title">并发代码也安全</div>
                <div class="feature-desc"><code class="inline">async fun</code> + channel 像普通函数一样写并发；深拷贝隔离 + Atomic 共享，运行时保证无数据竞争</div>
            </div>
            <div class="feature-card">
                <div class="feature-title">坏值不偷偷溜走</div>
                <div class="feature-desc"><code class="inline">T?</code> 标可空、<code class="inline">Throw&lt;T,E&gt;</code> 标可失败；<code class="inline">?</code> 一行传播坏值，<code class="inline">match</code> 强制穷举处理</div>
            </div>
            <div class="feature-card">
                <div class="feature-title">标准库开箱即用</div>
                <div class="feature-desc"><code class="inline">std/io</code>、<code class="inline">std/time</code>、<code class="inline">std/reflect</code> 编进二进制；项目内同名文件可覆盖，自定义随心</div>
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
// Part 8: 初始化
// ═══════════════════════════════════════════

document.addEventListener('DOMContentLoaded', () => {
    renderSidebar();
    renderNavMenus();
    initCopyButtons();
    initScrollFeatures();
    initCustomScrollbar();
    initPsHoverBehavior();
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
