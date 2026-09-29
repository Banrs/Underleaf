// Static LaTeX for the editor: the blocks it inserts and its completions.
// The one copy is the core's (crates/texlocal-syntax/src/catalog.json), which
// the Mac's native editor reads through the core.

import catalog from '../../crates/texlocal-syntax/src/catalog.json' with { type: 'json' };

// The blocks the source bar and the native apps' Insert and Format menus
// write, by id; Windows reaches them through the editor page's `block`
// command. "$0" marks where the cursor lands.
export const BLOCK_TEMPLATES = catalog.blocks;

export const ENVIRONMENTS = catalog.environments;

// [name, detail, snippet]; #{…} marks a snippet field
export const COMMANDS = catalog.commands;

export const BIB_ENTRY_TYPES = catalog.bibEntryTypes;
