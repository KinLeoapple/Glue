// docs/web/js/i18n.js — 多语言系统（中文 / English）

const I18N_DATA = {
    zh: {
        // 导航栏
        nav_tutorial: '教程',
        nav_reference: '参考',
        nav_search: '搜索',
        nav_search_placeholder: '搜索文档...',
        nav_search_kbd: '⌘K',
        nav_github: 'GitHub',
        nav_lang_toggle: 'EN',

        // 侧栏
        sidebar_tutorial: '教程',
        sidebar_reference: '参考',

        // 首页
        hero_title: '▸ Glue',
        hero_tagline: '安全、自然、高效的并行函数式语言',
        hero_tagline_sub: '组合优于继承 · 显式优于隐式 · 运行时并行安全',
        hero_cta_start: '5 分钟入门',
        hero_cta_cheatsheet: '语法速查',
        hero_cta_github: 'GitHub',

        feature_safety_title: '并发代码也安全',
        feature_safety_desc: '<code class="inline">async fun</code> + channel 像普通函数一样写并发；深拷贝隔离 + Atomic 共享，运行时保证无数据竞争',
        feature_error_title: '坏值不偷偷溜走',
        feature_error_desc: '<code class="inline">T?</code> 标可空、<code class="inline">Throw&lt;T,E&gt;</code> 标可失败；<code class="inline">?</code> 一行传播坏值，<code class="inline">match</code> 强制穷举处理',
        feature_stdlib_title: '标准库开箱即用',
        feature_stdlib_desc: '<code class="inline">std/io</code>、<code class="inline">std/time</code>、<code class="inline">std/reflect</code> 编进二进制；项目内同名文件可覆盖，自定义随心',
        feature_zero_title: '零开销抽象',
        feature_zero_desc: '静态分发 + 无回退单态化，泛型在编译期展开；协程切换纳秒级，channel 零拷贝直传',

        // 提示框
        callout_tip: '提示',
        callout_info: '信息',
        callout_warn: '警告',

        // 代码块
        code_copy: '复制',
        code_copied: '已复制',

        // 搜索
        search_empty: '无匹配结果',

        // 回到顶部
        back_to_top_aria: '回到顶部',
        menu_toggle_aria: '切换菜单',
        search_aria: '搜索文档',
        search_close_aria: '关闭搜索',

        // 页面不存在
        not_found_title: '页面不存在',
        not_found_desc: '请从侧边栏选择一个章节。',

        // 章节标题英文翻译
        chapters: {
            home: '首页',
            start: '0. 起步',
            types: '1. 基础类型与字面量',
            vars: '2. 变量与函数',
            control: '3. 控制流',
            adt: '4. ADT 与 Pattern Matching',
            trait: '5. Trait',
            nullable: '6. Nullable 与错误处理',
            cast: '7. 类型转换',
            concurrency: '8. 并发编程',
            modules: '9. 模块系统与标准库',
            'r1-cheatsheet': 'R1. 语法速查表',
            'r2-types': 'R2. 类型系统参考',
            'r3-builtins': 'R3. 内建函数参考',
            'r4-stdlib': 'R4. 标准库 API',
            'r5-philosophy': 'R5. 设计哲学',
        },
        sections: {
            'what': '什么是 Glue',
            'install': '安装与项目结构',
            'hello': 'Hello World',
            'fib': '第一个示例',
            'scalars': '标量类型',
            'int-rules': '整数规则',
            'float': '浮点数',
            'literals': '字面量',
            'str': 'str 与 UTF-8',
            'bindings': '变量绑定',
            'functions': '函数定义',
            'currying': '柯里化',
            'lambda': 'Lambda',
            'refs': '借用引用',
            'if': 'if 表达式',
            'loops': '循环',
            'range': 'Range 与迭代器',
            'defer': 'defer',
            'tco': '尾调用优化',
            'enum': '枚举',
            'record': '记录',
            'newtype': 'Newtype 与别名',
            'generic-adt': '泛型 ADT',
            'gadt': 'GADT',
            'match': 'Pattern Matching',
            'define': '定义与实现',
            'multi': '多 Trait',
            'bounds': '约束与特化',
            'first-class': '一等 Trait 值',
            'nullable': 'T? 可空类型',
            'operators': '操作符',
            'propagation': '? 传播',
            'throw': 'Throw<T,E>',
            'custom-error': '自定义错误',
            'strategy': '策略对照',
            'cast-builder': 'cast builder',
            'builtin-cast': '内建转换函数',
            'rules': '转换规则',
            'async': 'async fun',
            'capture': '深拷贝捕获',
            'channel': 'Channel',
            'select': 'select',
            'atomic': 'Atomic<T>',
            'safety': '并行安全',
            'file-module': '文件即模块',
            'visibility': '可见性',
            'import': 'import',
            'stdlib': '标准库',
        },
    },

    en: {
        // Navbar
        nav_tutorial: 'Tutorial',
        nav_reference: 'Reference',
        nav_search: 'Search',
        nav_search_placeholder: 'Search docs...',
        nav_search_kbd: '⌘K',
        nav_github: 'GitHub',
        nav_lang_toggle: '中文',

        // Sidebar
        sidebar_tutorial: 'Tutorial',
        sidebar_reference: 'Reference',

        // Hero
        hero_title: '▸ Glue',
        hero_tagline: 'Safe, natural, efficient parallel functional language',
        hero_tagline_sub: 'Composition over inheritance · Explicit over implicit · Runtime parallel safety',
        hero_cta_start: 'Quick Start',
        hero_cta_cheatsheet: 'Cheatsheet',
        hero_cta_github: 'GitHub',

        feature_safety_title: 'Concurrency Made Safe',
        feature_safety_desc: '<code class="inline">async fun</code> + channel makes concurrency as natural as regular functions; deep-copy isolation + Atomic sharing, runtime guarantees no data races',
        feature_error_title: 'No Bad Values Slip Through',
        feature_error_desc: '<code class="inline">T?</code> marks nullable, <code class="inline">Throw&lt;T,E&gt;</code> marks fallible; <code class="inline">?</code> propagates in one line, <code class="inline">match</code> forces exhaustive handling',
        feature_stdlib_title: 'Standard Library Out of the Box',
        feature_stdlib_desc: '<code class="inline">std/io</code>, <code class="inline">std/time</code>, <code class="inline">std/reflect</code> compiled into the binary; project-local files can override, customize freely',
        feature_zero_title: 'Zero-Cost Abstraction',
        feature_zero_desc: 'Static dispatch + no-fallback monomorphization, generics expand at compile time; nanosecond coroutine switching, zero-copy channel passing',

        // Callouts
        callout_tip: 'Tip',
        callout_info: 'Info',
        callout_warn: 'Warning',

        // Code
        code_copy: 'Copy',
        code_copied: 'Copied',

        // Search
        search_empty: 'No results found',

        // Aria
        back_to_top_aria: 'Back to top',
        menu_toggle_aria: 'Toggle menu',
        search_aria: 'Search docs',
        search_close_aria: 'Close search',

        // Not found
        not_found_title: 'Page Not Found',
        not_found_desc: 'Please select a chapter from the sidebar.',

        // Chapter titles
        chapters: {
            home: 'Home',
            start: '0. Getting Started',
            types: '1. Basic Types & Literals',
            vars: '2. Variables & Functions',
            control: '3. Control Flow',
            adt: '4. ADT & Pattern Matching',
            trait: '5. Trait',
            nullable: '6. Nullable & Error Handling',
            cast: '7. Type Casting',
            concurrency: '8. Concurrency',
            modules: '9. Modules & Standard Library',
            'r1-cheatsheet': 'R1. Syntax Cheatsheet',
            'r2-types': 'R2. Type System Reference',
            'r3-builtins': 'R3. Built-in Functions',
            'r4-stdlib': 'R4. Standard Library API',
            'r5-philosophy': 'R5. Design Philosophy',
        },
        sections: {
            'what': 'What is Glue',
            'install': 'Installation & Project Structure',
            'hello': 'Hello World',
            'fib': 'First Example',
            'scalars': 'Scalar Types',
            'int-rules': 'Integer Rules',
            'float': 'Floating Point',
            'literals': 'Literals',
            'str': 'str & UTF-8',
            'bindings': 'Variable Bindings',
            'functions': 'Function Definitions',
            'currying': 'Currying',
            'lambda': 'Lambda',
            'refs': 'Borrowing References',
            'if': 'if Expressions',
            'loops': 'Loops',
            'range': 'Range & Iterators',
            'defer': 'defer',
            'tco': 'Tail Call Optimization',
            'enum': 'Enums',
            'record': 'Records',
            'newtype': 'Newtype & Aliases',
            'generic-adt': 'Generic ADT',
            'gadt': 'GADT',
            'match': 'Pattern Matching',
            'define': 'Definition & Implementation',
            'multi': 'Multi-Trait',
            'bounds': 'Bounds & Specialization',
            'first-class': 'First-Class Trait Values',
            'nullable': 'T? Nullable Type',
            'operators': 'Operators',
            'propagation': '? Propagation',
            'throw': 'Throw<T,E>',
            'custom-error': 'Custom Errors',
            'strategy': 'Strategy Comparison',
            'cast-builder': 'cast builder',
            'builtin-cast': 'Built-in Cast Functions',
            'rules': 'Casting Rules',
            'async': 'async fun',
            'capture': 'Deep Copy Capture',
            'channel': 'Channel',
            'select': 'select',
            'atomic': 'Atomic<T>',
            'safety': 'Parallel Safety',
            'file-module': 'File as Module',
            'visibility': 'Visibility',
            'import': 'import',
            'stdlib': 'Standard Library',
        },
    },
};

