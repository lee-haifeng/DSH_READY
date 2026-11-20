/**
 * User preferences.
 *
 * Settings live in Preferences (a small key/value store) and are mirrored into
 * AppStorage so any page can render them reactively without awaiting storage.
 */

import { preferences } from '@kit.ArkData';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import {
  DEFAULT_BASE_URL, EFFORT_HIGH, MODEL_FLASH, PREF_API_KEY_HINT,
  PREF_AUTO_TITLE, PREF_BASE_URL, PREF_EFFORT, PREF_HAS_KEY, PREF_LANGUAGE, PREF_LAST_SESSION,
  PREF_MAX_TOKENS, PREF_MODEL_ID, PREF_SEARCH_PROVIDER, PREF_SYSTEM_PROMPT, PREF_THEME, PREF_STORE
} from '../common/Constants';
import { AppSettings } from '../model/Types';
import { LANG_EN, LANG_ZH } from '../i18n/Strings';
import { Palette, paletteFor, THEME_DARK, THEME_LIGHT, THEME_SYSTEM } from '../common/Theme';
import { KEY_ACTIVE_SESSION, KEY_IS_DARK, KEY_LANG, KEY_PALETTE, KEY_SETTINGS, KEY_THEME_MODE } from '../common/StateKeys';
import { AppContext } from './AppContext';
import { Log } from '../common/Utils';

const log = new Log('Settings');

/** Search provider identifiers. */
export const SEARCH_DUCKDUCKGO: string = 'duckduckgo';
export const SEARCH_BING: string = 'bing';

/** Build the defaults, used on first launch and by the reset action. */
export function defaultSettings(): AppSettings {
  return {
    baseUrl: DEFAULT_BASE_URL,
    modelId: MODEL_FLASH,
    effort: EFFORT_HIGH,
    maxTokens: 16384,
    systemPrompt: '',
    language: detectLanguage(),
    themeMode: THEME_SYSTEM,
    autoTitle: true,
    searchProvider: SEARCH_DUCKDUCKGO,
    hasApiKey: false,
    apiKeyHint: ''
  };
}

/** Follow the device language on first launch: Chinese for zh-*, English otherwise. */
function detectLanguage(): string {
  try {
    const language: string = i18n.System.getSystemLanguage();
    return language.toLowerCase().startsWith('zh') ? LANG_ZH : LANG_EN;
  } catch (e) {
    return LANG_ZH;
  }
}

/** Whether the OS is currently in dark mode. */
export function systemIsDark(): boolean {
  try {
    const mode: ConfigurationConstant.ColorMode | undefined = AppContext.require().config.colorMode;
    return mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  } catch (e) {
    return true;
  }
}

export class SettingsService {
  private static store: preferences.Preferences | undefined = undefined;
  private static current: AppSettings = defaultSettings();

  /** Open the preference store and publish the initial snapshot. */
  static init(): void {
    const options: preferences.Options = { name: PREF_STORE };
    SettingsService.store = preferences.getPreferencesSync(AppContext.require(), options);
    SettingsService.current = SettingsService.read();
    SettingsService.publish();
  }

  /** Current snapshot; cheap because it is cached in memory. */
  static get(): AppSettings {
    return SettingsService.current;
  }

  private static readString(key: string, fallback: string): string {
    const store: preferences.Preferences | undefined = SettingsService.store;
    if (store === undefined) {
      return fallback;
    }
    const value: preferences.ValueType = store.getSync(key, fallback);
    return typeof value === 'string' ? value : fallback;
  }

  private static readNumber(key: string, fallback: number): number {
    const store: preferences.Preferences | undefined = SettingsService.store;
    if (store === undefined) {
      return fallback;
    }
    const value: preferences.ValueType = store.getSync(key, fallback);
    return typeof value === 'number' ? value : fallback;
  }

  private static readBool(key: string, fallback: boolean): boolean {
    const store: preferences.Preferences | undefined = SettingsService.store;
    if (store === undefined) {
      return fallback;
    }
    const value: preferences.ValueType = store.getSync(key, fallback);
    return typeof value === 'boolean' ? value : fallback;
  }

