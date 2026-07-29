//! AST 源码位置与节点包装

/// 源码位置：行号与列号，用于错误定位
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Span {
    pub line: u32,
    pub column: u32,
}

impl Span {
    pub fn new(line: u32, column: u32) -> Self {
        Self { line, column }
    }
}

/// AST 节点包装：将源码位置与节点本体绑定
#[derive(Debug, Clone, PartialEq)]
pub struct Spanned<T> {
    pub span: Span,
    pub node: T,
}

impl<T> Spanned<T> {
    pub fn new(span: Span, node: T) -> Self {
        Self { span, node }
    }

    pub fn map<U, F: FnOnce(T) -> U>(self, f: F) -> Spanned<U> {
        Spanned {
            span: self.span,
            node: f(self.node),
        }
    }

    pub fn as_ref(&self) -> Spanned<&T> {
        Spanned {
            span: self.span,
            node: &self.node,
        }
    }
}
