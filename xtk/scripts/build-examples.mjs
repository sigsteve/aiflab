import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const shellPath = path.join(root, 'node_modules/@rancher/shell');
const vueCli = path.join(root, 'node_modules/.bin/vue-cli-service');
const requestedExamples = process.argv.slice(2);
const examples = (requestedExamples.length > 0 ?
  requestedExamples :
  [
    'examples/hello-extension',
    'examples/rbac-k8s-extension',
    'examples/modelprobe-extension',
  ])
  .map((example) => path.resolve(root, example));

if (!existsSync(shellPath) || !existsSync(vueCli)) {
  throw new Error('Build dependencies are missing. Run npm install from the XTK root.');
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    stdio: 'inherit',
    ...options,
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    throw new Error(`${ command } exited with status ${ result.status }`);
  }
}

function packageArchive(outputDirectory, name, version) {
  const bundleName = `${ name }-${ version }`;
  const archiveRoot = path.join(root, 'dist-pkg', `.archive-${ bundleName }`);
  const pluginDirectory = path.join(archiveRoot, version, 'plugin');

  rmSync(archiveRoot, { force: true, recursive: true });
  mkdirSync(pluginDirectory, { recursive: true });

  for (const file of [
    `${ bundleName }.umd.min.js`,
    'package.json',
    'report.html',
  ]) {
    copyFileSync(
      path.join(outputDirectory, file),
      path.join(pluginDirectory, file),
    );
  }

  const archive = path.join(root, 'dist-pkg', `${ bundleName }.tgz`);

  rmSync(archive, { force: true });
  run('tar', ['-czf', archive, '-C', archiveRoot, version]);
  rmSync(archiveRoot, { force: true, recursive: true });
}

for (const exampleDirectory of examples) {
  if (!existsSync(path.join(exampleDirectory, 'package.json'))) {
    throw new Error(`No extension package found at ${ exampleDirectory }`);
  }

  const packageJson = JSON.parse(
    readFileSync(path.join(exampleDirectory, 'package.json'), 'utf8'),
  );
  const bundleName = `${ packageJson.name }-${ packageJson.version }`;
  const outputDirectory = path.join(root, 'dist-pkg', bundleName);
  const shellLink = path.join(exampleDirectory, '.shell');
  let removeShellLink = false;

  if (existsSync(shellLink)) {
    if (readlinkSync(shellLink) !== shellPath) {
      throw new Error(`${ shellLink } points to an unexpected toolchain`);
    }
  } else {
    symlinkSync(shellPath, shellLink);
    removeShellLink = true;
  }

  rmSync(outputDirectory, { force: true, recursive: true });
  mkdirSync(outputDirectory, { recursive: true });

  try {
    run(vueCli, [
      'build',
      '--name',
      bundleName,
      '--target',
      'lib',
      'index.ts',
      '--dest',
      outputDirectory,
      '--formats',
      'umd-min',
      '--filename',
      bundleName,
    ], { cwd: exampleDirectory });
  } finally {
    if (removeShellLink) {
      rmSync(shellLink);
    }
  }

  const packaged = {
    ...packageJson,
    rancher: true,
    files: ['**/*'],
    main: `${ bundleName }.umd.min.js`,
  };

  delete packaged.scripts;
  delete packaged.browserslist;
  writeFileSync(
    path.join(outputDirectory, 'package.json'),
    `${ JSON.stringify(packaged, null, 2) }\n`,
  );
  packageArchive(outputDirectory, packageJson.name, packageJson.version);
}
