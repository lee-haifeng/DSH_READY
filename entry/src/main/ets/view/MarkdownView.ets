/**
 * MarkdownView —— 聊天消息气泡的 Markdown 富文本渲染组件。
 *
 * 设计约束（与 DSH Ready 的聊天流式输出对齐）：
 *  - 入参只有 Markdown 源码 text（流式过程中被高频更新）和只读样式令牌 palette；
 *  - text 变化 -> @Watch 重建 @State blocks（全量重解析，无节流、无定时器）；
 *  - 解析器对不完整输入健壮：未闭合围栏代码块、未闭合 ** 粗体、只有一个 | 的行、
 *    结尾带 # 的标题、空文本等都不会抛异常（最外层还有 try/catch 兜底）；
 *  - 渲染层不做任何业务交互（不跳转链接、不复制到系统剪贴板），只负责展示。
 *
 * 支持的块级语法（均可嵌套/混排）：
 *  1) 围栏代码块 ```lang             -> 等宽字体 + codeBackground + 横向 Scroll + 顶部 1vp 边框 + 右上角语言名
 *  2) 标题 # ~ ######               -> 字号 fontSize+8/+6/+4/+2/+1，全部加粗
 *  3) 无序列表 - / * / +、有序列表 1. -> 每 2 个前导空格一级，最多缩进 2 级
 *  4) 引用块 >                       -> 左侧 3vp quoteBorder 竖线 + 次要文字色
 *  5) 水平线 --- / *** / ___         -> 1vp 分隔线
 *  6) GFM 表格（表头 + |---|---| 对齐行）-> 真网格：横向 Scroll + 嵌套 Row，单元格固定宽高
 *     （单元格按原始文本显示、不做行内解析，超过 2 行省略；这是有意的简化）
 *  7) 段落                           -> 行高 1.5 倍
 *
 * 行内语法（段落 / 列表 / 标题 / 引用内生效）：
 *  **粗体**、*斜体* / _斜体_、`行内代码`（codeBackground 背景 + 等宽）、
 *  ~~删除线~~、[文字](url)（显示文字 + linkText + 下划线，不跳转）、
 *  裸 URL（http:// 或 https:// 开头）自动套链接样式。
 *
 * 全文件不写任何测试/说明文件；不 import 除 ../common/Theme 之外的模块。
 */

import { Palette } from '../common/Theme';

/**
 * 一个行内 token。最终由 Text 里的 Span 渲染，多个标志位可叠加（如加粗+斜体）。
 * 字段全部必需，方便解析器一次性构造出完整对象。
 */
interface MdSpan {
  text: string;
  bold: boolean;
  italic: boolean;
  code: boolean;
  strike: boolean;
  link: boolean;
}

/**
 * 一个块级元素。type 取值见下面 BLOCK_* 常量。
 * 为了贴合上层协议，这里把表格行也当作独立 block（type = 'tableRow'），
 * 渲染时把连续的 tableRow 合成一个网格；tableRow 的 level 复用为“是否表头”
 * （1 = 表头行，0 = 数据行），cells 存该行已 trim 的原始文本。
 */
interface MdBlock {
  type: string;
  level: number;
  ordered: boolean;
  index: number;
  lang: string;
  code: string;
  spans: MdSpan[];
  cells: string[];
}

/** 块类型词表，全部使用字符串常量避免散落的魔法字符串。 */
const BLOCK_PARAGRAPH: string = 'paragraph';
const BLOCK_HEADING: string = 'heading';
const BLOCK_CODE: string = 'code';
const BLOCK_LIST_ITEM: string = 'listItem';
const BLOCK_QUOTE: string = 'quote';
const BLOCK_DIVIDER: string = 'divider';
const BLOCK_TABLE_ROW: string = 'tableRow';

/** 等宽字体；HarmonyOS 内置 monospace family。 */
const MONO_FONT: string = 'monospace';
/** 正文默认字体族（HarmonyOS 系统默认），Span 显式设置时用它还原非代码文本。 */
const BODY_FONT_FAMILY: string = 'HarmonyOS Sans';

/** 列表最多支持 2 级缩进（每 2 个空格一级）。 */
const MAX_LIST_INDENT: number = 2;

/** 表格单元格尺寸（vp）。列多时整张表横向滚动，不压缩单元格。 */
const TABLE_CELL_WIDTH: number = 132;
const TABLE_CELL_HEIGHT: number = 48;

/** 行内递归深度上限，防止畸形输入造成深递归。 */
const MAX_INLINE_DEPTH: number = 6;
/** 单个文本块的行内 token 上限，超出后剩余内容降级为纯文本。 */
const MAX_INLINE_SPANS: number = 1200;

/** 稳定 key 的哈希取模，避免数字无限增长。 */
const HASH_MOD: number = 1000000007;

/**
 * 内置的 light 兜底色板：@Prop 接口类型必须有本地默认值，而父组件理论上可能传 undefined。
 * 这里只 import Palette 类型（不 import 主题实例），所以在本文件内自带一份浅色兜底；
 * 字段与 common/Theme 的 LIGHT 保持一致，仅用于极端情况下不白屏，正常渲染始终用入参 palette。
 */
const FALLBACK_LIGHT: Palette = {
  bg: '#F7F8FA',
  surface: '#FFFFFF',
  surfaceAlt: '#F0F2F5',
  surfaceHigh: '#FFFFFF',
  border: '#E2E5EA',
  borderStrong: '#C9CED6',
  textPrimary: '#1A1C21',
  textSecondary: '#5A616D',
  textTertiary: '#8A919D',
  onAccent: '#FFFFFF',
  accent: '#2F6BFF',
  accentSoft: '#E6EDFF',
  linkText: '#2F6BFF',
  danger: '#D9363E',
  dangerSoft: '#FDECEC',
  warning: '#B87413',
  success: '#1F9D55',
  userBubble: '#2F6BFF',
  userBubbleText: '#FFFFFF',
  assistantBubble: '#00000000',
  codeBackground: '#F2F4F7',
  codeBorder: '#E2E5EA',
  quoteBorder: '#C9CED6',
  reasoningBg: '#F2F4F7',
  reasoningBorder: '#E2E5EA',
  toolBg: '#F2F4F7',
  toolBorder: '#E2E5EA',
  scrim: '#00000055',
  pulse: '#2F6BFF'
};

