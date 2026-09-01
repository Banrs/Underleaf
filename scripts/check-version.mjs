import { readFile } from 'node:fs/promises';

const pkg = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
const tauri = JSON.parse(await readFile(new URL('../src-tauri/tauri.conf.json', import.meta.url), 'utf8'));
const cargo = await readFile(new URL('../Cargo.toml', import.meta.url), 'utf8');
const workspaceVersion = cargo.match(/^version\s*=\s*"([^"]+)"/m)?.[1];
const expected = pkg.version;
const versions = {
  'package.json': pkg.version,
  'Cargo.toml [workspace.package]': workspaceVersion,
  'src-tauri/tauri.conf.json': tauri.version,
};

for (const [file, version] of Object.entries(versions)) {
  if (!version || version !== expected) {
    throw new Error(`Version mismatch: ${file} has ${version ?? 'no version'}, expected ${expected}`);
  }
}

const tag = process.env.RELEASE_TAG;
if (tag && tag !== `v${expected}`) {
  throw new Error(`Release tag ${tag} does not match manifest version v${expected}`);
}

console.log(`Version ${expected} is consistent${tag ? ` with ${tag}` : ''}.`);
