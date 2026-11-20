/**
 * Error code → user-facing message.
 *
 * The client speaks the adapter's stable error vocabulary (`AUTH`, `RATE_LIMIT`, …).
 * Centralising the mapping keeps the chat screen free of code strings.
 */

import { translate } from '../i18n/Strings';

/** i18n key for a normalised error code. */
export function errorKey(code: string): string {
  if (code === 'AUTH' || code === 'INVALID_CREDENTIAL') {
    return 'error.auth';
  }
  if (code === 'MISSING_CREDENTIAL' || code === 'NO_API_KEY') {
    return 'error.noApiKey';
  }
  if (code === 'QUOTA') {
    return 'error.quota';
  }
  if (code === 'RATE_LIMIT') {
    return 'error.rateLimit';
  }
  if (code === 'CONTEXT_WINDOW_EXCEEDED') {
    return 'error.contextWindow';
  }
  if (code === 'INVALID_REQUEST' || code === 'UNSUPPORTED_CONTENT' || code === 'UNSUPPORTED_REASONING_EFFORT') {
    return 'error.invalidRequest';
  }
  if (code === 'SERVER' || code === 'HTTP_502' || code === 'HTTP_503') {
    return 'error.server';
  }
  if (code === 'TIMEOUT') {
    return 'error.timeout';
  }
  if (code === 'ABORTED') {
    return 'error.aborted';
  }
  if (code === 'EMPTY_RESPONSE') {
    return 'error.emptyResponse';
  }
  if (code === 'CONTENT_REFUSED') {
    return 'error.contentRefused';
  }
  if (code === 'MALFORMED_RESPONSE' || code === 'STREAM_CLOSED') {
    return 'error.streamClosed';
  }
  if (code === 'ROUND_LIMIT') {
    return 'chat.roundLimit';
  }
  if (code === 'NETWORK' || code === 'TLS' || code === 'DOMAIN_BLOCKED' || code === 'CLEARTEXT_BLOCKED') {
    return 'error.network';
  }
  return 'error.unknown';
}

/** Localised message for an error code. */
export function errorMessage(lang: string, code: string): string {
  return translate(lang, errorKey(code));
}
