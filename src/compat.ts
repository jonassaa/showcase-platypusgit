// Migration shim.
//
// 0.1.0-dev wrote notes under an unversioned key. Anyone who ran it from a
// checkout has notes there and no way to get them back, so this moves them
// across once and then does nothing forever.

import type { StorageLike } from './store.ts';

const LEGACY_KEY = 'platypad.notes';
const CURRENT_KEY = 'platypad.notes.v1';

/** Copy legacy notes forward, if there are any and nothing has landed yet. */
export function migrateLegacyKey(storage: StorageLike): boolean {
  const legacy = storage.getItem(LEGACY_KEY);
  if (legacy === null) return false;
  if (storage.getItem(CURRENT_KEY) !== null) return false;
  storage.setItem(CURRENT_KEY, legacy);
  return true;
}