// === 当前语言 ===
let currentLang = 'zh';

// 初始化语言（从 localStorage 读取）
function initLang() {
    const saved = localStorage.getItem('glue-lang');
    if (saved === 'en' || saved === 'zh') {
        currentLang = saved;
    }
}

// 获取当前语言
function getLang() {
    return currentLang;
}

// 翻译函数
function t(key) {
    const dict = I18N_DATA[currentLang];
    if (!dict) return key;
    return dict[key] || I18N_DATA.zh[key] || key;
}

// 获取章节标题（根据当前语言）
function tChapter(chId) {
    const dict = I18N_DATA[currentLang];
    if (dict && dict.chapters && dict.chapters[chId]) return dict.chapters[chId];
    // 回退到原始 CHAPTERS 数据
    const ch = CHAPTERS.find(c => c.id === chId);
    return ch ? ch.title : chId;
}

// 获取小节标题（根据当前语言）
function tSection(chId, secId) {
    const dict = I18N_DATA[currentLang];
    if (dict && dict.sections && dict.sections[secId]) return dict.sections[secId];
    // 回退到原始数据
    const ch = CHAPTERS.find(c => c.id === chId);
    if (ch) {
        const sec = ch.sections.find(s => s.id === secId);
        if (sec) return sec.title;
    }
    return secId;
}

