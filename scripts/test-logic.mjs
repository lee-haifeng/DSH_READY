/**
 * Logic tests for the pure parts of the app.
 *
 * ArkUI components can only be verified on a device, but the two modules that decide
 * *what* the chat screen shows — the wire model types and the conversation → render
 * mapping — are plain TypeScript. Node can run them directly via type stripping, so
 * this script copies them to a temp directory (rewriting only the import specifier),
 * imports them, and asserts behaviour. There is no second copy of the logic to drift.
 *
 * Usage:  node scripts/test-logic.mjs
 */

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const ROOT = new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const ETS = join(ROOT, 'entry', 'src', 'main', 'ets');
const OUT = join(tmpdir(), 'dsh-ready-logic-test');

let passed = 0;
let failed = 0;

function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    passed += 1;
    return;
  }
  failed += 1;
  console.error(`FAIL ${name}\n  expected ${e}\n  actual   ${a}`);
}

function ok(name, condition, detail) {
  if (condition) {
    passed += 1;
    return;
  }
  failed += 1;
  console.error(`FAIL ${name}${detail === undefined ? '' : `\n  ${detail}`}`);
}

/** Copy one module into the temp dir, rewriting relative specifiers to .ts files. */
function stage(relative, name) {
  const source = readFileSync(join(ETS, relative), 'utf8');
  const rewritten = source
    .replace(/from '\.\.\/(?:common|model|service|view)\/([A-Za-z]+)'/g, "from './$1.ts'")
    .replace(/from '\.\/([A-Za-z]+)'/g, "from './$1.ts'");
  writeFileSync(join(OUT, name), rewritten, 'utf8');
}

/**
 * Node strips `export interface` declarations, so a value import of an interface name
 * fails at link time. Split each `from './Types.ts'` import into its value and type
 * halves by reading which names Types declares as interfaces.
 */
function typeNamesOf(source) {
  const names = new Set();
  const pattern = /export interface (\w+)/g;
  let match = pattern.exec(source);
  while (match !== null) {
    names.add(match[1]);
    match = pattern.exec(source);
  }
  return names;
}

function splitTypeImports(file, types) {
  const source = readFileSync(file, 'utf8');
  const pattern = /import \{([^}]+)\} from '\.\/Types\.ts';/;
  const match = pattern.exec(source);
  if (match === null) {
    return;
  }
  const names = match[1].split(',').map((n) => n.trim()).filter((n) => n.length > 0);
  const values = names.filter((n) => !types.has(n));
  const typeOnly = names.filter((n) => types.has(n));
  const lines = [];
  if (values.length > 0) {
    lines.push(`import { ${values.join(', ')} } from './Types.ts';`);
  }
  if (typeOnly.length > 0) {
    lines.push(`import type { ${typeOnly.join(', ')} } from './Types.ts';`);
  }
  writeFileSync(file, source.replace(pattern, lines.join('\n')), 'utf8');
}

mkdirSync(OUT, { recursive: true });
stage(join('model', 'Types.ets'), 'Types.ts');
stage(join('model', 'Render.ets'), 'Render.ts');
stage(join('common', 'TextRank.ets'), 'TextRank.ts');
stage(join('common', 'FactParse.ets'), 'FactParse.ts');
stage(join('model', 'Transcript.ets'), 'Transcript.ts');
stage(join('common', 'Vector.ets'), 'Vector.ts');

const typeNames = typeNamesOf(readFileSync(join(OUT, 'Types.ts'), 'utf8'));
splitTypeImports(join(OUT, 'Render.ts'), typeNames);
splitTypeImports(join(OUT, 'Transcript.ts'), typeNames);

const { buildRenderItems, textLength } = await import(pathToFileURL(join(OUT, 'Render.ts')).href);
const Types = await import(pathToFileURL(join(OUT, 'Types.ts')).href);
const { tokenize, relevance, rank, similarity, scoreWithKeywords, combineScore, SEMANTIC_FLOOR } =
  await import(pathToFileURL(join(OUT, 'TextRank.ts')).href);
const { dot, norm, cosine, unit, toVector, isVector } =
  await import(pathToFileURL(join(OUT, 'Vector.ts')).href);
