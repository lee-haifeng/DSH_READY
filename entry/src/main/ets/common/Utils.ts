/**
 * Logging and small pure helpers.
 *
 * Everything here is free of ArkUI imports so it can also be reused from background
 * work and from unit tests.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { LOG_DOMAIN, LOG_TAG } from './Constants';

/** Namespaced logger; the tag suffix identifies the module in `hdc hilog`. */
export class Log {
  private scope: string;

  constructor(scope: string) {
    this.scope = scope;
  }

  info(message: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '[%{public}s] %{public}s', this.scope, message);
  }

  warn(message: string): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, '[%{public}s] %{public}s', this.scope, message);
  }

  error(message: string): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, '[%{public}s] %{public}s', this.scope, message);
  }

  debug(message: string): void {
    hilog.debug(LOG_DOMAIN, LOG_TAG, '[%{public}s] %{public}s', this.scope, message);
  }
}

/**
 * Generate a short unique id.
 *
 * Uses time plus a random suffix rather than a counter so ids stay unique across
 * process restarts without persisting any state.
 */
export function newId(prefix: string): string {
  const now: number = Date.now();
  const rand: number = Math.floor(Math.random() * 0x1000000);
  return `${prefix}_${now.toString(36)}${rand.toString(36)}`;
}

/** Two digit zero padding. */
function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** `HH:mm` in local time. */
export function formatTime(ms: number): string {
  const d: Date = new Date(ms);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** Relative day label: today / yesterday, otherwise a short date. */
export function formatSessionTime(ms: number, todayLabel: string, yesterdayLabel: string): string {
  const d: Date = new Date(ms);
  const now: Date = new Date();
  const startOfToday: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const oneDay: number = 86400000;
  if (ms >= startOfToday) {
    return `${todayLabel} ${formatTime(ms)}`;
  }
  if (ms >= startOfToday - oneDay) {
    return `${yesterdayLabel} ${formatTime(ms)}`;
  }
  if (d.getFullYear() === now.getFullYear()) {
    return `${d.getMonth() + 1}/${d.getDate()}`;
  }
  return `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`;
}

/** Human readable duration, e.g. `1.2s` or `12s`. */
export function formatDuration(ms: number): string {
  if (ms < 1000) {
    return `${ms}ms`;
  }
  const seconds: number = ms / 1000;
  if (seconds < 60) {
    return `${seconds.toFixed(1)}s`;
  }
  const minutes: number = Math.floor(seconds / 60);
  return `${minutes}m${Math.round(seconds - minutes * 60)}s`;
}

/** Compact token count, e.g. `12.4k`. */
export function formatTokens(count: number): string {
  if (count < 1000) {
    return `${count}`;
  }
  if (count < 1000000) {
    return `${(count / 1000).toFixed(1)}k`;
  }
  return `${(count / 1000000).toFixed(2)}M`;
}

/** Collapse runs of whitespace and clip to `max` characters. */
export function clip(text: string, max: number): string {
  const flat: string = text.replace(/\s+/g, ' ').trim();
  if (flat.length <= max) {
    return flat;
  }
  return `${flat.slice(0, max)}…`;
}

/** True when the string is empty or only whitespace. */
export function isBlank(text: string): boolean {
  return text.trim().length === 0;
}

/** Safe JSON parse that never throws; returns the fallback on any failure. */
export function parseJsonSafe<T>(raw: string, fallback: T): T {
  try {
    const value: T = JSON.parse(raw) as T;
    if (value === null || value === undefined) {
      return fallback;
    }
    return value;
  } catch (e) {
    return fallback;
  }
}

/** Whether a string looks like an absolute http(s) URL. */
export function isHttpUrl(text: string): boolean {
  return text.startsWith('http://') || text.startsWith('https://');
}

/** UTF-8 byte length, used to keep request bodies under provider limits. */
export function utf8ByteLength(text: string): number {
  const encoder: util.TextEncoder = new util.TextEncoder();
  return encoder.encodeInto(text).length;
}

/** Encode a string to UTF-8 bytes. */
export function encodeUtf8(text: string): Uint8Array {
  const encoder: util.TextEncoder = new util.TextEncoder();
  return encoder.encodeInto(text);
}

/** Build a streaming text decoder for SSE chunks that may split a code point. */
export function createStreamDecoder(): util.TextDecoder {
  const options: util.TextDecoderOptions = { fatal: false, ignoreBOM: true };
  return util.TextDecoder.create('utf-8', options);
}
