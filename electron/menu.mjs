// The native application menu. Its shape and enabled state come from the
// renderer's command model (web/src/commands.js), so a menu item can't drift
// from the shortcut or toolbar button that runs the same command.

import { Menu, app, shell } from 'electron';

const IS_MAC = process.platform === 'darwin';

function itemFor(entry, win) {
  if (entry === '-') return { type: 'separator' };
  if (entry.role) return { role: entry.role };
  return {
    id: entry.id,
    label: entry.label,
    accelerator: entry.accelerator,
    enabled: entry.enabled !== false,
    type: entry.type,
    checked: entry.checked,
    click: () => win?.webContents.send('command:run', entry.id),
  };
}

// `spec` is the renderer's menu description: [{ label, items: [...] }].
export function buildMenu(spec, win) {
  const appMenu = {
    label: app.name,
    submenu: [
      { role: 'about' },
      { type: 'separator' },
      {
        label: 'Settings…',
        accelerator: 'CmdOrCtrl+,',
        click: () => win?.webContents.send('command:run', 'app.settings'),
      },
      { type: 'separator' },
      { role: 'services' },
      { type: 'separator' },
      { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' },
      { type: 'separator' },
      { role: 'quit' },
    ],
  };

  const windowMenu = {
    label: 'Window',
    submenu: [
      { role: 'minimize' }, { role: 'zoom' },
      { type: 'separator' },
      IS_MAC ? { role: 'front' } : { role: 'close' },
    ],
  };

  const helpMenu = {
    role: 'help',
    submenu: [
      { label: 'Underleaf on GitHub', click: () => shell.openExternal('https://github.com/Banrs/Underleaf') },
      { type: 'separator' },
      { role: 'toggleDevTools' },
    ],
  };

  const template = [
    ...(IS_MAC ? [appMenu] : []),
    ...spec.map((group) => ({
      label: group.label,
      submenu: group.items.map((it) => itemFor(it, win)),
    })),
    windowMenu,
    helpMenu,
  ];

  // Windows and Linux have no application menu, so File gets Settings and Quit.
  if (!IS_MAC) {
    let file = template.find((m) => m.label === 'File');
    if (!file) {
      file = { label: 'File', submenu: [] };
      template.unshift(file);
    }
    file.submenu.push(
      { type: 'separator' },
      { label: 'Settings…', accelerator: 'Ctrl+,', click: () => win?.webContents.send('command:run', 'app.settings') },
      { type: 'separator' },
      { role: 'quit' },
    );
  }

  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// Until the renderer has published a spec, show a menu with the standard items
// so ⌘Q, ⌘C and friends work during startup.
export function buildFallbackMenu(win) {
  buildMenu([
    { label: 'File', items: [] },
    { label: 'Edit', items: [{ role: 'undo' }, { role: 'redo' }, '-', { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }] },
  ], win);
}