const { clipText, parseFacts } = await import(pathToFileURL(join(OUT, 'FactParse.ts')).href);
const { buildTranscript } = await import(pathToFileURL(join(OUT, 'Transcript.ts')).href);

/* ------------------------------------------------------------------ fixtures */

function userMessage(id, text) {
  return {
    id,
    role: Types.ROLE_USER,
    blocks: [{ kind: Types.BLOCK_TEXT, text }],
    createdAt: 1
  };
}

function assistantMessage(id, blocks) {
  return {
    id,
    role: Types.ROLE_ASSISTANT,
    blocks,
    createdAt: 2,
    durationMs: 1200,
    usage: { inputTokens: 10, outputTokens: 20, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 30 }
  };
}

function toolMessage(id, toolCallId, name, text, isError) {
  return {
    id,
    role: Types.ROLE_TOOL,
    blocks: [{ kind: Types.BLOCK_TEXT, text }],
    createdAt: 3,
    toolCallId,
    toolName: name,
    toolSummary: 'summary',
    isError
  };
}

/* ------------------------------------------------------- basic conversation */

{
  const items = buildRenderItems([userMessage('u1', 'hi'), assistantMessage('a1', [{ kind: Types.BLOCK_TEXT, text: 'hello' }])]);
  check('two rows', items.length, 2);
  check('row kinds', items.map((i) => i.kind), ['user', 'assistant']);
  check('assistant text', textLength(items[1]), 5);
}

/* ------------------------------------------- ordering: reasoning before prose */

{
  const items = buildRenderItems([
    assistantMessage('a1', [
      { kind: Types.BLOCK_REASONING, text: 'thinking...' },
      { kind: Types.BLOCK_TEXT, text: 'answer' }
    ])
  ]);
  check('part order', items[0].parts.map((p) => p.kind), ['reasoning', 'text']);
}

/* ------------------------------------------------- tool calls fold with results */

{
  const call = { kind: Types.BLOCK_TOOL_CALL, toolCallId: 't1', toolName: 'web_search', toolArguments: '{"query":"x"}' };
  const items = buildRenderItems([
    userMessage('u1', 'search'),
    assistantMessage('a1', [{ kind: Types.BLOCK_TEXT, text: 'let me look' }, call]),
    toolMessage('m1', 't1', 'web_search', 'results here', false),
    assistantMessage('a2', [{ kind: Types.BLOCK_TEXT, text: 'done' }])
  ]);
  check('rows after tool', items.length, 3);
  const withTool = items.find((i) => i.kind === 'assistant');
  check('tool count', withTool.tools.length, 1);
  check('tool name', withTool.tools[0].name, 'web_search');
  check('tool state', withTool.tools[0].state, 'done');
  check('tool result', withTool.tools[0].resultText, 'results here');
  check('tool part present', withTool.parts.filter((p) => p.kind === 'tool').length, 1);
  ok('tool part index valid', withTool.parts.find((p) => p.kind === 'tool').toolIndex === 0);
}

/* --------------------------------------------------- unanswered call stays running */

{
  const call = { kind: Types.BLOCK_TOOL_CALL, toolCallId: 't2', toolName: 'web_fetch', toolArguments: '{}' };
  const items = buildRenderItems([assistantMessage('a1', [call])]);
  check('pending tool state', items[0].tools[0].state, 'running');
  check('pending tool result', items[0].tools[0].resultText, '');
}

/* ------------------------------------------------------------- error tool result */

{
  const call = { kind: Types.BLOCK_TOOL_CALL, toolCallId: 't3', toolName: 'web_fetch', toolArguments: '{}' };
  const items = buildRenderItems([assistantMessage('a1', [call]), toolMessage('m1', 't3', 'web_fetch', 'boom', true)]);
  check('error state', items[0].tools[0].state, 'error');
  check('error flag', items[0].tools[0].isError, true);
}

/* --------------------------------------------------------- orphan and edge cases */