// 获取侧栏组标签
function tGroupLabel(group) {
    return group === 'tutorial' ? t('sidebar_tutorial') : t('sidebar_reference');
}

// 切换语言并重新渲染
function toggleLang() {
    currentLang = currentLang === 'zh' ? 'en' : 'zh';
    localStorage.setItem('glue-lang', currentLang);
    document.documentElement.lang = currentLang === 'zh' ? 'zh-CN' : 'en';
    applyLangToStatic();
    // 重新渲染动态内容
    renderSidebar();
    renderNavMenus();
    initNavIcons();
    navigate();
}

// 根据平台返回搜索快捷键标签（macOS 用 ⌘K，Windows/Linux 用 Ctrl K）
function searchKbdLabel() {
    const isMac = (typeof detectedPlatform !== 'undefined' && detectedPlatform)
        ? detectedPlatform === 'mac'
        : /mac|iphone|ipad/i.test(navigator.userAgent);
    return isMac ? '⌘K' : 'Ctrl+K';
}

// 应用语言到静态 HTML 元素
function applyLangToStatic() {
    // 导航栏按钮
    document.querySelectorAll('.nav-btn').forEach((btn, i) => {
        const key = i === 0 ? 'nav_tutorial' : 'nav_reference';
        btn.innerHTML = `${t(key)} <span class="nav-chevron">${ICONS.chevronDown}</span>`;
        btn.dataset.iconInit = '1';
    });

    // 搜索按钮
    const searchTrigger = document.getElementById('search-trigger');
    if (searchTrigger) {
        const kbd = searchTrigger.querySelector('kbd');
        searchTrigger.innerHTML = `<span class="nav-icon">${ICONS.search}</span><span>${t('nav_search')}</span>`;
        const kbdLabel = searchKbdLabel();
        if (kbd) {
            kbd.textContent = kbdLabel;
            searchTrigger.appendChild(kbd);
        } else {
            const newKbd = document.createElement('kbd');
            newKbd.textContent = kbdLabel;
            searchTrigger.appendChild(newKbd);
        }
        searchTrigger.dataset.iconInit = '1';
    }

    // 搜索输入框
    const searchInput = document.getElementById('search-input');
    if (searchInput) searchInput.placeholder = t('nav_search_placeholder');

    // 语言切换按钮文字
    const langBtn = document.getElementById('lang-toggle');
    if (langBtn) langBtn.textContent = t('nav_lang_toggle');

    // GitHub 链接 — 纯图标，无文字
    const githubLink = document.querySelector('.github-link');
    if (githubLink) {
        githubLink.innerHTML = `<span class="nav-icon">${ICONS.github}</span>`;
        githubLink.dataset.iconInit = '1';
        githubLink.setAttribute('aria-label', t('nav_github'));
    }

    // 汉堡菜单
    const menuToggle = document.getElementById('menu-toggle');
    if (menuToggle) {
        menuToggle.setAttribute('aria-label', t('menu_toggle_aria'));
    }

    // 回到顶部
    const backToTop = document.getElementById('back-to-top');
    if (backToTop) {
        backToTop.setAttribute('aria-label', t('back_to_top_aria'));
    }

    // 搜索框 aria
    const searchTrigger2 = document.getElementById('search-trigger');
    if (searchTrigger2) searchTrigger2.setAttribute('aria-label', t('search_aria'));
    const searchClose = document.getElementById('search-close');
    if (searchClose) searchClose.setAttribute('aria-label', t('search_close_aria'));

    // 页面 title
    document.title = currentLang === 'zh'
        ? 'Glue — 安全、自然、高效的并行函数式语言'
        : 'Glue — Safe, Natural, Efficient Parallel Functional Language';
}
