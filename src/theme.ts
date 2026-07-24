// Light and dark, as CSS custom properties.
//
// The token VALUES live here rather than only in styles/theme.scss because
// anything that has to serialise a theme — an export, a print stylesheet —
// cannot read a stylesheet it is not shipping.

import type { ThemeName } from './types.ts';

export const THEMES: readonly ThemeName[] = ['light', 'dark'];

const LIGHT: Record<string, string> = {
  '--bg': '#fbfaf8',
  '--bg-raised': '#ffffff',
  '--fg': '#1b1a17',
  '--fg-muted': '#6b6864',
  '--border': '#e3dfd8',
  '--accent': '#8a5a2b',
  '--hit': '#ffe9a8',
  '--code-bg': '#f3f0ea',
};

const DARK: Record<string, string> = {
  '--bg': '#17181a',
  '--bg-raised': '#1f2124',
  '--fg': '#e8e6e1',
  '--fg-muted': '#9b9791',
  '--border': '#2e3135',
  '--accent': '#d3a06a',
  '--hit': '#5a4a1e',
  '--code-bg': '#232629',
};

export function themeTokens(name: ThemeName): Record<string, string> {
  return name === 'dark' ? { ...DARK } : { ...LIGHT };
}

export function nextTheme(current: ThemeName): ThemeName {
  return current === 'light' ? 'dark' : 'light';
}

/** Write the tokens onto an element, and stamp the name for CSS to read. */
export function applyTheme(root: HTMLElement, name: ThemeName): void {
  const tokens = themeTokens(name);
  for (const [key, value] of Object.entries(tokens)) {
    root.style.setProperty(key, value);
  }
  root.dataset['theme'] = name;
}