@Component
export struct MarkdownView {
  /** Markdown 源码；流式输出时由父组件高频更新。 */
  @Prop @Watch('onTextChanged') text: string = '';
  /** 颜色令牌。@Prop 接口类型必须本地初始化，用文件内置的浅色兜底。 */
  @Prop palette: Palette = FALLBACK_LIGHT;
  /** 正文基准字号（fp）。 */
  @Prop fontSize: number = 16;
  /** 文本是否可长按选择。 */
  @Prop selectable: boolean = true;

  /** 解析结果。每次 text 变化整体替换，驱动 ForEach 重新渲染。 */
  @State blocks: MdBlock[] = [];

  aboutToAppear(): void {
    this.rebuild();
  }

  /** @Watch 回调：text 变了就重解析。不做节流，避免流式输出时内容滞后。 */
  onTextChanged(changedProperty: string): void {
    this.rebuild();
  }

  // ---------------------------------------------------------------------------
  // 状态 / 令牌工具
  // ---------------------------------------------------------------------------

  /** 重新解析。解析器理论上不会抛异常，这里仍然兜底，保证 UI 永远有内容。 */
  private rebuild(): void {
    try {
      this.blocks = this.parseMarkdown(this.text);
    } catch (error) {
      this.blocks = this.fallbackBlocks();
    }
  }

  /** 解析失败时的降级：把原文作为普通段落展示，绝不白屏。 */
  private fallbackBlocks(): MdBlock[] {
    const blocks: MdBlock[] = [];
    if (this.text.length === 0) {
      return blocks;
    }
    const block: MdBlock = this.makeBlock(BLOCK_PARAGRAPH);
    block.spans = [this.makeSpan(this.text, false, false, false, false, false)];
    blocks.push(block);
    return blocks;
  }

  /** 取 palette；@Prop 已本地初始化，undefined 分支只是防御。 */
  private paletteValue(): Palette {
    const current: Palette | undefined = this.palette;
    if (current === undefined) {
      return FALLBACK_LIGHT;
    }
    return current;
  }

  // ---------------------------------------------------------------------------
  // 数据结构工厂
  // ---------------------------------------------------------------------------

  private makeBlock(kind: string): MdBlock {
    const block: MdBlock = {
      type: kind,
      level: 0,
      ordered: false,
      index: 0,
      lang: '',
      code: '',
      spans: [],
      cells: []
    };
    return block;
  }

  private makeSpan(text: string, bold: boolean, italic: boolean, code: boolean, strike: boolean,
    link: boolean): MdSpan {
    const span: MdSpan = {
      text: text,
      bold: bold,
      italic: italic,
      code: code,
      strike: strike,
      link: link
    };
    return span;
  }

  private makeCodeBlock(lang: string, codeLines: string[]): MdBlock {
    const block: MdBlock = this.makeBlock(BLOCK_CODE);
    block.lang = lang;
    let code: string = '';
    for (let i = 0; i < codeLines.length; i++) {
      if (i > 0) {
        code += '\n';
      }
      code += codeLines[i];
    }
    block.code = code;
    return block;
  }

  // ---------------------------------------------------------------------------
  // 稳定 key：ForEach 在 key 不变时会复用旧组件，流式更新必须让 key 跟内容变化
  // ---------------------------------------------------------------------------

  private hashSeed(seed: number, value: string): number {
    let hash: number = seed;
    for (let i = 0; i < value.length; i++) {
      hash = (hash * 33 + value.charCodeAt(i)) % HASH_MOD;
    }
    return hash;
  }

  private blockContentHash(block: MdBlock): number {
    let hash: number = this.hashSeed(3, block.type);
    hash = this.hashSeed(hash, block.lang);
    hash = this.hashSeed(hash, block.code);
    hash = (hash * 31 + block.level * 7 + block.index * 13 + (block.ordered ? 1 : 0)) % HASH_MOD;
    for (let i = 0; i < block.spans.length; i++) {
      const span: MdSpan = block.spans[i];
      hash = this.hashSeed(hash, span.text);
      let flags: number = 0;
      if (span.bold) {
        flags += 1;
      }
      if (span.italic) {
        flags += 2;
      }
      if (span.code) {
        flags += 4;
      }
      if (span.strike) {
        flags += 8;
      }
      if (span.link) {
        flags += 16;
      }
      hash = (hash * 31 + flags) % HASH_MOD;
    }
    for (let i = 0; i < block.cells.length; i++) {
      hash = this.hashSeed(hash, block.cells[i]);
    }
    return hash;
  }

  /**
   * 块级 ForEach 的 key。表格首行（parser 会把表头行 index 置 0）还要把整张表的
   * 内容并入 key，否则表格中间某一行变化时首行 key 不变，外层组件被复用，
   * 嵌套 ForEach 不会重新求值，表格会显示旧内容（流式输出时必现）。
   */
  private blockKey(block: MdBlock, index: number): string {
    let hash: number = this.blockContentHash(block);
    if (block.type === BLOCK_TABLE_ROW && block.index === 0) {
      let scan: number = index + 1;
      while (scan < this.blocks.length && this.blocks[scan].type === BLOCK_TABLE_ROW) {
        hash = this.hashSeed(hash, this.blocks[scan].cells.join('\u0001'));
        scan++;
      }
    }
    return index.toString() + '-' + hash.toString();
  }

  private spanKey(span: MdSpan, index: number): string {
    let hash: number = this.hashSeed(7, span.text);
    let flags: number = 0;
    if (span.bold) {
      flags += 1;
    }
    if (span.italic) {
      flags += 2;
    }
    if (span.code) {
      flags += 4;
    }
    if (span.strike) {
      flags += 8;
    }
    if (span.link) {
      flags += 16;
    }
    hash = (hash * 31 + flags) % HASH_MOD;
    return index.toString() + '-' + hash.toString();
  }