{
  check('empty log', buildRenderItems([]).length, 0);
  // A tool result with no owning assistant turn must not crash or create a row.
  const orphan = buildRenderItems([toolMessage('m1', 'nope', 'x', 'y', false)]);
  check('orphan tool ignored', orphan.length, 0);
  // Empty text blocks are dropped.
  const empty = buildRenderItems([assistantMessage('a1', [{ kind: Types.BLOCK_TEXT, text: '' }])]);
  check('empty text dropped', empty[0].parts.length, 0);
  // Consecutive user messages are independent rows.
  const users = buildRenderItems([userMessage('u1', 'a'), userMessage('u2', 'b')]);
  check('two user rows', users.length, 2);
}

/* --------------------------------------------------------------- system notices */

{
  const system = { id: 'n1', role: Types.ROLE_SYSTEM, blocks: [{ kind: Types.BLOCK_TEXT, text: 'round 2' }], createdAt: 9 };
  const items = buildRenderItems([userMessage('u1', 'x'), system, assistantMessage('a1', [{ kind: Types.BLOCK_TEXT, text: 'y' }])]);
  check('system row', items.map((i) => i.kind), ['user', 'system', 'assistant']);
}

/* ------------------------------------------------------------------- images */

{
  const image = { kind: Types.BLOCK_IMAGE, uri: '/tmp/a.jpg', mediaType: 'image/jpeg', name: 'a.jpg' };
  const items = buildRenderItems([{ id: 'u1', role: Types.ROLE_USER, blocks: [image], createdAt: 1 }]);
  check('image collected', items[0].images.length, 1);
  check('image keeps uri', items[0].images[0].uri, '/tmp/a.jpg');
}

/* ------------------------------------------------------------- recall ranking */

{
  // Chinese has no spaces: runs of CJK characters become character bigrams.
  check('cjk bigrams', tokenize('鸿蒙项目'), ['鸿蒙', '蒙项', '项目']);
  check('latin words', tokenize('Hello, World!'), ['hello', 'world']);
  check('mixed script', tokenize('用 ArkTS 写'), ['用', 'arkts', '写']);
  check('empty text', tokenize(''), []);
  check('punctuation only', tokenize('，。！'), []);

  const relevant = relevance('鸿蒙 项目', '用户在做一个鸿蒙项目，基于 DeepSeek Harness');
  ok('relevant > 0', relevant > 0, `got ${relevant}`);
  check('unrelated => 0', relevance('天气预报', '用户在做一个鸿蒙项目'), 0);
  check('empty query => 0', relevance('', '任何内容'), 0);

  // A precise short fact must outrank a long rambling one that mentions the term once.
  const candidates = [
    '用户在做一个鸿蒙项目，还聊了很多别的事情，天气、咖啡、通勤路线、周末计划等等等等',
    '用户偏好用中文回复'
  ];
  const order = rank('鸿蒙项目', candidates, 5);
  check('rank picks the project', order, [0]);
  const order2 = rank('中文', candidates, 5);
  check('rank picks the preference', order2, [1]);
  check('rank limit respected', rank('用户', candidates, 1).length, 1);
  check('rank drops zero scores', rank('完全无关的词汇', candidates, 5), []);
}

/* ------------------------------------------------------- fact extraction */

