// docs/web/js/main.js — Part 1: 侧栏渲染 + 路由

// === 侧栏渲染 ===
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
                toggle.innerHTML = `<span class="arrow">▾</span> ${ch.title}`;
                toggle.onclick = () => {
                    const children = section.querySelector('.sidebar-children');
                    children.classList.toggle('collapsed');
                    const arrow = toggle.querySelector('.arrow');
                    arrow.textContent = children.classList.contains('collapsed') ? '▸' : '▾';
                };
                section.appendChild(toggle);

                const children = document.createElement('div');
                children.className = 'sidebar-children';
                ch.sections.forEach(sec => {
                    const item = document.createElement('div');
                    item.className = 'sidebar-item';
                    item.dataset.chapter = ch.id;
                    item.dataset.section = sec.id;
                    item.textContent = sec.title;
                    item.onclick = () => {
                        location.hash = `#/${ch.id}/${sec.id}`;
                    };
                    children.appendChild(item);
                });
                section.appendChild(children);
            } else {
                const item = document.createElement('div');
                item.className = 'sidebar-item';
                item.dataset.chapter = ch.id;
                item.textContent = ch.title;
                item.onclick = () => {
                    location.hash = `#/${ch.id}`;
                };
                section.appendChild(item);
            }

            nav.appendChild(section);
        });
    });
}

// === 路由 ===
function getRoute() {
    const hash = location.hash.slice(1); // remove #
    if (!hash || hash === '/') return { chapter: 'home', section: null };
    const parts = hash.slice(1).split('/'); // remove leading /
    return { chapter: parts[0] || 'home', section: parts[1] || null };
}

function navigate() {
    const { chapter, section } = getRoute();
    updateActiveSidebar(chapter, section);
    renderContent(chapter, section);
    window.scrollTo(0, 0);
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

function renderContent(chapter, section) {
    const content = document.getElementById('content');
    const data = CONTENT[chapter];

    if (chapter === 'home') {
        content.innerHTML = renderHome();
        initHeroAnimation();
        return;
    }

    if (!data) {
        content.innerHTML = '<h1>页面不存在</h1>';
        return;
    }

    // 如果有 section，只渲染该 section；否则渲染整个 chapter
    let html = '';
    if (section && data.sections && data.sections[section]) {
        html = renderBlocks(data.sections[section].blocks);
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

// 渲染 blocks 数组为 HTML
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
    let html = '<table><thead><tr>';
    html += block.headers.map(h => `<th>${h}</th>`).join('');
    html += '</tr></thead><tbody>';
    block.rows.forEach(row => {
        html += '<tr>' + row.map(c => `<td>${inline(c)}</td>`).join('') + '</tr>';
    });
    html += '</tbody></table>';
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

// === 导航下拉菜单 ===
function renderNavMenus() {
    const tutMenu = document.getElementById('nav-tutorial');
    const refMenu = document.getElementById('nav-reference');
    tutMenu.innerHTML = '';
    refMenu.innerHTML = '';
    CHAPTERS.forEach(ch => {
        const a = document.createElement('a');
        a.textContent = ch.title;
        a.href = `#/${ch.id}`;
        if (ch.group === 'tutorial') tutMenu.appendChild(a);
        else refMenu.appendChild(a);
    });
}

// === 初始化 ===
document.addEventListener('DOMContentLoaded', () => {
    renderSidebar();
    renderNavMenus();
    navigate();
});

window.addEventListener('hashchange', navigate);

// docs/web/js/main.js — Part 2: 代码块渲染

function renderCodeBlock(code, filename) {
    const id = 'code-' + Math.random().toString(36).slice(2, 9);
    const fn = filename || 'example.glue';
    const highlighted = highlightGlue(code);
    return `
        <div class="code-block">
            <div class="code-header">
                <div class="code-dots">
                    <span class="red"></span><span class="yellow"></span><span class="green"></span>
                </div>
                <span class="code-filename">${fn}</span>
                <button class="copy-btn" onclick="copyCode('${id}')">复制</button>
            </div>
            <div class="code-body">
                <pre id="${id}">${highlighted}</pre>
            </div>
        </div>`;
}

function copyCode(id) {
    const pre = document.getElementById(id);
    const text = pre.textContent;
    navigator.clipboard.writeText(text).then(() => {
        const btn = pre.closest('.code-block').querySelector('.copy-btn');
        btn.textContent = 'Copied!';
        btn.classList.add('copied');
        setTimeout(() => {
            btn.textContent = '复制';
            btn.classList.remove('copied');
        }, 1500);
    });
}

// docs/web/js/main.js — Part 4: 首页 hero

function renderHome() {
    return `
    <div class="hero">
        <div class="hero-title">▸ Glue<span class="hero-cursor">_</span></div>
        <div class="hero-tagline">安全、自然、高效的并行函数式语言</div>
        <div class="hero-cta">
            <a href="#/start/what" class="cta-btn cta-primary">5 分钟入门</a>
            <a href="#/r1-cheatsheet" class="cta-btn cta-secondary">语法速查</a>
        </div>
        <div class="hero-terminal">
            ${renderCodeBlock('', '~/app')}
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
    const interval = setInterval(() => {
        if (idx >= text.length) {
            clearInterval(interval);
            return;
        }
        idx += 2;
        term.textContent = text.slice(0, idx);
    }, 30);
}

// docs/web/js/main.js — Part 5: 汉堡菜单 + 锚点

document.addEventListener('DOMContentLoaded', () => {
    // 汉堡菜单
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