  private tableRowKey(row: MdBlock, rowIndex: number, tableStart: number): string {
    let hash: number = this.hashSeed(11, row.cells.join('\u0001'));
    hash = (hash * 17 + rowIndex + tableStart * 31) % HASH_MOD;
    return tableStart.toString() + '-' + rowIndex.toString() + '-' + hash.toString();
  }

  // ---------------------------------------------------------------------------
  // 块级解析（按行扫描的状态机）
  // ---------------------------------------------------------------------------

  private parseMarkdown(source: string): MdBlock[] {
    const blocks: MdBlock[] = [];
    if (source.length === 0) {
      return blocks;
    }
    const lines: string[] = source.split('\n');
    // 段落缓冲区：连续普通行合成一个段落（保留软换行）
    let paragraphLines: string[] = [];
    // 围栏代码块状态（未闭合时在 EOF 按代码块输出，不会丢内容）
    let inCode: boolean = false;
    let codeLang: string = '';
    let codeLines: string[] = [];
    // 有序列表连续编号状态
    let previousOrdered: boolean = false;
    let previousLevel: number = 0;
    let previousIndex: number = 0;
    let i: number = 0;

    while (i < lines.length) {
      const rawLine: string = this.stripCarriageReturn(lines[i]);
      const trimmed: string = rawLine.trim();

      // 1) 代码块内部：只有纯反引号行才闭合；语言名、代码内容原样保留
      if (inCode) {
        if (this.isFenceClose(trimmed)) {
          blocks.push(this.makeCodeBlock(codeLang, codeLines));
          inCode = false;
          codeLang = '';
          codeLines = [];
        } else {
          codeLines.push(rawLine);
        }
        i++;
        continue;
      }

      // 空行：结束当前段落
      if (trimmed.length === 0) {
        this.flushParagraph(blocks, paragraphLines);
        paragraphLines = [];
        previousOrdered = false;
        i++;
        continue;
      }

      // 2) 围栏代码块开始
      if (this.isFenceStart(trimmed)) {
        this.flushParagraph(blocks, paragraphLines);
        paragraphLines = [];
        inCode = true;
        codeLang = this.fenceLanguage(trimmed);
        codeLines = [];
        previousOrdered = false;
        i++;
        continue;
      }

      // 3) 水平线：仅由 >=3 个同种 - / * / _ 组成（可带空格）
      if (this.isDivider(trimmed)) {
        this.flushParagraph(blocks, paragraphLines);
        paragraphLines = [];
        blocks.push(this.makeBlock(BLOCK_DIVIDER));
        previousOrdered = false;
        i++;
        continue;
      }

      // 4) 标题：# 后必须跟空白或行尾；结尾的 # 关闭序列会被去掉
      const headingLevel: number = this.headingLevel(trimmed);
      if (headingLevel > 0) {
        this.flushParagraph(blocks, paragraphLines);
        paragraphLines = [];
        const headingBlock: MdBlock = this.makeBlock(BLOCK_HEADING);
        headingBlock.level = headingLevel;
        headingBlock.spans = this.parseInline(this.headingText(trimmed, headingLevel), 0);
        blocks.push(headingBlock);
        previousOrdered = false;
        i++;
        continue;
      }

      // 5) 引用块：剥掉前导 > 后当作普通行内容做行内解析
      if (trimmed.charAt(0) === '>') {
        this.flushParagraph(blocks, paragraphLines);
        paragraphLines = [];
        const quoteBlock: MdBlock = this.makeBlock(BLOCK_QUOTE);
        quoteBlock.spans = this.parseInline(this.stripQuoteMarkers(trimmed), 0);
        blocks.push(quoteBlock);
        previousOrdered = false;
        i++;
        continue;
      }

      // 6) 列表：先去掉前导空白再识别 marker；空行/其他块会重置有序编号
      const indentWidth: number = this.leadingIndentWidth(rawLine);
      const listBody: string = this.trimLeft(rawLine);
      if (this.isUnorderedItem(listBody)) {
        this.flushParagraph(blocks, paragraphLines);
        paragraphLines = [];
        const unorderedBlock: MdBlock = this.makeBlock(BLOCK_LIST_ITEM);
        unorderedBlock.level = this.indentToLevel(indentWidth);
        unorderedBlock.ordered = false;
        unorderedBlock.spans = this.parseInline(this.trimLeft(listBody.substring(1)), 0);
        blocks.push(unorderedBlock);
        previousOrdered = false;
        i++;
        continue;
      }
      const markerEnd: number = this.orderedMarkerEnd(listBody);
      if (markerEnd > 0) {
        this.flushParagraph(blocks, paragraphLines);
        paragraphLines = [];
        const level: number = this.indentToLevel(indentWidth);
        const orderedBlock: MdBlock = this.makeBlock(BLOCK_LIST_ITEM);
        orderedBlock.level = level;
        orderedBlock.ordered = true;
        // 源码序号和连续编号取其一：同一层级连续出现时自增，避免模型全写 1.
        const parsedNumber: number = this.smallPositiveInt(listBody.substring(0, markerEnd - 1));
        if (previousOrdered && previousLevel === level) {
          orderedBlock.index = previousIndex + 1;
        } else {
          orderedBlock.index = parsedNumber;
        }
        orderedBlock.spans = this.parseInline(this.trimLeft(listBody.substring(markerEnd)), 0);
        blocks.push(orderedBlock);
        previousOrdered = true;
        previousLevel = level;
        previousIndex = orderedBlock.index;
        i++;
        continue;
      }

      // 7) 表格开始：当前行含 |，且下一行是合法的 |---|---| 对齐行
      if (trimmed.indexOf('|') >= 0 && i + 1 < lines.length) {
        const nextTrimmed: string = this.stripCarriageReturn(lines[i + 1]).trim();
        if (this.isTableSeparator(nextTrimmed)) {
          this.flushParagraph(blocks, paragraphLines);
          paragraphLines = [];
          i = this.collectTable(lines, i, blocks);
          previousOrdered = false;
          continue;
        }
      }

      // 8) 段落：连续普通行累积，直到空行或其他块类型
      paragraphLines.push(trimmed);
      previousOrdered = false;
      i++;
    }

    // EOF：未闭合的围栏代码块也按代码块输出，内容不丢
    if (inCode) {
      blocks.push(this.makeCodeBlock(codeLang, codeLines));
    }
    this.flushParagraph(blocks, paragraphLines);
    return blocks;
  }

