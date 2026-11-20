/**
 * AppStorage keys.
 *
 * Pages observe these through `@StorageLink`, so a single write here re-renders every
 * screen that depends on the value. Keeping the names in one place avoids the classic
 * silent typo where a component links to a key nobody ever writes.
 */

/** `AppSettings` snapshot. */
export const KEY_SETTINGS: string = 'dsh.settings';
/** Active UI language (`zh` / `en`). */
export const KEY_LANG: string = 'dsh.lang';
/** Theme mode (`system` / `light` / `dark`). */
export const KEY_THEME_MODE: string = 'dsh.themeMode';
/** Resolved `Palette` for the current mode. */
export const KEY_PALETTE: string = 'dsh.palette';
/** Resolved dark flag. */
export const KEY_IS_DARK: string = 'dsh.isDark';
/** Whether the agent is currently producing a reply. */
export const KEY_STREAMING: string = 'dsh.streaming';
/** Session currently open in the chat screen. */
export const KEY_ACTIVE_SESSION: string = 'dsh.activeSession';
/** Bumped whenever the session index changes, so lists refresh. */
export const KEY_SESSION_REVISION: string = 'dsh.sessionRevision';
/** Bottom safe area inset in vp, measured once by the root page. */
export const KEY_BOTTOM_INSET: string = 'dsh.bottomInset';