{
  const texts = (facts) => facts.map((f) => f.text);

  check('clip keeps short text', clipText('abc', 10), 'abc');
  check('clip truncates', clipText('abcdef', 3), 'abc…');
  check('clip trims', clipText('  ab  ', 10), 'ab');

  check('plain array', texts(parseFacts('["A fact","B fact"]', 3, 200)), ['A fact', 'B fact']);
  check('fenced array', texts(parseFacts('```json\n["Fenced fact"]\n```', 3, 200)), ['Fenced fact']);
  check('prose around array', texts(parseFacts('Here you go: ["Wrapped fact"] — done', 3, 200)), ['Wrapped fact']);
  check('empty array', parseFacts('[]', 3, 200), []);
  check('no json at all', parseFacts('I could not find anything.', 3, 200), []);
  check('broken json', parseFacts('["unclosed"', 3, 200), []);
  check('non strings dropped', texts(parseFacts('["ab", 3, null, "Real fact here"]', 3, 200)), ['Real fact here']);
  check('duplicates dropped', texts(parseFacts('["Same fact","same fact"]', 3, 200)), ['Same fact']);
  check('respects max facts', texts(parseFacts('["a1b2","b2c3","c3d4","d4e5"]', 2, 200)), ['a1b2', 'b2c3']);
  check('respects max chars', texts(parseFacts('["0123456789"]', 3, 4)), ['0123…']);

  // Enriched shape: synonyms travel with the fact.
  const enriched = parseFacts('[{"fact":"用户在做鸿蒙移植","keywords":["鸿蒙","移植"]}]', 3, 200);
  check('object fact text', enriched[0].text, '用户在做鸿蒙移植');
  check('object fact keywords', enriched[0].keywords, ['鸿蒙', '移植']);

  // Models sometimes use another field name; accept it rather than losing the fact.
  check('text field alias', parseFacts('[{"text":"The user prefers Chinese"}]', 3, 200)[0].text,
    'The user prefers Chinese');
  check('content field alias', parseFacts('[{"content":"The user runs HarmonyOS"}]', 3, 200)[0].text,
    'The user runs HarmonyOS');

  // Keyword hygiene: drop junk, de-duplicate, cap the list.
  check('keywords filtered', parseFacts('[{"fact":"Some fact here","keywords":["ab","","a",3]}]', 3, 200)[0].keywords,
    ['ab']);
  check('keywords deduped', parseFacts('[{"fact":"Some fact here","keywords":["same","Same"]}]', 3, 200)[0].keywords,
    ['same']);
  check('keywords capped', parseFacts('[{"fact":"Some fact here","keywords":["k1","k2","k3","k4","k5"]}]', 3, 200)[0].keywords,
    ['k1', 'k2', 'k3', 'k4']);

  // Mixed array: a model may answer in both shapes at once.
  const mixed = parseFacts('["Plain fact",{"fact":"Object fact","keywords":["kw"]}]', 3, 200);
  check('mixed shapes', texts(mixed), ['Plain fact', 'Object fact']);
  check('mixed keywords', mixed[1].keywords, ['kw']);
}

/* ------------------------------------------------------------ fuzzy match */

{
  ok('identical is 1', similarity('鸿蒙移植', '鸿蒙移植') === 1);
  ok('prefix overlap is high', similarity('鸿蒙移植', '鸿蒙移植项目') > 0.5,
    `${similarity('鸿蒙移植', '鸿蒙移植项目')}`);
  ok('related phrasing overlaps', similarity('鸿蒙移植项目', '移植鸿蒙项目') > 0.3,
    `${similarity('鸿蒙移植项目', '移植鸿蒙项目')}`);
  check('unrelated is 0', similarity('鸿蒙移植', '天气预报'), 0);
  check('too short is 0', similarity('a', 'ab'), 0);
  ok('latin typo still matches', similarity('harmonyos', 'harmonyso') > 0.4,
    `${similarity('harmonyos', 'harmonyso')}`);
}

/* -------------------------------------------------- memory scoring tiers */

{
  ok('literal overlap scores', scoreWithKeywords('鸿蒙项目', '用户在做一个鸿蒙项目', []) > 0);
  // The whole point of stored synonyms: the wording never appears in the fact itself.
  ok('synonym bridges wording', scoreWithKeywords('锻炼', '用户喜欢健身', ['锻炼', '运动']) > 0,
    `${scoreWithKeywords('锻炼', '用户喜欢健身', ['锻炼', '运动'])}`);
  check('without synonyms it misses', scoreWithKeywords('锻炼', '用户喜欢健身', []), 0);
  ok('synonym outranks incidental hit',
    scoreWithKeywords('健身', '用户喜欢健身', ['健身']) > scoreWithKeywords('健身', '用户喜欢健身', []));
  ok('typo still matches via fuzzy', scoreWithKeywords('harmonyos', 'harmonyso', []) > 0,
    `${scoreWithKeywords('harmonyos', 'harmonyso', [])}`);
  check('unrelated scores zero', scoreWithKeywords('天气预报', '用户喜欢健身', ['锻炼']), 0);
}

/* ------------------------------------------------ reserved vector recall */