  /** 行尾 \r 归一到 \n 的分行结果里去掉（兼容 CRLF 流式文本）。 */
  private stripCarriageReturn(line: string): string {
    if (line.length > 0 && line.charAt(line.length - 1) === '\r') {
      return line.substring(0, line.length - 1);
    }
    return line;
  }

  /** 把当前段落的行拼起来做成 paragraph block。 */
  private flushParagraph(blocks: MdBlock[], lines: string[]): void {
    if (lines.length === 0) {
      return;
    }
    let joined: string = '';
    for (let i = 0; i < lines.length; i++) {
      if (i > 0) {
        joined += '\n';
      }
      joined += lines[i];
    }
    if (joined.length === 0) {
      return;
    }
    const block: MdBlock = this.makeBlock(BLOCK_PARAGRAPH);
    block.spans = this.parseInline(joined, 0);
    blocks.push(block);
  }

  // ---------------------------------------------------------------------------
  // 块级语法识别辅助
  // ---------------------------------------------------------------------------

  /** ``` 开头视为围栏开始（允许 3 个以上反引号）。 */
  private isFenceStart(trimmed: string): boolean {
    if (trimmed.length < 3) {
      return false;
    }
    return trimmed.charAt(0) === '`' && trimmed.charAt(1) === '`' && trimmed.charAt(2) === '`';
  }

  /** 只有整行都是 >=3 个反引号才算闭合围栏；代码中的 ```ts 不会被误闭合。 */
  private isFenceClose(trimmed: string): boolean {
    if (trimmed.length < 3) {
      return false;
    }
    for (let i = 0; i < trimmed.length; i++) {
      if (trimmed.charAt(i) !== '`') {
        return false;
      }
    }
    return true;
  }

  /** 取围栏语言名：去掉 3 个反引号后的第一个 token，最长 24 字符。 */
  private fenceLanguage(trimmed: string): string {
    let rest: string = this.trimLeft(trimmed.substring(3));
    let end: number = 0;
    while (end < rest.length) {
      const c: string = rest.charAt(end);
      if (c === ' ' || c === '\t') {
        break;
      }
      end++;
    }
    let lang: string = rest.substring(0, end);
    if (lang.length > 24) {
      lang = lang.substring(0, 24);
    }
    return lang;
  }

  private isDivider(trimmed: string): boolean {
    if (trimmed.length < 3) {
      return false;
    }
    let marker: string = '';
    let count: number = 0;
    for (let i = 0; i < trimmed.length; i++) {
      const c: string = trimmed.charAt(i);
      if (c === ' ' || c === '\t') {
        continue;
      }
      if (c !== '-' && c !== '*' && c !== '_') {
        return false;
      }
      if (marker.length === 0) {
        marker = c;
      } else if (marker !== c) {
        return false;
      }
      count++;
    }
    return count >= 3;
  }

  /** 返回 1 到 6 的标题级别；不是标题返回 0。 */
  private headingLevel(trimmed: string): number {
    if (trimmed.length === 0 || trimmed.charAt(0) !== '#') {
      return 0;
    }
    let count: number = 0;
    while (count < trimmed.length && trimmed.charAt(count) === '#' && count < 7) {
      count++;
    }
    if (count > 6) {
      return 0;
    }
    if (count < trimmed.length) {
      const next: string = trimmed.charAt(count);
      if (next !== ' ' && next !== '\t') {
        return 0;
      }
    }
    return count;
  }

  /** 取标题文字：去掉前导 # 和空格，并去掉“空格 + 结尾 # 序列”的关闭语法。 */
  private headingText(trimmed: string, level: number): string {
    let text: string = this.trimLeft(trimmed.substring(level));
    let end: number = text.length;
    while (end > 0 && text.charAt(end - 1) === '#') {
      end--;
    }
    if (end < text.length) {
      if (end === 0) {
        text = '';
      } else {
        const before: string = text.charAt(end - 1);
        if (before === ' ' || before === '\t') {
          text = text.substring(0, end);
        }
      }
    }
    return text.trim();
  }

  /** 去掉引用标记（支持 > > 多级折叠成一层文本）和其后空白。 */
  private stripQuoteMarkers(trimmed: string): string {
    let text: string = trimmed;
    while (text.length > 0 && text.charAt(0) === '>') {
      text = this.trimLeft(text.substring(1));
    }
    return text;
  }

  /** 前导空格 / 制表符宽度（tab 记 2 个空格）。 */
  private leadingIndentWidth(line: string): number {
    let width: number = 0;
    for (let i = 0; i < line.length; i++) {
      const c: string = line.charAt(i);
      if (c === ' ') {
        width += 1;
      } else if (c === '\t') {
        width += 2;
      } else {
        break;
      }
    }
    return width;
  }

  /** 缩进宽度 -> 层级：每 2 个空格一级，最多 MAX_LIST_INDENT 级。 */
  private indentToLevel(width: number): number {
    let level: number = Math.floor(width / 2);
    if (level > MAX_LIST_INDENT) {
      level = MAX_LIST_INDENT;
    }
    if (level < 0) {
      level = 0;
    }
    return level;
  }

  /** 行首空白去掉。 */
  private trimLeft(value: string): string {
    let i: number = 0;
    while (i < value.length) {
      const c: string = value.charAt(i);
      if (c === ' ' || c === '\t') {
        i++;
      } else {
        break;
      }
    }
    return value.substring(i);
  }

  /** 无序列表项：- / * / + 后必须跟空白或行尾。 */
  private isUnorderedItem(body: string): boolean {
    if (body.length === 0) {
      return false;
    }
    const marker: string = body.charAt(0);
    if (marker !== '-' && marker !== '*' && marker !== '+') {
      return false;
    }
    if (body.length === 1) {
      return true;
    }
    const next: string = body.charAt(1);
    return next === ' ' || next === '\t';
  }

