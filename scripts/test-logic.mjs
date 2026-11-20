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
const OUT = join(tmpdir(), 'dsh-mobile-logic-test');

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
  const rewritten = source.replace(/from '\.\/([A-Za-z]+)'/g, "from './$1.ts'");
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
splitTypeImports(join(OUT, 'Render.ts'), typeNamesOf(readFileSync(join(OUT, 'Types.ts'), 'utf8')));

const { buildRenderItems, textLength } = await import(pathToFileURL(join(OUT, 'Render.ts')).href);
const Types = await import(pathToFileURL(join(OUT, 'Types.ts')).href);

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

/* ---------------------------------------------------------------------- report */

console.log(`\nlogic tests: ${passed} passed, ${failed} failed`);
process.exitCode = failed === 0 ? 0 : 1;
