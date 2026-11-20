/**
 * Global constants for DSH Mobile.
 *
 * Ported from the DeepSeek Harness desktop client (deepseek-harness, v0.2.2-rc.5).
 * The desktop client talks to DeepSeek's Anthropic-Messages-compatible endpoint; the
 * phone client keeps the same wire contract so both share model behaviour.
 */

/** Human readable product name, shown in the About page and window title. */
export const APP_NAME: string = 'DSH Mobile';

/** Upstream project this app is ported from. */
export const UPSTREAM_REPO: string = 'https://github.com/deepseek-ai/deepseek-harness';

/** Version of the upstream behaviour this port tracks. */
export const UPSTREAM_VERSION: string = '0.2.2-rc.5';

/** Version of this port. */
export const APP_VERSION: string = '1.0.0';

/** Official DeepSeek Messages root, identical to the desktop default. */
export const DEFAULT_BASE_URL: string = 'https://api.deepseek.com/anthropic';

/** Wire path appended to the base URL for model calls. */
export const MESSAGES_PATH: string = '/v1/messages';

/** Text plus image model advertised by the desktop default catalog (1,048,576 tokens). */
export const MODEL_FLASH: string = 'deepseek-flash';

/** Text only model advertised by the desktop default catalog (1,048,576 tokens). */
export const MODEL_PRO: string = 'deepseek-v4-pro';

/** Advisory context windows, mirroring the desktop catalog. */
export const CONTEXT_WINDOW: number = 1048576;

/** Catalog entries shown before the provider listing is fetched. */
export interface ModelEntry {
  id: string;
  label: string;
  supportsImages: boolean;
  contextWindow: number;
}

export const BUILTIN_MODELS: ModelEntry[] = [
  { id: MODEL_FLASH, label: 'DeepSeek V4.1 Flash', supportsImages: true, contextWindow: CONTEXT_WINDOW },
  { id: MODEL_PRO, label: 'DeepSeek V4 Pro', supportsImages: false, contextWindow: CONTEXT_WINDOW }
];

/** Header carrying the API key; the desktop adapter uses the same one. */
export const HEADER_API_KEY: string = 'x-api-key';

/** Preference store name. */
export const PREF_STORE: string = 'dsh_settings';

/** Preference keys. */
export const PREF_BASE_URL: string = 'base_url';
export const PREF_MODEL_ID: string = 'model_id';
export const PREF_EFFORT: string = 'reasoning_effort';
export const PREF_MAX_TOKENS: string = 'max_tokens';
export const PREF_SYSTEM_PROMPT: string = 'system_prompt';
export const PREF_LANGUAGE: string = 'language';
export const PREF_THEME: string = 'theme';
export const PREF_AUTO_TITLE: string = 'auto_title';
export const PREF_AUTO_MEMORY: string = 'auto_memory';
export const PREF_SEARCH_PROVIDER: string = 'search_provider';
export const PREF_LAST_SESSION: string = 'last_session_id';
export const PREF_HAS_KEY: string = 'has_api_key';
export const PREF_API_KEY_HINT: string = 'api_key_hint';

/** Directory (inside the app sandbox) holding one JSON file per session. */
export const SESSIONS_DIR: string = 'sessions';

/** File holding the session ordering / metadata index. */
export const SESSION_INDEX_FILE: string = 'index.json';

/** Key used by the Asset Store for the DeepSeek API key. */
export const ASSET_ALIAS: string = 'dsh_mobile_api_key';

/** Reasoning effort values accepted by the Messages endpoint. */
export const EFFORT_OFF: string = 'off';
export const EFFORT_LOW: string = 'low';
export const EFFORT_HIGH: string = 'high';
export const EFFORT_MAX: string = 'max';

export const EFFORTS: string[] = [EFFORT_OFF, EFFORT_LOW, EFFORT_HIGH, EFFORT_MAX];

/** Maximum agent loop rounds before the client pauses and asks the user. */
export const MAX_AGENT_ROUNDS: number = 40;

/** Maximum automatic goal continuation rounds, mirroring the desktop goal driver. */
export const MAX_GOAL_ROUNDS: number = 60;

/** Maximum characters of a tool result kept before truncation. */
export const MAX_TOOL_RESULT_CHARS: number = 24000;

/** Maximum bytes of one image accepted as an attachment. */
export const MAX_IMAGE_BYTES: number = 8 * 1024 * 1024;

/** Maximum number of images attached to a single message. */
export const MAX_IMAGES_PER_MESSAGE: number = 6;

/** Log tag used by every module. */
export const LOG_TAG: string = 'DSHMobile';

/** Domain id required by hilog. */
export const LOG_DOMAIN: number = 0xD5A;