  /**
   * 有序列表 marker 结束位置（数字 + . 或 ) 之后的索引）；
   * 不是有序列表返回 -1。最多接受 9 位数字，且后面必须有空白或行尾。
   */
  private orderedMarkerEnd(body: string): number {
    let digits: number = 0;
    while (digits < body.length && digits < 9) {
      const code: number = body.charCodeAt(digits);
      if (code < 48 || code > 57) {
        break;
      }
      digits++;
    }
    if (digits === 0 || digits >= body.length) {
      return -1;
    }
    const separator: string = body.charAt(digits);
    if (separator !== '.' && separator !== ')') {
      return -1;
    }
    const afterIndex: number = digits + 1;
    if (afterIndex < body.length) {
      const after: string = body.charAt(afterIndex);
      if (after !== ' ' && after !== '\t') {
        return -1;
      }
    }
    return afterIndex;
  }

  /** 纯数字串转正整数（超过 9999 截断），无法解析时返回 1。 */
  private smallPositiveInt(digits: string): number {
    if (digits.length === 0) {
      return 1;
    }
    let value: number = 0;
    for (let i = 0; i < digits.length; i++) {
      const code: number = digits.charCodeAt(i);
      if (code < 48 || code > 57) {
        return 1;
      }
      value = value * 10 + (code - 48);
      if (value > 9999) {
        return 9999;
      }
    }
    if (value < 1) {
      return 1;
    }
    return value;
  }

  // ---------------------------------------------------------------------------
  // 表格解析
  // ---------------------------------------------------------------------------

  /**
   * 从 start 行开始收集一张表：start 是表头，start+1 是对齐行，之后是数据行，
   * 遇到空行 / 不含 | 的行 / 新围栏就结束。返回表格结束后的下一行下标。
   * 每行输出一个 type = 'tableRow' 的 block，列数按整表最大值补空对齐。
   */
  private collectTable(lines: string[], start: number, blocks: MdBlock[]): number {
    const rows: string[][] = [];
    rows.push(this.splitTableCells(this.stripCarriageReturn(lines[start])));
    let i: number = start + 2;
    while (i < lines.length) {
      const rawLine: string = this.stripCarriageReturn(lines[i]);
      const trimmed: string = rawLine.trim();
      if (trimmed.length === 0) {
        break;
      }
      if (trimmed.indexOf('|') < 0) {
        break;
      }
      if (this.isFenceStart(trimmed)) {
        break;
      }
      rows.push(this.splitTableCells(rawLine));
      i++;
    }
    let columnCount: number = 0;
    for (let r = 0; r < rows.length; r++) {
      if (rows[r].length > columnCount) {
        columnCount = rows[r].length;
      }
    }
    if (columnCount === 0) {
      columnCount = 1;
    }
    for (let r = 0; r < rows.length; r++) {
      while (rows[r].length < columnCount) {
        rows[r].push('');
      }
      const block: MdBlock = this.makeBlock(BLOCK_TABLE_ROW);
      // level 复用：1 = 表头行，0 = 数据行
      block.level = r === 0 ? 1 : 0;
      block.cells = rows[r];
      block.index = r;
      blocks.push(block);
    }
    return i;
  }