{
  check('dot', dot([1, 2, 3], [4, 5, 6]), 32);
  check('dot mismatch', dot([1, 2], [1]), 0);
  check('norm', norm([3, 4]), 5);
  check('cosine identical', cosine([1, 0], [1, 0]), 1);
  check('cosine orthogonal', cosine([1, 0], [0, 1]), 0.5);
  check('cosine opposite', cosine([1, 0], [-1, 0]), 0);
  check('cosine mismatch', cosine([1, 0], [1, 0, 0]), 0);
  check('cosine zero vector', cosine([0, 0], [1, 1]), 0);
  check('cosine scale invariant', cosine([2, 0], [5, 0]), 1);
  check('unit', unit([3, 4]), [0.6, 0.8]);
  check('unit of zero', unit([0, 0]), [0, 0]);

  ok('toVector accepts numbers', JSON.stringify(toVector([0.5, 1])) === '[0.5,1]');
  check('toVector rejects empty', toVector([]), undefined);
  check('toVector rejects strings', toVector(['a', 'b']), undefined);
  check('toVector rejects scalar', toVector(3), undefined);
  ok('isVector true for numbers', isVector([1, 2]) === true);

  // Blending rules: semantic wins only when strong enough and genuinely better.
  check('semantic replaces weak lexical', combineScore(0.3, 0.9), 0.9);
  check('lexical kept when better', combineScore(0.95, 0.9), 0.95);
  check('semantic below floor ignored', combineScore(0.2, SEMANTIC_FLOOR - 0.01), 0.2);
  check('no semantic means lexical', combineScore(0.42, 0), 0.42);
}

/* ------------------------------------------------------------ transcripts */

{
  const session = {
    id: 's1',
    title: 'T',
    createdAt: 1,
    updatedAt: 1,
    messages: [
      { id: 'm1', role: 'user', blocks: [{ kind: 'text', text: 'I am building a HarmonyOS port' }], createdAt: 1 },
      { id: 'm2', role: 'assistant', blocks: [{ kind: 'text', text: 'Nice, tell me more' }], createdAt: 1 },
      { id: 'm3', role: 'tool', blocks: [{ kind: 'text', text: 'tool output' }], createdAt: 1, toolCallId: 't1' },
      { id: 'm4', role: 'system', blocks: [{ kind: 'text', text: 'round 2' }], createdAt: 1 },
      { id: 'm5', role: 'user', blocks: [{ kind: 'text', text: '' }], createdAt: 1 }
    ],
    modelId: '',
    effort: '',
    todos: [],
    preview: ''
  };
  const transcript = buildTranscript(session, 0, 500, 6000);
  check('roles and filtering', transcript, 'User: I am building a HarmonyOS port\nAssistant: Nice, tell me more');

  const long = {
    id: 's2',
    title: 'T',
    createdAt: 1,
    updatedAt: 1,
    messages: [
      { id: 'm1', role: 'user', blocks: [{ kind: 'text', text: 'x'.repeat(200) }], createdAt: 1 }
    ],
    modelId: '',
    effort: '',
    todos: [],
    preview: ''
  };
  const clipped = buildTranscript(long, 0, 10, 6000);
  ok('message clipped', clipped.endsWith('…') && clipped.length < 40, clipped);

  const many = {
    id: 's3',
    title: 'T',
    createdAt: 1,
    updatedAt: 1,
    messages: [
      { id: 'm1', role: 'user', blocks: [{ kind: 'text', text: 'aaa' }], createdAt: 1 },
      { id: 'm2', role: 'assistant', blocks: [{ kind: 'text', text: 'bbb' }], createdAt: 1 },
      { id: 'm3', role: 'user', blocks: [{ kind: 'text', text: 'ccc' }], createdAt: 1 }
    ],
    modelId: '',
    effort: '',
    todos: [],
    preview: ''
  };
  const tail = buildTranscript(many, 0, 500, 25);
  ok('budget keeps the tail', tail.indexOf('ccc') >= 0 && tail.indexOf('aaa') < 0, tail);
  check('fromIndex skips earlier turns', buildTranscript(many, 2, 500, 6000), 'User: ccc');
}

/* ---------------------------------------------------------------------- report */

console.log(`\nlogic tests: ${passed} passed, ${failed} failed`);
process.exitCode = failed === 0 ? 0 : 1;