import { cpSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const name = process.argv[2];
const fail = (message) => {
  process.stderr.write(`Error: ${ message }\n`);
  process.exit(1);
};
if (!name) {
  fail('Usage: npm run new -- <extension-name>');
}
if (name.length > 40 || !/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(name)) {
  fail('Use 40 or fewer lowercase letters, numbers, and single hyphens.');
}
const source = path.join(root, 'examples/hello-extension');
const destination = path.join(root, 'examples', name);
if (existsSync(destination)) {
  fail(`${ destination } already exists.`);
}
const title = name.split('-')
  .map((word) => `${ word[0].toUpperCase() }${ word.slice(1) }`)
  .join(' ');
cpSync(source, destination, { recursive: true });
for (const relativePath of [
  'package.json', 'index.ts', 'pages/Hello.vue', 'README.md',
]) {
  const file = path.join(destination, relativePath);
  const content = readFileSync(file, 'utf8')
    .replaceAll('hello-extension', name)
    .replaceAll('xtk-hello', name)
    .replaceAll('XTK Hello', title)
    .replaceAll('Hello from XTK', title);

  writeFileSync(file, content);
}
process.stdout.write(`Created examples/${ name }. Run "cd examples/${ name } && make deploy".\n`);
