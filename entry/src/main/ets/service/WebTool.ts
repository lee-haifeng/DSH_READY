/**
 * Network tools: page fetch and web search.
 *
 * Phone builds have no shell, so the web tools are the only way the agent can touch
 * the outside world. Both go through `@ohos.net.http` and degrade to a readable error
 * string rather than throwing, because a failed search should never kill a turn.
 */

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Utils';

const log = new Log('Web');

/** A single search hit. */
export interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}

const BROWSER_UA: string =
  'Mozilla/5.0 (Phone; OpenHarmony) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/** Decode the handful of HTML entities that show up in text content. */
export function decodeEntities(text: string): string {
  let out: string = text;
  out = out.replace(/&nbsp;/g, ' ');
  out = out.replace(/&amp;/g, '&');
  out = out.replace(/&lt;/g, '<');
  out = out.replace(/&gt;/g, '>');
  out = out.replace(/&quot;/g, '"');
  out = out.replace(/&#39;/g, '\'');
  out = out.replace(/&#x27;/g, '\'');
  out = out.replace(/&#x2F;/g, '/');
  out = out.replace(/&#(\d{2,5});/g, (match: string, code: string) => {
    const value: number = parseInt(code, 10);
    return value > 0 && value < 65536 ? String.fromCharCode(value) : match;
  });
  return out;
}

/** Remove markup and collapse whitespace, so the model reads prose instead of tags. */
export function htmlToText(html: string): string {
  let text: string = html;
  text = text.replace(/<script[\s\S]*?<\/script>/gi, ' ');
  text = text.replace(/<style[\s\S]*?<\/style>/gi, ' ');
  text = text.replace(/<noscript[\s\S]*?<\/noscript>/gi, ' ');
  text = text.replace(/<svg[\s\S]*?<\/svg>/gi, ' ');
  text = text.replace(/<!--[\s\S]*?-->/g, ' ');
  text = text.replace(/<\/(p|div|li|tr|h[1-6]|section|article|header|footer|blockquote)>/gi, '\n');
  text = text.replace(/<br\s*\/?>/gi, '\n');
  text = text.replace(/<[^>]+>/g, ' ');
  text = decodeEntities(text);
  text = text.replace(/[ \t\u00A0]+/g, ' ');
  text = text.replace(/\n\s*\n\s*\n+/g, '\n\n');
  return text.trim();
}

/** Strip tags inside a short HTML fragment without adding line breaks. */
function inlineText(html: string): string {
  const stripped: string = html.replace(/<[^>]+>/g, '');
  return decodeEntities(stripped).replace(/\s+/g, ' ').trim();
}

/** Run one non-streaming GET and return the body, or a readable failure. */
async function httpGet(url: string, acceptLanguage: string): Promise<string> {
  const request: http.HttpRequest = http.createHttp();
  const headers: Record<string, string> = {};
  headers['User-Agent'] = BROWSER_UA;
  headers['Accept'] = 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8';
  headers['Accept-Language'] = acceptLanguage;
  const options: http.HttpRequestOptions = {
    method: http.RequestMethod.GET,
    header: headers,
    connectTimeout: 20000,
    readTimeout: 45000,
    expectDataType: http.HttpDataType.STRING
  };
  try {
    const response: http.HttpResponse = await request.request(url, options);
    const code: number = response.responseCode;
    const body: string = typeof response.result === 'string' ? response.result as string : '';
    if (code >= 400) {
      return `__ERROR__ HTTP ${code} for ${url}`;
    }
    return body;
  } catch (e) {
    const err = e as BusinessError;
    log.warn(`GET ${url} failed: ${err.code} ${err.message}`);
    return `__ERROR__ network failure (${err.code}) for ${url}`;
  } finally {
    request.destroy();
  }
}

/** Fetch a URL and return readable text. */
export async function fetchPage(url: string, maxChars: number): Promise<string> {
  const target: string = url.trim();
  if (!target.startsWith('http://') && !target.startsWith('https://')) {
    return 'Only absolute http(s) URLs are supported.';
  }
  const body: string = await httpGet(target, 'zh-CN,zh;q=0.9,en;q=0.8');
  if (body.startsWith('__ERROR__')) {
    return body.replace('__ERROR__ ', '');
  }
  const text: string = htmlToText(body);
  if (text.length === 0) {
    return 'The page returned no readable text.';
  }
  if (text.length <= maxChars) {
    return text;
  }
  return `${text.slice(0, maxChars)}\n\n[truncated: ${text.length - maxChars} more characters]`;
}

/** Recover the destination URL from DuckDuckGo's redirect wrapper. */
function unwrapDuckUrl(href: string): string {
  const marker: string = 'uddg=';
  const at: number = href.indexOf(marker);
  if (at < 0) {
    if (href.startsWith('//')) {
      return `https:${href}`;
    }
    return href;
  }
  const rest: string = href.slice(at + marker.length);
  const amp: number = rest.indexOf('&');
  const encoded: string = amp >= 0 ? rest.slice(0, amp) : rest;
  try {
    return decodeURIComponent(encoded);
  } catch (e) {
    return encoded;
  }
}

/** Parse DuckDuckGo HTML results. */
function parseDuckDuckGo(html: string, limit: number): Array<SearchResult> {
  const results: Array<SearchResult> = [];
  const anchorPattern: RegExp = /<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi;
  const snippetPattern: RegExp = /<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)<\/a>/gi;
  const snippets: Array<string> = [];
  let snippetMatch: RegExpExecArray | null = snippetPattern.exec(html);
  while (snippetMatch !== null) {
    snippets.push(inlineText(snippetMatch[1]));
    snippetMatch = snippetPattern.exec(html);
  }
  let match: RegExpExecArray | null = anchorPattern.exec(html);
  let index: number = 0;
  while (match !== null && results.length < limit) {
    const url: string = unwrapDuckUrl(decodeEntities(match[1]));
    const title: string = inlineText(match[2]);
    const snippet: string = index < snippets.length ? snippets[index] : '';
    if (url.length > 0 && title.length > 0) {
      results.push({ title: title, url: url, snippet: snippet });
    }
    index++;
    match = anchorPattern.exec(html);
  }
  return results;
}

/** Parse Bing's result list. */
function parseBing(html: string, limit: number): Array<SearchResult> {
  const results: Array<SearchResult> = [];
  const pattern: RegExp = /<li class="b_algo"[\s\S]*?<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?(?:<p[^>]*>([\s\S]*?)<\/p>)?/gi;
  let match: RegExpExecArray | null = pattern.exec(html);
  while (match !== null && results.length < limit) {
    const url: string = decodeEntities(match[1]);
    const title: string = inlineText(match[2]);
    const snippetHtml: string = match[3] === undefined ? '' : match[3];
    const snippet: string = inlineText(snippetHtml);
    if (url.startsWith('http') && title.length > 0) {
      results.push({ title: title, url: url, snippet: snippet });
    }
    match = pattern.exec(html);
  }
  return results;
}

/** Last resort: every external link on the page, de-duplicated. */
function parseLooseLinks(html: string, limit: number): Array<SearchResult> {
  const results: Array<SearchResult> = [];
  const seen: Set<string> = new Set();
  const pattern: RegExp = /<a[^>]*href="(https?:\/\/[^"]+)"[^>]*>([\s\S]*?)<\/a>/gi;
  let match: RegExpExecArray | null = pattern.exec(html);
  while (match !== null && results.length < limit) {
    const url: string = decodeEntities(match[1]);
    const title: string = inlineText(match[2]);
    if (title.length > 8 && !seen.has(url)) {
      seen.add(url);
      results.push({ title: title, url: url, snippet: '' });
    }
    match = pattern.exec(html);
  }
  return results;
}

