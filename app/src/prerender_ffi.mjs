import { readFileSync, writeFileSync } from 'node:fs';

export function write_file(path, contents) {
  writeFileSync(path, contents);
}

export function read_file(path) {
  return readFileSync(path, 'utf8');
}
