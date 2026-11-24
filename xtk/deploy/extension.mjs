import crypto from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
const [action, directory = '.'] = process.argv.slice(2);
const exampleDirectory = path.resolve(directory);
const packagePath = path.join(exampleDirectory, 'package.json');
const namespace = process.env.XTK_UI_NAMESPACE ?? 'cattle-ui-plugin-system';
const contextArguments = process.env.KUBECTL_CONTEXT ?
  ['--context', process.env.KUBECTL_CONTEXT] :
  [];

function fail(message) {
  process.stderr.write(`Error: ${ message }\n`);
  process.exit(1);
}

function kubectl(args, options = {}) {
  const {
    printOutput = true,
    ...spawnOptions
  } = options;
  const result = spawnSync('kubectl', [...contextArguments, ...args], {
    encoding: 'utf8',
    stdio: spawnOptions.input ? ['pipe', 'pipe', 'pipe'] : 'inherit',
    ...spawnOptions,
  });

  if (result.error?.code === 'ENOENT') {
    fail('kubectl is required and must be on PATH.');
  }
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    fail(result.stderr?.trim() || `kubectl exited with status ${ result.status }.`);
  }

  if (printOutput && result.stdout) {
    process.stdout.write(result.stdout);
  }

  return result.stdout;
}

function runNode(args) {
  const result = spawnSync(process.execPath, args, { stdio: 'inherit' });

  if (result.status !== 0) {
    fail(`Build exited with status ${ result.status }.`);
  }
}

if (!['deploy', 'undeploy'].includes(action)) {
  fail('Usage: node deploy/extension.mjs <deploy|undeploy> <example-directory>');
}
if (!existsSync(packagePath)) {
  fail(`No package.json found in ${ exampleDirectory }.`);
}

const packageJson = JSON.parse(readFileSync(packagePath, 'utf8'));
const name = packageJson.name;
const version = packageJson.version;

if (!/^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$/.test(namespace)) {
  fail(`Namespace "${ namespace }" must be a Kubernetes-compatible name.`);
}
if (!/^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$/.test(name)) {
  fail(`Package name "${ name }" must be a Kubernetes-compatible name.`);
}
if (!/^[0-9A-Za-z.-]+$/.test(version)) {
  fail(`Package version "${ version }" contains unsupported characters.`);
}

const serverName = `${ name }-server`;
const assetsName = `${ name }-assets`;

if (action === 'undeploy') {
  kubectl([
    '-n',
    namespace,
    'delete',
    `uiplugin/${ name }`,
    `deployment/${ serverName }`,
    `service/${ serverName }`,
    `configmap/${ assetsName }`,
    '--ignore-not-found',
    '--wait=true',
  ]);
  process.stdout.write(`Undeployed ${ name }.\n`);
  process.exit(0);
}

kubectl(['get', 'namespace', namespace]);
runNode([path.join(root, 'scripts/build-examples.mjs'), exampleDirectory]);

const bundleName = `${ name }-${ version }.umd.min.js`;
const archiveName = `${ name }-${ version }.tgz`;
const bundlePath = path.join(root, 'dist-pkg', `${ name }-${ version }`, bundleName);
const archivePath = path.join(root, 'dist-pkg', archiveName);
const serverPath = path.join(root, 'deploy/server.cjs');

for (const asset of [bundlePath, archivePath, serverPath]) {
  if (!existsSync(asset)) {
    fail(`Build asset is missing: ${ asset }`);
  }
}

const configMap = kubectl([
  '-n',
  namespace,
  'create',
  'configmap',
  assetsName,
  `--from-file=server.cjs=${ serverPath }`,
  `--from-file=${ bundleName }=${ bundlePath }`,
  `--from-file=${ archiveName }=${ archivePath }`,
  '--dry-run=client',
  '-o',
  'yaml',
], { printOutput: false, stdio: ['ignore', 'pipe', 'pipe'] });

kubectl(['apply', '-f', '-'], { input: configMap });

const checksum = crypto.createHash('sha256')
  .update(readFileSync(bundlePath))
  .update(readFileSync(archivePath))
  .update(readFileSync(serverPath))
  .digest('hex');
const annotations = packageJson.rancher?.annotations ?? {};
const displayName =
  annotations['catalog.cattle.io/display-name'] ?? name;
const rancherVersion =
  annotations['catalog.cattle.io/rancher-version'] ?? '>= 2.13.0-0 < 2.17.0';
const extensionsVersion =
  annotations['catalog.cattle.io/ui-extensions-version'] ?? '>= 3.0.0 < 4.0.0';
const image = process.env.XTK_ASSET_SERVER_IMAGE ??
  'docker.io/library/node:22-bookworm-slim@sha256:47725aca53d3295ec2d3be8f62726599b3033cc262edc2c7e429909b3ac599fc';
const quote = (value) => JSON.stringify(value);
const workload = `apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${ serverName }
  namespace: ${ namespace }
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${ serverName }
  template:
    metadata:
      annotations:
        xtk.aiflab.io/assets-sha256: ${ checksum }
      labels:
        app.kubernetes.io/name: ${ serverName }
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: assets
          image: ${ quote(image) }
          imagePullPolicy: IfNotPresent
          command: [node, /assets/server.cjs]
          env:
            - name: EXTENSION_NAME
              value: ${ name }
            - name: EXTENSION_VERSION
              value: ${ quote(version) }
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
          resources:
            requests:
              cpu: 5m
              memory: 16Mi
            limits:
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          volumeMounts:
            - name: assets
              mountPath: /assets
              readOnly: true
      volumes:
        - name: assets
          configMap:
            name: ${ assetsName }
---
apiVersion: v1
kind: Service
metadata:
  name: ${ serverName }
  namespace: ${ namespace }
spec:
  selector:
    app.kubernetes.io/name: ${ serverName }
  ports:
    - name: http
      port: 8080
      targetPort: http
`;

kubectl(['apply', '-f', '-'], { input: workload });
kubectl([
  '-n',
  namespace,
  'rollout',
  'status',
  `deployment/${ serverName }`,
  '--timeout=120s',
]);
kubectl([
  '-n',
  namespace,
  'delete',
  `uiplugin/${ name }`,
  '--ignore-not-found',
  '--wait=true',
]);

const plugin = `apiVersion: catalog.cattle.io/v1
kind: UIPlugin
metadata:
  name: ${ name }
  namespace: ${ namespace }
spec:
  plugin:
    name: ${ name }
    version: ${ quote(version) }
    endpoint: http://${ serverName }.${ namespace }.svc:8080/plugin/${ name }-${ version }
    compressedEndpoint: http://${ serverName }.${ namespace }.svc:8080/plugin/${ name }-${ version }.tgz
    noAuth: false
    noCache: false
    metadata:
      developer: "true"
      catalog.cattle.io/display-name: ${ quote(displayName) }
      catalog.cattle.io/rancher-version: ${ quote(rancherVersion) }
      catalog.cattle.io/ui-extensions-version: ${ quote(extensionsVersion) }
`;

kubectl(['apply', '-f', '-'], { input: plugin });
kubectl([
  '-n',
  namespace,
  'wait',
  '--for=jsonpath={.status.cacheState}=cached',
  `uiplugin/${ name }`,
  '--timeout=120s',
]);
process.stdout.write(`Deployed ${ name } ${ version }.\n`);