/**
 * Search the web.
 *
 * @param query user query, forwarded as-is
 * @param provider `duckduckgo` or `bing`
 * @param limit maximum results
 * @returns results plus a note when the primary parser found nothing
 */
export async function searchWeb(query: string, provider: string, limit: number): Promise<Array<SearchResult>> {
  const encoded: string = encodeURIComponent(query);
  const wantsBing: boolean = provider === 'bing';
  const primaryUrl: string = wantsBing
    ? `https://www.bing.com/search?q=${encoded}&setlang=zh-Hans`
    : `https://html.duckduckgo.com/html/?q=${encoded}`;
  const primary: string = await httpGet(primaryUrl, 'zh-CN,zh;q=0.9,en;q=0.8');
  if (!primary.startsWith('__ERROR__')) {
    const parsed: Array<SearchResult> = wantsBing ? parseBing(primary, limit) : parseDuckDuckGo(primary, limit);
    if (parsed.length > 0) {
      return parsed;
    }
  }
  // Fall back to the other engine before giving up.
  const fallbackUrl: string = wantsBing
    ? `https://html.duckduckgo.com/html/?q=${encoded}`
    : `https://www.bing.com/search?q=${encoded}&setlang=zh-Hans`;
  const fallback: string = await httpGet(fallbackUrl, 'zh-CN,zh;q=0.9,en;q=0.8');
  if (!fallback.startsWith('__ERROR__')) {
    const parsed: Array<SearchResult> = wantsBing ? parseDuckDuckGo(fallback, limit) : parseBing(fallback, limit);
    if (parsed.length > 0) {
      return parsed;
    }
    const loose: Array<SearchResult> = parseLooseLinks(fallback, limit);
    if (loose.length > 0) {
      return loose;
    }
  }
  if (primary.startsWith('__ERROR__')) {
    log.warn(primary);
  }
  return [];
}

/** Format results for the model. */
export function formatResults(query: string, results: Array<SearchResult>): string {
  if (results.length === 0) {
    return `No results found for "${query}". The search engine may be unreachable or the query too narrow.`;
  }
  const lines: Array<string> = [`Search results for "${query}":`];
  for (let i = 0; i < results.length; i++) {
    const item: SearchResult = results[i];
    lines.push(`${i + 1}. ${item.title}`);
    lines.push(`   ${item.url}`);
    if (item.snippet.length > 0) {
      lines.push(`   ${item.snippet}`);
    }
  }
  return lines.join('\n');
}
