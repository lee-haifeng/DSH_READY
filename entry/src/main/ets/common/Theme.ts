/**
 * Design tokens.
 *
 * One interface, one instance per colour mode. Every component takes the active
 * palette as a parameter instead of reading a global, which keeps previews and the
 * settings preview honest and makes unit reasoning about colour a pure function.
 */

/** Colour tokens shared by every screen. Values are ArkUI colour strings. */
export interface Palette {
  /** Page background. */
  bg: string;
  /** Cards, sheets and popovers. */
  surface: string;
  /** Secondary surfaces: input bar, chips, list rows. */
  surfaceAlt: string;
  /** Highest surface: menus, dialogs. */
  surfaceHigh: string;
  /** Hairline separators. */
  border: string;
  /** Strong separators and outlines. */
  borderStrong: string;

  textPrimary: string;
  textSecondary: string;
  textTertiary: string;
  /** Text drawn on top of `accent`. */
  onAccent: string;

  accent: string;
  accentSoft: string;
  linkText: string;

  danger: string;
  dangerSoft: string;
  warning: string;
  success: string;

  /** User message bubble. */
  userBubble: string;
  userBubbleText: string;
  /** Assistant message bubble; usually transparent so text sits on `bg`. */
  assistantBubble: string;

  codeBackground: string;
  codeBorder: string;
  quoteBorder: string;

  /** Reasoning ("thinking") panel. */
  reasoningBg: string;
  reasoningBorder: string;
  /** Tool call card. */
  toolBg: string;
  toolBorder: string;

  /** Full-screen scrim behind sheets. */
  scrim: string;
  /** Breathing dot used while streaming. */
  pulse: string;
}

/** Dark palette, the default for this app. */
export const DARK: Palette = {
  bg: '#121317',
  surface: '#1A1C21',
  surfaceAlt: '#22252B',
  surfaceHigh: '#2A2E36',
  border: '#2C3038',
  borderStrong: '#3B404A',
  textPrimary: '#ECEDEF',
  textSecondary: '#A7ADB8',
  textTertiary: '#767D8A',
  onAccent: '#0B1220',
  accent: '#6BA6FF',
  accentSoft: '#1E2C44',
  linkText: '#7FB6FF',
  danger: '#FF6B6B',
  dangerSoft: '#3A2226',
  warning: '#F2B44C',
  success: '#57C98A',
  userBubble: '#2B3A55',
  userBubbleText: '#F2F5FA',
  assistantBubble: '#00000000',
  codeBackground: '#0D0E12',
  codeBorder: '#2A2E36',
  quoteBorder: '#4A5160',
  reasoningBg: '#171A20',
  reasoningBorder: '#272B33',
  toolBg: '#181B21',
  toolBorder: '#2A2F38',
  scrim: '#00000099',
  pulse: '#6BA6FF'
};

/** Light palette. */
export const LIGHT: Palette = {
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

/** Theme selection mode. */
export const THEME_SYSTEM: string = 'system';
export const THEME_LIGHT: string = 'light';
export const THEME_DARK: string = 'dark';

/** Resolve the palette for a mode, mapping `system` through the supplied dark flag. */
export function paletteFor(mode: string, systemIsDark: boolean): Palette {
  if (mode === THEME_LIGHT) {
    return LIGHT;
  }
  if (mode === THEME_DARK) {
    return DARK;
  }
  return systemIsDark ? DARK : LIGHT;
}

/** Corner radii used across the app so sheets, cards and bubbles stay consistent. */
export const RADIUS_SM: number = 8;
export const RADIUS_MD: number = 12;
export const RADIUS_LG: number = 18;
export const RADIUS_XL: number = 24;

/** Shared spacing steps (vp). */
export const SPACE_XS: number = 4;
export const SPACE_SM: number = 8;
export const SPACE_MD: number = 12;
export const SPACE_LG: number = 16;
export const SPACE_XL: number = 24;

/** Font sizes (fp). */
export const FONT_XS: number = 11;
export const FONT_SM: number = 12;
export const FONT_MD: number = 14;
export const FONT_BODY: number = 16;
export const FONT_TITLE: number = 20;
export const FONT_HERO: number = 26;

/** Monospace family available on HarmonyOS. */
export const MONO_FAMILY: string = 'monospace';