  /** 拆一行表格：去掉首尾 |，按 | split 后逐格 trim。 */
  private splitTableCells(line: string): string[] {
    let text: string = line.trim();
    if (text.length > 0 && text.charAt(0) === '|') {
      text = text.substring(1);
    }
    if (text.length > 0 && text.charAt(text.length - 1) === '|') {
      text = text.substring(0, text.length - 1);
    }
    const parts: string[] = text.split('|');
    const cells: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      cells.push(parts[i].trim());
    }
    return cells;
  }

  /** 对齐行：每个单元格形如 --- / :--- / ---: / :---:。 */
  private isTableSeparator(trimmed: string): boolean {
    if (trimmed.length === 0 || trimmed.indexOf('|') < 0) {
      return false;
    }
    const cells: string[] = this.splitTableCells(trimmed);
    if (cells.length === 0) {
      return false;
    }
    for (let i = 0; i < cells.length; i++) {
      if (!this.isTableAlignCell(cells[i])) {
        return false;
      }
    }
    return true;
  }

  private isTableAlignCell(cell: string): boolean {
    let text: string = cell.trim();
    if (text.length === 0) {
      return false;
    }
    if (text.charAt(0) === ':') {
      text = text.substring(1);
    }
    let end: number = text.length;
    if (end > 0 && text.charAt(end - 1) === ':') {
      end -= 1;
    }
    if (end <= 0) {
      return false;
    }
    for (let i = 0; i < end; i++) {
      if (text.charAt(i) !== '-') {
        return false;
      }
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // 行内解析（递归扫描，输出 MdSpan 扁平数组；用标志位状态表示嵌套）
  // ---------------------------------------------------------------------------

  /** 行内解析入口。始终至少返回一个 span，保证 Text 里有 Span 子组件。 */
  private parseInline(source: string, depth: number): MdSpan[] {
    const spans: MdSpan[] = [];
    this.scanInline(source, 0, source.length, false, false, false, false, depth, spans);
    if (spans.length === 0) {
      spans.push(this.makeSpan('', false, false, false, false, false));
    }
    return spans;
  }

  /**
   * 扫描 [start, end) 区间：
   *  - 反斜杠转义下一个字符；
   *  - `code`、**bold**、*italic* / _italic_、~~strike~~、[text](url)、裸 URL；
   *  - 未闭合的标记一律按普通字符输出（不会死循环、不会抛异常）；
   *  - 嵌套通过递归 + 标志位传递实现，深度和 token 数都有上限。
   */
  private scanInline(source: string, start: number, end: number, bold: boolean, italic: boolean,
    strike: boolean, link: boolean, depth: number, out: MdSpan[]): void {
    if (start >= end) {
      return;
    }
    // 递归过深时，剩余内容统一降级成纯文本
    if (depth > MAX_INLINE_DEPTH) {
      out.push(this.makeSpan(source.substring(start, end), bold, italic, false, strike, link));
      return;
    }
    let i: number = start;
    let buffer: string = '';
    while (i < end) {
      if (out.length >= MAX_INLINE_SPANS) {
        this.pushPlainSpan(out, buffer, bold, italic, strike, link);
        out.push(this.makeSpan(source.substring(i, end), bold, italic, false, strike, link));
        return;
      }
      const c: string = source.charAt(i);
      // 转义
      if (c === '\\' && i + 1 < end) {
        buffer += source.charAt(i + 1);
        i += 2;
        continue;
      }
      // 行内代码：找下一个反引号；找不到就当普通反引号
      if (c === '`') {
        const closeCode: number = source.indexOf('`', i + 1);
        if (closeCode > i && closeCode < end) {
          this.pushPlainSpan(out, buffer, bold, italic, strike, link);
          buffer = '';
          out.push(this.makeSpan(source.substring(i + 1, closeCode), bold, false, true, false, link));
          i = closeCode + 1;
          continue;
        }
        buffer += c;
        i++;
        continue;
      }
      // 粗体 / 斜体：* 和 _ 都支持；_ 额外做词边界判断，避免 snake_case 被误斜体
      if (c === '*' || c === '_') {
        const canOpen: boolean = this.canOpenEmphasis(source, i, start, end, c);
        if (canOpen && i + 1 < end && source.charAt(i + 1) === c) {
          const boldClose: number = this.findClosingMarker(source, i + 2, end, c + c, start);
          if (boldClose > i + 1) {
            this.pushPlainSpan(out, buffer, bold, italic, strike, link);
            buffer = '';
            this.scanInline(source, i + 2, boldClose, true, italic, strike, link, depth + 1, out);
            i = boldClose + 2;
            continue;
          }
        }
        if (canOpen) {
          const italicClose: number = this.findClosingMarker(source, i + 1, end, c, start);
          if (italicClose > i + 1) {
            this.pushPlainSpan(out, buffer, bold, italic, strike, link);
            buffer = '';
            this.scanInline(source, i + 1, italicClose, bold, true, strike, link, depth + 1, out);
            i = italicClose + 1;
            continue;
          }
        }
        buffer += c;
        i++;
        continue;
      }
      // 删除线 ~~text~~
      if (c === '~' && i + 1 < end && source.charAt(i + 1) === '~') {
        const strikeClose: number = this.findClosingMarker(source, i + 2, end, '~~', start);
        if (strikeClose > i + 1) {
          this.pushPlainSpan(out, buffer, bold, italic, strike, link);
          buffer = '';
          this.scanInline(source, i + 2, strikeClose, bold, italic, true, link, depth + 1, out);
          i = strikeClose + 2;
          continue;
        }
      }
      // 链接 [text](url)：只显示 text，不负责点击跳转
      if (c === '[') {
        const closeBracket: number = source.indexOf(']', i + 1);
        if (closeBracket > i && closeBracket + 1 < end && source.charAt(closeBracket + 1) === '(') {
          const closeParen: number = source.indexOf(')', closeBracket + 2);
          if (closeParen > closeBracket + 2 && closeParen < end) {
            this.pushPlainSpan(out, buffer, bold, italic, strike, link);
            buffer = '';
            this.scanInline(source, i + 1, closeBracket, bold, italic, strike, true, depth + 1, out);
            i = closeParen + 1;
            continue;
          }
        }
        buffer += c;
        i++;
        continue;
      }
      // 裸 URL：http(s):// 开头，自动加链接样式
      if (c === 'h') {
        const urlEnd: number = this.bareUrlEnd(source, i, end);
        if (urlEnd > i) {
          this.pushPlainSpan(out, buffer, bold, italic, strike, link);
          buffer = '';
          out.push(this.makeSpan(source.substring(i, urlEnd), bold, italic, false, strike, true));
          i = urlEnd;
          continue;
        }
      }
      // 普通字符
      buffer += c;
      i++;
    }
    this.pushPlainSpan(out, buffer, bold, italic, strike, link);
  }

  /** 把普通文本 run 追加成 span（空串忽略）。 */
  private pushPlainSpan(out: MdSpan[], text: string, bold: boolean, italic: boolean, strike: boolean,
    link: boolean): void {
    if (text.length === 0) {
      return;
    }
    out.push(this.makeSpan(text, bold, italic, false, strike, link));
  }

  /** 强调开启判断：后面不能是空白；_ 不能在单词内部开启。 */
  private canOpenEmphasis(source: string, markerIndex: number, segmentStart: number, end: number,
    marker: string): boolean {
    if (markerIndex + 1 >= end) {
      return false;
    }
    const next: string = source.charAt(markerIndex + 1);
    if (next === ' ' || next === '\t' || next === '\n') {
      return false;
    }
    if (marker === '_' && markerIndex > segmentStart && this.isWordChar(source.charAt(markerIndex - 1))) {
      return false;
    }
    return true;
  }

  /** 强调关闭判断：前面不能是空白；_ 不能在单词内部关闭。 */
  private canCloseEmphasis(source: string, markerIndex: number, segmentStart: number, end: number,
    marker: string): boolean {
    if (markerIndex <= segmentStart) {
      return false;
    }
    const before: string = source.charAt(markerIndex - 1);
    if (before === ' ' || before === '\t' || before === '\n') {
      return false;
    }
    if (marker === '_' && markerIndex + 1 < end && this.isWordChar(source.charAt(markerIndex + 1))) {
      return false;
    }
    return true;
  }

  /** 从 from 开始找合法的关闭 marker 下标；找不到返回 -1。 */
  private findClosingMarker(source: string, from: number, end: number, marker: string,
    segmentStart: number): number {
    let search: number = from;
    while (search < end) {
      const found: number = source.indexOf(marker, search);
      if (found < 0 || found >= end) {
        return -1;
      }
      if (this.canCloseEmphasis(source, found, segmentStart, end, marker)) {
        return found;
      }
      search = found + 1;
    }
    return -1;
  }

  private isWordChar(c: string): boolean {
    if (c.length !== 1) {
      return false;
    }
    const code: number = c.charCodeAt(0);
    const isLower: boolean = code >= 97 && code <= 122;
    const isUpper: boolean = code >= 65 && code <= 90;
    const isDigit: boolean = code >= 48 && code <= 57;
    return isLower || isUpper || isDigit;
  }

  /** 裸 URL 结束位置；不是 http(s):// 开头返回 start。 */
  private bareUrlEnd(source: string, start: number, end: number): number {
    let prefixLength: number = 0;
    if (this.startsWithAt(source, start, 'https://', end)) {
      prefixLength = 8;
    } else if (this.startsWithAt(source, start, 'http://', end)) {
      prefixLength = 7;
    } else {
      return start;
    }
    let i: number = start + prefixLength;
    while (i < end) {
      const c: string = source.charAt(i);
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
        break;
      }
      if (c === '<' || c === '>' || c === '"' || c === '`' || c === '|' || c === ')' || c === ']' ||
        c === '}' || c === '，' || c === '。' || c === '；' || c === '：' || c === '！' || c === '？' ||
        c === '、' || c === '）' || c === '“' || c === '”') {
        break;
      }
      i++;
    }
    // 去掉句末标点
    while (i > start + prefixLength) {
      const last: string = source.charAt(i - 1);
      if (last === '.' || last === ',' || last === ';' || last === ':' || last === '!' || last === '?' ||
        last === '\'' || last === '’' || last === '】' || last === '》') {
        i--;
      } else {
        break;
      }
    }
    if (i <= start + prefixLength) {
      return start;
    }
    return i;
  }

  private startsWithAt(source: string, start: number, prefix: string, end: number): boolean {
    if (start + prefix.length > end) {
      return false;
    }
    for (let i = 0; i < prefix.length; i++) {
      if (source.charAt(start + i) !== prefix.charAt(i)) {
        return false;
      }
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // 尺寸 / 文本辅助
  // ---------------------------------------------------------------------------

  private headingSize(level: number): number {
    if (level <= 1) {
      return this.fontSize + 8;
    }
    if (level === 2) {
      return this.fontSize + 6;
    }
    if (level === 3) {
      return this.fontSize + 4;
    }
    if (level === 4) {
      return this.fontSize + 2;
    }
    return this.fontSize + 1;
  }

  private monoFontSize(): number {
    return Math.max(11, this.fontSize - 3);
  }

  private monoLineHeight(): number {
    return this.monoFontSize() * 1.5;
  }

  private languageLabelSize(): number {
    return Math.max(10, this.fontSize - 5);
  }

  private tableFontSize(): number {
    return Math.max(11, this.fontSize - 2);
  }

  private countLines(value: string): number {
    let lines: number = 1;
    for (let i = 0; i < value.length; i++) {
      if (value.charAt(i) === '\n') {
        lines++;
      }
    }
    return lines;
  }

  /** 代码块内部 Scroll 的高度：按行数 * 行高 + 余量算，避免 Scroll 在 auto 高度父容器里塌陷。 */
  private codeScrollHeight(code: string): number {
    return this.countLines(code) * this.monoLineHeight() + 8;
  }

  /** 表格 Scroll 的高度：行数 * 单元格高度 + 外边框余量。 */
  private tableScrollHeight(start: number): number {
    return this.tableRowsFrom(start).length * TABLE_CELL_HEIGHT + 4;
  }

  /** 取出从 start 开始连续的 tableRow block（一张表）。 */
  private tableRowsFrom(start: number): MdBlock[] {
    const rows: MdBlock[] = [];
    let i: number = start;
    while (i < this.blocks.length && this.blocks[i].type === BLOCK_TABLE_ROW) {
      rows.push(this.blocks[i]);
      i++;
    }
    return rows;
  }

  private listMarker(block: MdBlock): string {
    if (block.ordered) {
      return block.index.toString() + '.';
    }
    return '•';
  }

  private spanDecoration(span: MdSpan): TextDecorationType {
    if (span.link) {
      return TextDecorationType.Underline;
    }
    if (span.strike) {
      return TextDecorationType.LineThrough;
    }
    return TextDecorationType.None;
  }

  // ---------------------------------------------------------------------------
  // UI：块分发
  // ---------------------------------------------------------------------------

  build() {
    Column() {
      ForEach(this.blocks, (block: MdBlock, index: number) => {
        this.renderBlock(block, index)
      }, (block: MdBlock, index: number): string => this.blockKey(block, index))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  renderBlock(block: MdBlock, index: number) {
    if (block.type === BLOCK_CODE) {
      this.codeBlockView(block, index)
    } else if (block.type === BLOCK_HEADING) {
      this.headingView(block, index)
    } else if (block.type === BLOCK_LIST_ITEM) {
      this.listItemView(block, index)
    } else if (block.type === BLOCK_QUOTE) {
      this.quoteView(block, index)
    } else if (block.type === BLOCK_DIVIDER) {
      this.dividerView(index)
    } else if (block.type === BLOCK_TABLE_ROW) {
      // 表格首行（parser 置 index = 0）负责把整张表渲染成网格；同表其余行不产生 UI
      if (block.index === 0) {
        this.tableView(index)
      }
    } else {
      this.paragraphView(block, index)
    }
  }

  // ---------------------------------------------------------------------------
  // UI：段落 / 标题
  // ---------------------------------------------------------------------------

  @Builder
  paragraphView(block: MdBlock, index: number) {
    this.renderSpans(block.spans, this.paletteValue().textPrimary, this.fontSize, this.fontSize * 1.5,
      false, index === 0 ? 0 : 8)
  }

  @Builder
  headingView(block: MdBlock, index: number) {
    this.renderSpans(block.spans, this.paletteValue().textPrimary, this.headingSize(block.level),
      this.headingSize(block.level) * 1.3, true, index === 0 ? 0 : 14)
  }

  // ---------------------------------------------------------------------------
  // UI：行内 spans（Text 内的 ForEach + Span）
  // ---------------------------------------------------------------------------

  /**
   * 渲染一段行内富文本。每个 Span 都显式设置字号/颜色/字重等属性，
   * 避免依赖 Text 继承造成不同 API 版本表现不一致。
   * code 用 textPrimary 作为代码文字色（Palette 没有 codeText 字段）。
   */
  @Builder
  renderSpans(spans: MdSpan[], color: string, size: number, lineHeight: number, forceBold: boolean,
    topMargin: number) {
    Text() {
      ForEach(spans, (span: MdSpan, spanIndex: number) => {
        Span(span.text)
          .fontSize(span.code ? size - 1 : size)
          .fontColor(span.code ? this.paletteValue().textPrimary :
            (span.link ? this.paletteValue().linkText : color))
          .fontWeight(span.bold || forceBold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(span.code ? MONO_FONT : BODY_FONT_FAMILY)
          .decoration({
            type: this.spanDecoration(span),
            color: span.link ? this.paletteValue().linkText : color
          })
          .textBackgroundStyle({
            color: span.code ? this.paletteValue().codeBackground : Color.Transparent,
            radius: span.code ? 4 : 0
          })
      }, (span: MdSpan, spanIndex: number): string => this.spanKey(span, spanIndex))
    }
    .width('100%')
    .fontSize(size)
    .fontColor(color)
    .lineHeight(lineHeight)
    .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None)
    .margin({ top: topMargin })
  }

  // ---------------------------------------------------------------------------
  // UI：列表
  // ---------------------------------------------------------------------------

  @Builder
  listItemView(block: MdBlock, index: number) {
    Row() {
      Text(this.listMarker(block))
        .fontSize(this.fontSize)
        .fontColor(this.paletteValue().textSecondary)
        .width(block.ordered ? 28 : 16)
        .textAlign(TextAlign.End)
        .lineHeight(this.fontSize * 1.5)
        .margin({ right: 6 })
      Column() {
        this.renderSpans(block.spans, this.paletteValue().textPrimary, this.fontSize, this.fontSize * 1.5,
          false, 0)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 4 + block.level * 16 })
    .margin({
      top: index === 0 ? 0 : (this.blocks[index - 1].type === BLOCK_LIST_ITEM ? 2 : 8)
    })
  }

  // ---------------------------------------------------------------------------
  // UI：引用块 / 水平线
  // ---------------------------------------------------------------------------

  @Builder
  quoteView(block: MdBlock, index: number) {
    Column() {
      this.renderSpans(block.spans, this.paletteValue().textSecondary, this.fontSize, this.fontSize * 1.5,
        false, 0)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .borderWidth({ left: 3 })
    .borderColor(this.paletteValue().quoteBorder)
    .padding({ left: 10, right: 6, top: 2, bottom: 2 })
    .margin({ top: index === 0 ? 0 : 8 })
  }

  @Builder
  dividerView(index: number) {
    Divider()
      .strokeWidth(1)
      .color(this.paletteValue().codeBorder)
      .width('100%')
      .margin({ top: index === 0 ? 0 : 12, bottom: 12 })
  }

  // ---------------------------------------------------------------------------
  // UI：围栏代码块
  // ---------------------------------------------------------------------------

  /**
   * 代码块：整体 Column 作为容器（codeBackground + 顶部 1vp codeBorder + 圆角），
   * 右上角语言名；代码正文放在横向 Scroll 里、等宽字体，不做任何行内解析。
   */
  @Builder
  codeBlockView(block: MdBlock, index: number) {
    Column() {
      if (block.lang.length > 0) {
        Row() {
          Text(block.lang)
            .fontSize(this.languageLabelSize())
            .fontFamily(MONO_FONT)
            .fontColor(this.paletteValue().textTertiary)
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ bottom: 2 })
      }
      Scroll() {
        Text(block.code)
          .fontFamily(MONO_FONT)
          .fontSize(this.monoFontSize())
          .lineHeight(this.monoLineHeight())
          .fontColor(this.paletteValue().textPrimary)
          .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Auto)
      .width('100%')
      .height(this.codeScrollHeight(block.code))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.paletteValue().codeBackground)
    .borderWidth({ top: 1 })
    .borderColor(this.paletteValue().codeBorder)
    .borderRadius(6)
    .padding({ left: 10, right: 10, top: 6, bottom: 8 })
    .margin({ top: index === 0 ? 0 : 10 })
  }

  // ---------------------------------------------------------------------------
  // UI：表格（GFM）
  // ---------------------------------------------------------------------------

  /**
   * 一张表渲染成一个横向 Scroll + 列布局：列多时整体左右滚动，单元格固定宽高，
   * 表头用 surfaceAlt 背景加粗。单元格内容按原始文本展示（不做行内解析，
   * 见文件头说明），过长时最多 2 行省略。
   */
  @Builder
  tableView(start: number) {
    Scroll() {
      Column() {
        ForEach(this.tableRowsFrom(start), (row: MdBlock, rowIndex: number) => {
          this.tableRowView(row, start)
        }, (row: MdBlock, rowIndex: number): string => this.tableRowKey(row, rowIndex, start))
      }
      .alignItems(HorizontalAlign.Start)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Auto)
    .width('100%')
    .height(this.tableScrollHeight(start))
    .borderWidth(1)
    .borderColor(this.paletteValue().codeBorder)
    .margin({ top: start === 0 ? 0 : 10 })
  }

  @Builder
  tableRowView(row: MdBlock, tableStart: number) {
    Row() {
      ForEach(row.cells, (cell: string, cellIndex: number) => {
        Text(cell)
          .width(TABLE_CELL_WIDTH)
          .height(TABLE_CELL_HEIGHT)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .fontSize(this.tableFontSize())
          .lineHeight(this.tableFontSize() * 1.4)
          .fontWeight(row.level === 1 ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(row.level === 1 ? this.paletteValue().textPrimary : this.paletteValue().textSecondary)
          .textAlign(TextAlign.Start)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .backgroundColor(row.level === 1 ? this.paletteValue().surfaceAlt : Color.Transparent)
          .borderWidth({
            right: cellIndex === row.cells.length - 1 ? 0 : 1,
            bottom: 1
          })
          .borderColor(this.paletteValue().codeBorder)
          .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None)
      }, (cell: string, cellIndex: number): string => this.cellKey(cell, cellIndex, row.level, tableStart))
    }
    .alignItems(VerticalAlign.Center)
  }

  private cellKey(cell: string, cellIndex: number, level: number, tableStart: number): string {
    let hash: number = this.hashSeed(19, cell);
    hash = (hash * 13 + cellIndex + level * 7 + tableStart * 11) % HASH_MOD;
    return cellIndex.toString() + '-' + hash.toString();
  }
}