  private static read(): AppSettings {
    const defaults: AppSettings = defaultSettings();
    const settings: AppSettings = {
      baseUrl: SettingsService.readString(PREF_BASE_URL, defaults.baseUrl),
      modelId: SettingsService.readString(PREF_MODEL_ID, defaults.modelId),
      effort: SettingsService.readString(PREF_EFFORT, defaults.effort),
      maxTokens: SettingsService.readNumber(PREF_MAX_TOKENS, defaults.maxTokens),
      systemPrompt: SettingsService.readString(PREF_SYSTEM_PROMPT, defaults.systemPrompt),
      language: SettingsService.readString(PREF_LANGUAGE, defaults.language),
      themeMode: SettingsService.readString(PREF_THEME, defaults.themeMode),
      autoTitle: SettingsService.readBool(PREF_AUTO_TITLE, defaults.autoTitle),
      searchProvider: SettingsService.readString(PREF_SEARCH_PROVIDER, defaults.searchProvider),
      hasApiKey: SettingsService.readBool(PREF_HAS_KEY, false),
      apiKeyHint: SettingsService.readString(PREF_API_KEY_HINT, '')
    };
    return settings;
  }

  /** Persist a complete snapshot and republish it. */
  static save(settings: AppSettings): void {
    SettingsService.current = settings;
    const store: preferences.Preferences | undefined = SettingsService.store;
    if (store !== undefined) {
      store.putSync(PREF_BASE_URL, settings.baseUrl);
      store.putSync(PREF_MODEL_ID, settings.modelId);
      store.putSync(PREF_EFFORT, settings.effort);
      store.putSync(PREF_MAX_TOKENS, settings.maxTokens);
      store.putSync(PREF_SYSTEM_PROMPT, settings.systemPrompt);
      store.putSync(PREF_LANGUAGE, settings.language);
      store.putSync(PREF_THEME, settings.themeMode);
      store.putSync(PREF_AUTO_TITLE, settings.autoTitle);
      store.putSync(PREF_SEARCH_PROVIDER, settings.searchProvider);
      store.putSync(PREF_HAS_KEY, settings.hasApiKey);
      store.putSync(PREF_API_KEY_HINT, settings.apiKeyHint);
      store.flushSync();
    }
    SettingsService.publish();
  }

  /** Convenience: save a copy with the API key metadata replaced. */
  static withApiKeyState(hasKey: boolean, hint: string): AppSettings {
    const current: AppSettings = SettingsService.current;
    const next: AppSettings = {
      baseUrl: current.baseUrl,
      modelId: current.modelId,
      effort: current.effort,
      maxTokens: current.maxTokens,
      systemPrompt: current.systemPrompt,
      language: current.language,
      themeMode: current.themeMode,
      autoTitle: current.autoTitle,
      searchProvider: current.searchProvider,
      hasApiKey: hasKey,
      apiKeyHint: hint
    };
    return next;
  }

  /** Remember which session was last open so the app can restore it. */
  static saveLastSession(sessionId: string): void {
    const store: preferences.Preferences | undefined = SettingsService.store;
    if (store !== undefined) {
      store.putSync(PREF_LAST_SESSION, sessionId);
      store.flush();
    }
  }

  /** Id of the session that was open when the app was last used. */
  static lastSession(): string {
    return SettingsService.readString(PREF_LAST_SESSION, '');
  }

  /** Reset preferences to defaults (credential removal is handled by the caller). */
  static reset(): AppSettings {
    const defaults: AppSettings = defaultSettings();
    SettingsService.save(defaults);
    return defaults;
  }

  /** Push the snapshot, language and palette into AppStorage. */
  static publish(): void {
    const settings: AppSettings = SettingsService.current;
    const dark: boolean = settings.themeMode === THEME_DARK
      ? true
      : settings.themeMode === THEME_LIGHT ? false : systemIsDark();
    const palette: Palette = paletteFor(settings.themeMode, systemIsDark());
    AppStorage.setOrCreate<AppSettings>(KEY_SETTINGS, settings);
    AppStorage.setOrCreate<string>(KEY_LANG, settings.language);
    AppStorage.setOrCreate<string>(KEY_THEME_MODE, settings.themeMode);
    AppStorage.setOrCreate<boolean>(KEY_IS_DARK, dark);
    AppStorage.setOrCreate<Palette>(KEY_PALETTE, palette);
    log.info(`published settings model=${settings.modelId} lang=${settings.language} theme=${settings.themeMode}`);
  }

  /** Ensure AppStorage holds a palette even before the first publish. */
  static ensurePublished(): void {
    const existing: AppSettings | undefined = AppStorage.get<AppSettings>(KEY_SETTINGS);
    if (existing === undefined) {
      SettingsService.publish();
    }
  }

  /** Current active session id from AppStorage. */
  static activeSession(): string {
    const value: string | undefined = AppStorage.get<string>(KEY_ACTIVE_SESSION);
    return value === undefined ? '' : value;
  }

  /** Set the active session id in AppStorage. */
  static setActiveSession(id: string): void {
    AppStorage.setOrCreate<string>(KEY_ACTIVE_SESSION, id);
  }
}
