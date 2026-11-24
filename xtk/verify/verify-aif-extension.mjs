import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import path from 'node:path';
import { chromium } from 'playwright';

const STOCK_PAGES = [
  { label: 'Overview', path: '/c/{cluster}/suseai/overview' },
  { label: 'Apps', path: '/c/{cluster}/suseai/apps' },
  { label: 'Blueprints', path: '/c/{cluster}/suseai/blueprints' },
  { label: 'Workloads', path: '/c/{cluster}/suseai/workloads' },
  { label: 'Settings', path: '/c/{cluster}/suseai/settings' },
  { label: 'About', path: '/c/{cluster}/suseai/about' },
];
const STOCK_ROUTES = [
  ['c-cluster-suseai-about', '/c/:cluster/suseai/about'],
  ['c-cluster-suseai-install', '/c/:cluster/suseai/apps/:slug/install'],
  ['c-cluster-suseai-app-instances', '/c/:cluster/suseai/apps/:slug/instances'],
  ['c-cluster-suseai-manage', '/c/:cluster/suseai/apps/:slug/manage'],
  ['c-cluster-suseai-apps', '/c/:cluster/suseai/apps'],
  ['c-cluster-suseai-blueprint-create', '/c/:cluster/suseai/blueprints/create'],
  ['c-cluster-suseai-blueprint-install', '/c/:cluster/suseai/blueprints/install'],
  ['c-cluster-suseai-blueprint-manage', '/c/:cluster/suseai/blueprints/manage'],
  ['c-cluster-suseai-blueprints', '/c/:cluster/suseai/blueprints'],
  ['c-cluster-suseai-home', '/c/:cluster/suseai/home'],
  ['c-cluster-suseai-overview', '/c/:cluster/suseai/overview'],
  ['c-cluster-suseai-repositories', '/c/:cluster/suseai/repositories'],
  ['c-cluster-suseai-settings', '/c/:cluster/suseai/settings'],
  ['c-cluster-suseai-workloads', '/c/:cluster/suseai/workloads'],
  ['c-cluster-suseai-home-root', '/c/:cluster/suseai'],
].map(([name, routePath]) => ({ name, path: routePath, product: 'suseai' }));
const DEFAULT_PAGES = [
  {
    id: 'xtk-hello',
    slug: 'hello',
    label: 'Hello from XTK',
    kind: 'hello',
    plugin: 'xtk-hello',
    version: '0.1.1',
  },
  {
    id: 'xtk-k8s',
    slug: 'summary',
    label: 'Cluster Summary',
    kind: 'summary',
    plugin: 'xtk-k8s',
    version: '0.1.1',
  },
  {
    id: 'xtk-k8s',
    slug: 'pods',
    label: 'Pod Inspector',
    kind: 'pods',
    plugin: 'xtk-k8s',
    version: '0.1.1',
  },
  {
    id: 'xtk-modelprobe',
    slug: 'probes',
    label: 'Model Probes',
    kind: 'probes',
    plugin: 'xtk-modelprobe',
    version: '0.1.0',
    resourceType: 'xtk.aiflab.io.modelprobe',
    verb: 'GET',
  },
];
const REGISTRATION_ERROR =
  /Could not initialize plugin|Failed to load extension|Error applying the products|registration error|extendedProductMissing|No match found|TypeError|ReferenceError/i;

function parseArguments(argv) {
  const parsed = {};

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];

    if (argument === '--help') {
      parsed.help = true;
      continue;
    }

    if (!argument.startsWith('--')) {
      throw new Error(`Unexpected argument: ${ argument }`);
    }

    const [key, inlineValue] = argument.slice(2).split('=', 2);
    const value = inlineValue ?? argv[index + 1];

    if (inlineValue === undefined) {
      index += 1;
    }

    if (!value || value.startsWith('--')) {
      throw new Error(`Missing value for --${ key }`);
    }

    parsed[key] = value;
  }

  return parsed;
}

function printHelp() {
  process.stdout.write([
    'Usage: node verify/verify-aif-extension.mjs [options]',
    '',
    'Options:',
    '  --url URL              Rancher URL (RANCHER_URL)',
    '  --user USER            Rancher user (RANCHER_USER)',
    '  --password PASS        Rancher password (RANCHER_PASSWORD)',
    '  --cluster ID           Rancher cluster id (RANCHER_CLUSTER)',
    '  --artifacts PATH       Report and screenshot directory',
    '  --pages-json JSON      Expected pages, routes, and bundle metadata',
    '  --kubectl-context CTX  Optional kubectl context',
    '  --delay-ms NUMBER      Bundle delay for load-order checks',
    '',
  ].join('\n'));
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function parsePages(raw) {
  const pages = raw ? JSON.parse(raw) : DEFAULT_PAGES;

  assert(Array.isArray(pages) && pages.length > 0, 'Expected pages must be a non-empty JSON array');

  return pages.map((page, index) => {
    for (const field of ['id', 'slug', 'label', 'plugin', 'version']) {
      assert(
        typeof page[field] === 'string' && page[field].length > 0,
        `Expected page ${ index } has no ${ field }`,
      );
    }

    return {
      ...page,
      kind: page.kind ?? 'page',
      path: `/c/{cluster}/suseai/extensions/${ page.id }/${ page.slug }`,
      route: `c-cluster-suseai-ext-${ page.id }-${ page.slug }`,
      virtualTypeName: `suseai.ext.${ page.id }.${ page.slug }`,
    };
  });
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function routePattern(plugin, version) {
  return new RegExp(
    `/v1/uiplugins/${ escapeRegExp(plugin) }/${ escapeRegExp(version) }/plugin/` +
    `${ escapeRegExp(plugin) }-${ escapeRegExp(version) }\\.umd\\.min\\.js(?:\\?.*)?$`,
  );
}

function runKubectl(context, args) {
  const contextArgs = context ? ['--context', context] : [];

  return execFileSync('kubectl', [...contextArgs, ...args], {
    encoding: 'utf8',
  }).trim();
}

function nonEmptyLines(value) {
  return value ? value.split('\n').filter(Boolean) : [];
}

function captureKubectl(context) {
  const namespaces = nonEmptyLines(runKubectl(context, [
    'get',
    'namespaces',
    '--no-headers',
    '-o',
    'custom-columns=NAME:.metadata.name',
  ]));
  const podLines = nonEmptyLines(runKubectl(context, [
    'get',
    'pods',
    '-A',
    '--no-headers',
    '-o',
    'custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase',
  ]));
  const pods = podLines.map((line) => {
    const [namespace, name, phase] = line.trim().split(/\s+/);

    return { namespace, name, phase };
  });
  const modelProbes = JSON.parse(runKubectl(context, [
    'get',
    'modelprobes.xtk.aiflab.io',
    '-A',
    '-o',
    'json',
  ])).items.map((probe) => ({
    name: probe.metadata.name,
    namespace: probe.metadata.namespace,
    url: probe.spec.url,
    healthy: probe.status?.healthy,
    statusCode: probe.status?.lastStatusCode,
    latencyMs: probe.status?.latencyMs,
    lastProbeTime: probe.status?.lastProbeTime,
  }));

  return {
    namespaceCount: namespaces.length,
    namespaces,
    podCount: pods.length,
    pods,
    modelProbes,
  };
}

function loginToken(baseUrl, username, password) {
  const target = new URL(
    '/v3-public/localProviders/local?action=login',
    baseUrl,
  );
  const body = JSON.stringify({
    username,
    password,
    responseType: 'json',
  });
  const client = target.protocol === 'https:' ? https : http;

  return new Promise((resolve, reject) => {
    const request = client.request(target, {
      method: 'POST',
      rejectUnauthorized: false,
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    }, (response) => {
      let responseBody = '';

      response.on('data', (chunk) => {
        responseBody += chunk;
      });
      response.on('end', () => {
        if (response.statusCode !== 201) {
          reject(new Error(`Rancher login returned ${ response.statusCode }`));
          return;
        }

        resolve(JSON.parse(responseBody).token);
      });
    });

    request.on('error', reject);
    request.end(body);
  });
}

function pagePath(page, cluster) {
  return page.path.replace('{cluster}', cluster);
}

async function newRun(browser, config, token) {
  const target = new URL(config.baseUrl);
  const context = await browser.newContext({
    ignoreHTTPSErrors: true,
    serviceWorkers: 'block',
    viewport: { width: 1600, height: 1000 },
  });
  const consoleErrors = [];
  const pageErrors = [];
  const failedResponses = [];
  const bundleEvents = [];

  await context.addCookies([{
    name: 'R_SESS',
    value: token,
    domain: target.hostname,
    path: '/',
    httpOnly: true,
    secure: target.protocol === 'https:',
    sameSite: 'Lax',
  }]);

  const page = await context.newPage();

  page.on('console', (message) => {
    if (message.type() === 'error') {
      consoleErrors.push(message.text());
    }
  });
  page.on('pageerror', (error) => {
    pageErrors.push(error.message);
  });
  page.on('response', (response) => {
    if (response.status() >= 400) {
      failedResponses.push({
        resourceType: response.request().resourceType(),
        status: response.status(),
        url: response.url(),
      });
    }
  });
  page.on('requestfinished', (request) => {
    if (
      request.resourceType() === 'script' &&
      /\/v1\/uiplugins\//.test(request.url())
    ) {
      bundleEvents.push({ at: Date.now(), url: request.url() });
    }
  });

  return {
    context,
    page,
    consoleErrors,
    pageErrors,
    failedResponses,
    bundleEvents,
  };
}

function errorEvidence(run) {
  return {
    consoleErrors: run.consoleErrors,
    pageErrors: run.pageErrors,
    registrationErrors: [
      ...run.consoleErrors,
      ...run.pageErrors,
    ].filter((message) => REGISTRATION_ERROR.test(message)),
    failedResponses: run.failedResponses,
  };
}

async function closeWelcome(page) {
  const close = page.getByRole('button', { name: 'Close', exact: true });

  if (await close.isVisible()) {
    await close.click();
  }
}

async function openPage(page, config, routePath, heading) {
  await page.goto(
    `${ config.baseUrl }/dashboard${ routePath }`,
    { waitUntil: 'domcontentloaded' },
  );
  await page.getByRole('heading', { name: heading, exact: true }).waitFor({
    state: 'visible',
    timeout: 60_000,
  });
  await closeWelcome(page);
}

async function visibleCount(locator) {
  let count = 0;

  for (let index = 0; index < await locator.count(); index += 1) {
    if (await locator.nth(index).isVisible()) {
      count += 1;
    }
  }

  return count;
}

async function visibleLink(page, routePath) {
  const links = page.locator('nav.side-nav').locator(`a[href$="${ routePath }"]`);

  for (let index = 0; index < await links.count(); index += 1) {
    if (await links.nth(index).isVisible()) {
      return links.nth(index);
    }
  }

  throw new Error(`No visible sidebar link for ${ routePath }`);
}

async function openExtensions(page, pages, cluster) {
  const sideNav = page.locator('nav.side-nav');
  const groups = sideNav.locator('[role="button"][aria-label="Extensions"]');

  assert(
    await visibleCount(groups) === 1,
    'Expected exactly one visible Extensions group',
  );

  const firstPath = pagePath(pages[0], cluster);

  if (await visibleCount(sideNav.locator(`a[href$="${ firstPath }"]`)) === 0) {
    await groups.filter({ visible: true }).first().click();
  }

  await visibleLink(page, firstPath);
}

async function captureNavigation(page, pages, cluster) {
  const stock = [];

  for (const item of STOCK_PAGES) {
    const link = await visibleLink(
      page,
      item.path.replace('{cluster}', cluster),
    );

    stock.push({
      label: item.label,
      y: (await link.boundingBox())?.y ?? Number.MAX_SAFE_INTEGER,
    });
  }

  await openExtensions(page, pages, cluster);

  const children = [];

  for (const item of pages) {
    const link = await visibleLink(page, pagePath(item, cluster));

    children.push({
      label: item.label,
      y: (await link.boundingBox())?.y ?? Number.MAX_SAFE_INTEGER,
    });
  }

  return {
    stock: stock.sort((left, right) => left.y - right.y)
      .map(({ label }) => label),
    extensionsGroupCount: await visibleCount(
      page.locator('nav.side-nav')
        .locator('[role="button"][aria-label="Extensions"]'),
    ),
    children: children.sort((left, right) => left.y - right.y)
      .map(({ label }) => label),
  };
}

async function captureRuntime(page, expectedPages) {
  return page.evaluate((pages) => {
    const app = document.querySelector('#app')?.__vue_app__;
    const globals = app?.config?.globalProperties;
    const store = globals?.$store;
    const router = globals?.$router;
    const product = store?.getters?.['type-map/productByName']?.('suseai');
    const labels = pages.map(({ label }) => label);
    const resourceTypes = [...new Set(
      pages.map(({ resourceType }) => resourceType).filter(Boolean),
    )];

    if (!store || !router || !product) {
      throw new Error('Could not read the suseai product from Rancher');
    }

    const basicTypes = store.getters['type-map/allTypes']('suseai', ['basic']);
    const basicTree = store.getters['type-map/getTree'](
      'suseai',
      'basic',
      basicTypes.basic ?? {},
      store.getters.clusterId,
      router.currentRoute.value.params.resource ?? '',
    );
    const extensionsTree = basicTree.find((item) => item.name === 'Extensions');

    return {
      product: {
        inStore: product.inStore,
        weight: product.weight,
        showClusterSwitcher: product.showClusterSwitcher,
        isMultiClusterApp: product.isMultiClusterApp,
      },
      extendable: {
        ownProperty: Object.prototype.hasOwnProperty.call(product, 'extendable'),
        value: product.extendable === undefined ? '__undefined__' : product.extendable,
      },
      resourceSchemas: Object.fromEntries(resourceTypes.map((type) => {
        const schema = store.getters['cluster/schemaFor'](type);

        return [type, schema ? {
          id: schema.id,
          namespaced: schema.attributes?.namespaced,
        } : null];
      })),
      childDslState: {
        basicTypes: store.state['type-map'].basicTypes.suseai,
        weights: Object.fromEntries(labels.map((label) => [
          label,
          store.state['type-map'].basicTypeWeights[label.toLowerCase()],
        ])),
        extensionsTree: extensionsTree ? {
          name: extensionsTree.name,
          label: extensionsTree.label,
          children: extensionsTree.children?.map((child) => ({
            name: child.name,
            label: child.label,
            weight: child.weight,
          })),
        } : null,
        virtualTypes: (store.state['type-map'].virtualTypes.suseai ?? [])
          .map((type) => ({
            name: type.name,
            label: type.label,
            ifFeature: type.ifFeature,
            ifHaveType: type.ifHaveType,
            ifHaveVerb: type.ifHaveVerb,
          })),
      },
      routes: router.getRoutes()
        .filter((route) => route.meta?.product === 'suseai' ||
          route.path.includes('/suseai') ||
          String(route.name ?? '').includes('suseai'))
        .map((route) => ({
          name: route.name ?? null,
          path: route.path,
          product: route.meta?.product ?? null,
        })),
    };
  }, expectedPages);
}

function assertNavigation(navigation, expectedPages) {
  assert(
    JSON.stringify(navigation.stock) ===
      JSON.stringify(STOCK_PAGES.map(({ label }) => label)),
    'Stock sidebar order changed',
  );
  assert(
    navigation.extensionsGroupCount === 1,
    'Expected one Extensions group',
  );
  assert(
    JSON.stringify(navigation.children) ===
      JSON.stringify(expectedPages.map(({ label }) => label)),
    'Extension sidebar order is wrong',
  );
}

function assertRuntime(runtime, pages) {
  assert(
    JSON.stringify(runtime.product) === JSON.stringify({
      inStore: 'management',
      weight: 80,
      showClusterSwitcher: false,
      isMultiClusterApp: true,
    }),
    'Stock suseai product metadata changed',
  );
  assert(
    runtime.extendable.ownProperty === false &&
      runtime.extendable.value === '__undefined__',
    'Stock suseai extendable metadata changed',
  );

  const actualRoutes = new Set(
    runtime.routes.map((route) => JSON.stringify(route)),
  );

  for (const route of STOCK_ROUTES) {
    assert(
      actualRoutes.has(JSON.stringify(route)),
      `Stock AIF route changed or disappeared: ${ route.name }`,
    );
  }

  assert(STOCK_ROUTES.length === 15, 'The stock route contract must contain 15 routes');

  for (const page of pages) {
    assert(
      actualRoutes.has(JSON.stringify({
        name: page.route,
        path: page.path.replace('{cluster}', ':cluster'),
        product: 'suseai',
      })),
      `Extension route is missing: ${ page.route }`,
    );

    if (page.resourceType) {
      const schema = runtime.resourceSchemas[page.resourceType];
      const virtualType = runtime.childDslState.virtualTypes.find(
        ({ name }) => name === page.virtualTypeName,
      );

      assert(
        schema?.id === page.resourceType && schema.namespaced === true,
        `Live Rancher schema is wrong: ${ page.resourceType }`,
      );
      assert(
        virtualType?.ifHaveType === page.resourceType &&
          virtualType.ifHaveVerb === page.verb,
        `Extension access gate is wrong: ${ page.virtualTypeName }`,
      );
    }
  }
}

async function readLivePage(page, expectedPage) {
  if (expectedPage.kind === 'summary') {
    const namespaceCount = Number(
      await page.getByTestId('namespace-count').innerText(),
    );
    const podCount = Number(
      await page.getByTestId('summary-pod-count').innerText(),
    );
    const lists = await page.locator('.summary-grid article').evaluateAll(
      (articles) => articles.map((article) =>
        [...article.querySelectorAll('li')].map((item) => item.textContent?.trim())),
    );

    return {
      namespaceCount,
      podCount,
      namespaceNames: lists[0] ?? [],
      podNames: lists[1] ?? [],
    };
  }

  if (expectedPage.kind === 'pods') {
    const podCount = Number(await page.getByTestId('pod-count').innerText());
    const pods = await page.getByTestId('pod-row').evaluateAll((rows) =>
      rows.map((row) => {
        const cells = [...row.querySelectorAll('td')]
          .map((cell) => cell.textContent?.trim() ?? '');

        return {
          name: cells[0],
          namespace: cells[1],
          phase: cells[2],
        };
      }),
    );

    return { podCount, pods };
  }

  if (expectedPage.kind === 'probes') {
    const probes = await page.getByTestId('modelprobe-row').evaluateAll((rows) =>
      rows.map((row) => {
        const cells = [...row.querySelectorAll('td')]
          .map((cell) => cell.textContent?.trim() ?? '');

        return {
          name: cells[0],
          namespace: cells[1],
          url: cells[2],
          healthy: cells[3] === 'Healthy' ?
            true :
            cells[3] === 'Unhealthy' ?
              false :
              undefined,
          statusCode: Number(cells[4]),
          latency: cells[5],
          lastProbeTime: cells[6],
        };
      }),
    );

    return { probes };
  }

  return {};
}

function assertLiveData(result, expectedPage, kubectl) {
  if (expectedPage.kind === 'summary') {
    assert(result.namespaceCount > 0, 'Cluster Summary showed zero namespaces');
    assert(result.podCount > 0, 'Cluster Summary showed zero pods');
    assert(
      result.namespaceCount === kubectl.namespaceCount,
      'Cluster Summary namespace count does not match kubectl',
    );
    assert(
      result.podCount === kubectl.podCount,
      'Cluster Summary pod count does not match kubectl',
    );

    for (const namespace of result.namespaceNames) {
      assert(
        kubectl.namespaces.includes(namespace),
        `Cluster Summary showed unknown namespace: ${ namespace }`,
      );
    }

    const podNames = new Set(kubectl.pods.map(({ name }) => name));

    for (const pod of result.podNames) {
      assert(podNames.has(pod), `Cluster Summary showed unknown pod: ${ pod }`);
    }
  }

  if (expectedPage.kind === 'pods') {
    assert(result.podCount > 0, 'Pod Inspector showed zero pods');
    assert(
      result.podCount === kubectl.podCount,
      'Pod Inspector count does not match kubectl',
    );
    assert(
      result.pods.length === kubectl.podCount,
      'Pod Inspector did not render every live pod',
    );
    const podKeys = new Set(
      kubectl.pods.map(({ namespace, name }) => `${ namespace }/${ name }`),
    );

    for (const pod of result.pods) {
      assert(
        podKeys.has(`${ pod.namespace }/${ pod.name }`),
        `Pod Inspector showed unknown pod: ${ pod.namespace }/${ pod.name }`,
      );
    }
  }

  if (expectedPage.kind === 'probes') {
    assert(
      result.probes.length === kubectl.modelProbes.length,
      'Model Probes did not render every live ModelProbe',
    );
    const kubectlProbes = new Map(kubectl.modelProbes.map((probe) => [
      `${ probe.namespace }/${ probe.name }`,
      probe,
    ]));

    for (const probe of result.probes) {
      const expected = kubectlProbes.get(
        `${ probe.namespace }/${ probe.name }`,
      );

      assert(expected, `Model Probes showed unknown resource: ${ probe.name }`);
      assert(probe.url === expected.url, `ModelProbe URL differs: ${ probe.name }`);
      assert(
        probe.healthy === expected.healthy,
        `ModelProbe health differs: ${ probe.name }`,
      );
      assert(
        probe.statusCode === expected.statusCode,
        `ModelProbe status code differs: ${ probe.name }`,
      );
      assert(
        probe.lastProbeTime !== 'Pending',
        `ModelProbe status is pending: ${ probe.name }`,
      );
    }

    assert(
      result.probes.some(({ healthy }) => healthy === true),
      'Model Probes showed no healthy resource',
    );
    assert(
      result.probes.some(({ healthy }) => healthy === false),
      'Model Probes showed no unhealthy resource',
    );
  }
}

async function directRefresh(browser, config, token, expectedPage, kubectl) {
  const run = await newRun(browser, config, token);

  try {
    await openPage(
      run.page,
      config,
      pagePath(expectedPage, config.cluster),
      expectedPage.label,
    );
    const route = await run.page.evaluate(() => document.querySelector('#app')
      ?.__vue_app__?.config?.globalProperties?.$router?.currentRoute?.value?.name);
    const live = await readLivePage(run.page, expectedPage);
    const navigation = await captureNavigation(
      run.page,
      config.pages,
      config.cluster,
    );
    const errors = errorEvidence(run);

    assert(route === expectedPage.route, `Hard refresh matched the wrong route for ${ expectedPage.label }`);
    assertNavigation(navigation, config.pages);
    assertLiveData(live, expectedPage, kubectl);
    assert(
      errors.registrationErrors.length === 0,
      `Registration errors on hard refresh for ${ expectedPage.label }`,
    );

    if (
      expectedPage.kind === 'summary' ||
      expectedPage.kind === 'pods' ||
      expectedPage.kind === 'probes'
    ) {
      const screenshotNames = {
        summary: 'cluster-summary.png',
        pods: 'pod-inspector.png',
        probes: 'model-probes.png',
      };

      await run.page.screenshot({
        path: path.join(
          config.artifacts,
          screenshotNames[expectedPage.kind],
        ),
        fullPage: false,
      });
    }

    return {
      label: expectedPage.label,
      route,
      url: run.page.url(),
      navigation,
      live,
      ...errors,
    };
  } finally {
    await run.context.close();
  }
}

async function addEntryProbe(page, ids) {
  await page.addInitScript((pluginIds) => {
    window.__xtkEntryEvents = [];

    for (const id of pluginIds) {
      Object.defineProperty(window, id, {
        configurable: true,
        set(module) {
          const original = module.default;
          const wrapped = function(...args) {
            window.__xtkEntryEvents.push({ id, at: Date.now() });
            return original.apply(this, args);
          };
          const instrumented = new Proxy(module, {
            get(target, property, receiver) {
              return property === 'default' ?
                wrapped :
                Reflect.get(target, property, receiver);
            },
          });

          Object.defineProperty(window, id, {
            configurable: true,
            value: instrumented,
            writable: true,
          });
        },
      });
    }
  }, ids);
}

async function preReleaseState(page, ids) {
  return page.evaluate((pluginIds) => {
    const app = document.querySelector('#app')?.__vue_app__;
    const store = app?.config?.globalProperties?.$store;

    return {
      globals: Object.fromEntries(pluginIds.map((id) => [
        id,
        typeof window[id]?.default === 'function',
      ])),
      entryEvents: window.__xtkEntryEvents ?? [],
      productExists: Boolean(
        store?.getters?.['type-map/productByName']?.('suseai'),
      ),
    };
  }, ids);
}

async function loadOrderCheck(browser, config, token, mode) {
  const run = await newRun(browser, config, token);
  const childIds = [...new Set(config.pages.map(
    ({ plugin, version }) => `${ plugin }-${ version }`,
  ))];
  const aifId = `aif-ui-${ config.aifVersion }`;
  const probeIds = mode === 'child-first' ? childIds : [aifId];
  const delayedPatterns = mode === 'child-first' ?
    [routePattern('aif-ui', config.aifVersion)] :
    [...new Map(config.pages.map((page) => [
      `${ page.plugin }/${ page.version }`,
      routePattern(page.plugin, page.version),
    ])).values()];
  const preRelease = [];

  await addEntryProbe(run.page, probeIds);

  for (const pattern of delayedPatterns) {
    await run.page.route(pattern, async(route) => {
      await new Promise((resolve) => setTimeout(resolve, config.delayMs));
      preRelease.push({
        at: Date.now(),
        url: route.request().url(),
        state: await preReleaseState(run.page, [...childIds, aifId]),
      });
      await route.continue();
    });
  }

  try {
    await openPage(
      run.page,
      config,
      `/c/${ config.cluster }/suseai/overview`,
      'Overview',
    );
    const navigation = await captureNavigation(
      run.page,
      config.pages,
      config.cluster,
    );
    const errors = errorEvidence(run);

    assertNavigation(navigation, config.pages);
    assert(
      errors.registrationErrors.length === 0,
      `${ mode } load has registration errors`,
    );

    if (mode === 'child-first') {
      const first = preRelease[0]?.state;

      assert(first, 'The AIF bundle was not delayed');
      assert(
        childIds.every((id) =>
          first.globals[id] &&
          first.entryEvents.some((event) => event.id === id)),
        'Every child entry did not execute before AIF',
      );
      assert(!first.globals[aifId], 'AIF executed before its delay was released');
    } else {
      assert(
        preRelease.length === delayedPatterns.length,
        'Every child bundle was not delayed',
      );
      assert(
        preRelease.every(({ state }) =>
          state.globals[aifId] &&
          state.entryEvents.some((event) => event.id === aifId)),
        'AIF did not execute before the child bundles',
      );
    }

    return {
      mode,
      delayMilliseconds: config.delayMs,
      preRelease,
      bundleEvents: run.bundleEvents,
      navigation,
      ...errors,
    };
  } finally {
    await run.context.close();
  }
}

async function permissionCheck(browser, config, token) {
  const run = await newRun(browser, config, token);
  const podPage = config.pages.find(({ kind }) => kind === 'pods');

  assert(podPage, 'Permission check requires a page with kind "pods"');

  try {
    await openPage(
      run.page,
      config,
      `/c/${ config.cluster }/suseai/overview`,
      'Overview',
    );
    await openExtensions(run.page, config.pages, config.cluster);

    const gateConfig = await run.page.evaluate((positiveName) => {
      const app = document.querySelector('#app')?.__vue_app__;
      const store = app?.config?.globalProperties?.$store;

      if (!store) {
        throw new Error('Could not access the Rancher store');
      }

      const negativeName = 'suseai.ext.xtk-proof.denied';
      const negativeLabel = 'Denied verb probe';

      store.commit('type-map/virtualType', {
        product: 'suseai',
        obj: {
          name: negativeName,
          label: negativeLabel,
          route: { name: 'c-cluster-suseai-overview' },
          ifHaveType: 'pod',
          ifHaveVerb: 'XTK_DENIED',
        },
      });
      store.commit('type-map/basicType', {
        product: 'suseai',
        types: [negativeName],
        group: 'Extensions',
      });
      store.commit('type-map/weightType', {
        type: negativeLabel,
        weight: 40,
        forBasic: true,
      });

      const virtualTypes = store.state['type-map'].virtualTypes.suseai;

      return [positiveName, negativeName]
        .map((name) => virtualTypes.find((type) => type.name === name))
        .map((type) => ({
          name: type?.name,
          ifHaveType: type?.ifHaveType,
          ifHaveVerb: type?.ifHaveVerb,
        }));
    }, podPage.virtualTypeName);

    await run.page.waitForTimeout(500);

    const positiveVisible = await visibleCount(
      run.page.locator('nav.side-nav')
        .locator(`a[href$="${ pagePath(podPage, config.cluster) }"]`),
    );
    const negativeVisible = await visibleCount(
      run.page.getByText('Denied verb probe', { exact: true }),
    );
    const errors = errorEvidence(run);

    assert(
      JSON.stringify(gateConfig[0]) === JSON.stringify({
        name: podPage.virtualTypeName,
        ifHaveType: 'pod',
        ifHaveVerb: 'GET',
      }),
      'Pod Inspector does not have the expected pod GET gate',
    );
    assert(positiveVisible === 1, 'Pod Inspector is not visible with pod GET');
    assert(negativeVisible === 0, 'The denied verb probe is visible');
    assert(
      errors.registrationErrors.length === 0,
      'Permission check has registration errors',
    );

    return {
      gateConfig,
      positiveVisible,
      negativeVisible,
      ...errors,
    };
  } finally {
    await run.context.close();
  }
}

async function aifAbsentCheck(browser, config, token) {
  const run = await newRun(browser, config, token);
  const childIds = [...new Set(config.pages.map(
    ({ plugin, version }) => `${ plugin }-${ version }`,
  ))];

  await addEntryProbe(run.page, childIds);
  await run.page.route(
    routePattern('aif-ui', config.aifVersion),
    (route) => route.abort('blockedbyclient'),
  );

  try {
    await run.page.goto(
      `${ config.baseUrl }/dashboard/c/${ config.cluster }/explorer`,
      { waitUntil: 'domcontentloaded' },
    );
    await run.page.waitForFunction(() => document.querySelector('#app')
      ?.__vue_app__?.config?.globalProperties
      ?.$router?.currentRoute?.value?.name === 'c-cluster-explorer', undefined, {
      timeout: 60_000,
    });
    await run.page.locator('nav.side-nav').waitFor({
      state: 'visible',
      timeout: 60_000,
    });
    await run.page.waitForFunction((ids) => ids.every((id) =>
      typeof window[id]?.default === 'function'), childIds, {
      timeout: 60_000,
    });
    await run.page.waitForTimeout(1_000);

    const state = await run.page.evaluate(() => {
      const app = document.querySelector('#app')?.__vue_app__;
      const globals = app?.config?.globalProperties;
      const store = globals?.$store;
      const router = globals?.$router;
      const product = store?.getters?.['type-map/productByName']?.('suseai');
      const links = [...document.querySelectorAll('a[href*="/suseai"]')]
        .filter((link) => {
          const box = link.getBoundingClientRect();
          const style = window.getComputedStyle(link);

          return box.width > 0 && box.height > 0 &&
            style.display !== 'none' && style.visibility !== 'hidden';
        })
        .map((link) => ({
          href: link.getAttribute('href'),
          text: link.textContent?.replace(/\s+/g, ' ').trim(),
        }));

      return {
        productState: (store?.state?.['type-map']?.products ?? [])
          .map(({ name }) => ({ name })),
        suseaiProduct: product ?? null,
        visibleSuseaiLinks: links,
        childEntryEvents: window.__xtkEntryEvents ?? [],
        childVirtualTypes:
          (store?.state?.['type-map']?.virtualTypes?.suseai ?? [])
            .map(({ name }) => name),
        renderedPage: {
          route: router?.currentRoute?.value?.name,
          mainText: document.querySelector('main')
            ?.innerText?.replace(/\s+/g, ' ').trim().slice(0, 300) ?? '',
          sideNavVisible: Boolean(
            document.querySelector('nav.side-nav')?.getBoundingClientRect().width,
          ),
        },
      };
    });
    const errors = errorEvidence(run);

    assert(state.suseaiProduct === null, 'A child created a stray suseai product');
    assert(
      !state.productState.some(({ name }) => name === 'suseai'),
      'suseai exists in type-map products while AIF is blocked',
    );
    assert(
      state.visibleSuseaiLinks.length === 0,
      'A stray suseai link is visible while AIF is blocked',
    );
    assert(
      childIds.every((id) =>
        state.childEntryEvents.some((event) => event.id === id)),
      'Every child entry did not execute while AIF was blocked',
    );
    assert(
      state.renderedPage.route === 'c-cluster-explorer' &&
        state.renderedPage.sideNavVisible &&
        state.renderedPage.mainText.length > 0,
      'Cluster Explorer did not render while AIF was blocked',
    );

    return {
      ...state,
      ...errors,
    };
  } finally {
    await run.context.close();
  }
}

async function createModelProbeThroughUi(browser, config, token) {
  const probePage = config.pages.find(({ kind }) => kind === 'probes');

  assert(probePage, 'UI create check requires a page with kind "probes"');

  const input = {
    name: config.uiProbeName,
    namespace: config.uiProbeNamespace,
    url: config.uiProbeUrl,
  };

  runKubectl(config.kubectlContext, [
    '-n',
    input.namespace,
    'delete',
    'modelprobe',
    input.name,
    '--ignore-not-found',
    '--wait=true',
  ]);

  const run = await newRun(browser, config, token);

  try {
    await openPage(
      run.page,
      config,
      pagePath(probePage, config.cluster),
      probePage.label,
    );
    await run.page.getByTestId('probe-name').fill(input.name);
    await run.page.getByTestId('probe-namespace').fill(input.namespace);
    await run.page.getByTestId('probe-url').fill(input.url);

    const createRequest = run.page.waitForRequest((request) =>
      request.method() === 'POST' &&
      request.url().includes('xtk.aiflab.io.modelprobes'), {
      timeout: 30_000,
    });

    await run.page.getByTestId('create-probe').click();
    const request = await createRequest;
    await run.page.getByText(`Created ${ input.name }.`, {
      exact: true,
    }).waitFor({
      state: 'visible',
      timeout: 30_000,
    });
    await run.page.waitForFunction((name) =>
      [...document.querySelectorAll('[data-testid="modelprobe-row"]')]
        .some((row) =>
          row.textContent?.includes(name) &&
          !row.querySelector('[data-testid="probe-status"]')
            ?.textContent?.includes('Pending')), input.name, {
      timeout: 60_000,
    });

    const resource = JSON.parse(runKubectl(config.kubectlContext, [
      '-n',
      input.namespace,
      'get',
      'modelprobe',
      input.name,
      '-o',
      'json',
    ]));
    const row = await run.page.getByTestId('modelprobe-row')
      .filter({ hasText: input.name })
      .innerText();
    const errors = errorEvidence(run);

    assert(resource.spec.url === input.url, 'UI-created ModelProbe URL differs');
    assert(
      typeof resource.status?.healthy === 'boolean' &&
        typeof resource.status?.lastProbeTime === 'string',
      'UI-created ModelProbe has no controller status',
    );
    assert(
      errors.registrationErrors.length === 0,
      'UI create check has registration errors',
    );

    await run.page.screenshot({
      path: path.join(config.artifacts, 'model-probes.png'),
      fullPage: false,
    });

    return {
      input,
      request: {
        method: request.method(),
        url: request.url(),
      },
      row,
      status: resource.status,
      ...errors,
    };
  } finally {
    await run.context.close();
  }
}

async function checkA(browser, config, token, kubectl) {
  const run = await newRun(browser, config, token);
  let base;

  try {
    await openPage(
      run.page,
      config,
      `/c/${ config.cluster }/suseai/overview`,
      'Overview',
    );
    const runtime = await captureRuntime(
      run.page,
      config.pages,
    );
    const navigation = await captureNavigation(
      run.page,
      config.pages,
      config.cluster,
    );
    const errors = errorEvidence(run);

    assertRuntime(runtime, config.pages);
    assertNavigation(navigation, config.pages);
    assert(
      errors.registrationErrors.length === 0,
      'Check A has registration errors',
    );

    base = {
      stockRouteCount: STOCK_ROUTES.length,
      runtime,
      navigation,
      directRefreshes: [],
      ...errors,
    };
  } finally {
    await run.context.close();
  }

  for (const expectedPage of config.pages) {
    base.directRefreshes.push(
      await directRefresh(browser, config, token, expectedPage, kubectl),
    );
  }

  return base;
}

async function main() {
  const args = parseArguments(process.argv.slice(2));

  if (args.help) {
    printHelp();
    return;
  }

  const baseUrl = args.url ?? process.env.RANCHER_URL;
  const username = args.user ?? process.env.RANCHER_USER;
  const password = args.password ?? process.env.RANCHER_PASSWORD;

  assert(baseUrl, 'Set RANCHER_URL or pass --url');
  assert(username, 'Set RANCHER_USER or pass --user');
  assert(password, 'Set RANCHER_PASSWORD or pass --password');

  const config = {
    baseUrl: baseUrl.replace(/\/$/, ''),
    username,
    password,
    cluster: args.cluster ?? process.env.RANCHER_CLUSTER ?? 'local',
    artifacts: path.resolve(
      args.artifacts ??
      process.env.XTK_ARTIFACTS_DIR ??
      path.join(process.cwd(), 'artifacts'),
    ),
    pages: parsePages(
      args['pages-json'] ?? process.env.XTK_EXPECTED_PAGES,
    ),
    kubectlContext:
      args['kubectl-context'] ?? process.env.KUBECTL_CONTEXT ?? '',
    delayMs: Number(args['delay-ms'] ?? process.env.XTK_DELAY_MS ?? 3_500),
    aifVersion: process.env.AIF_UI_VERSION ?? '2.4.0',
    uiProbeName: process.env.XTK_UI_PROBE_NAME ?? 'ui-created',
    uiProbeNamespace: process.env.XTK_UI_PROBE_NAMESPACE ?? 'xtk-system',
    uiProbeUrl: process.env.XTK_UI_PROBE_URL ??
      'http://xtk-modelprobe-server.cattle-ui-plugin-system.svc:8080/healthz',
  };

  assert(
    Number.isFinite(config.delayMs) && config.delayMs >= 0,
    '--delay-ms must be a non-negative finite number',
  );
  fs.mkdirSync(config.artifacts, { recursive: true });

  const reportPath = path.join(config.artifacts, 'verification-report.json');
  const report = {
    generatedAt: new Date().toISOString(),
    target: {
      baseUrl: config.baseUrl,
      username: config.username,
      cluster: config.cluster,
      aifVersion: config.aifVersion,
      expectedPages: config.pages,
    },
    ok: false,
    kubectl: null,
    checks: {},
  };
  const browser = await chromium.launch({ headless: true });

  try {
    const token = await loginToken(
      config.baseUrl,
      config.username,
      config.password,
    );

    report.kubectl = captureKubectl(config.kubectlContext);
    assert(report.kubectl.namespaceCount > 0, 'kubectl found zero namespaces');
    assert(report.kubectl.podCount > 0, 'kubectl found zero pods');

    report.checks.A = await checkA(
      browser,
      config,
      token,
      report.kubectl,
    );
    report.checks.A.passed = true;

    const childFirst = await loadOrderCheck(
      browser,
      config,
      token,
      'child-first',
    );
    const aifFirst = await loadOrderCheck(
      browser,
      config,
      token,
      'aif-first',
    );

    assert(
      JSON.stringify(childFirst.navigation) ===
        JSON.stringify(aifFirst.navigation),
      'Load orders produced different sidebars',
    );
    report.checks.B = {
      passed: true,
      childFirst,
      aifFirst,
    };

    report.checks.C = {
      passed: true,
      ...await permissionCheck(browser, config, token),
    };
    report.checks.D = {
      passed: true,
      ...await aifAbsentCheck(browser, config, token),
    };
    report.checks.E = {
      passed: true,
      ...await createModelProbeThroughUi(browser, config, token),
    };
    report.ok = true;
  } catch (error) {
    report.error = {
      name: error instanceof Error ? error.name : 'Error',
      message: error instanceof Error ? error.message : String(error),
      stack: error instanceof Error ? error.stack : undefined,
    };
    throw error;
  } finally {
    await browser.close();
    fs.writeFileSync(
      reportPath,
      `${ JSON.stringify(report, null, 2) }\n`,
    );
    process.stdout.write(`${ JSON.stringify(report, null, 2) }\n`);
  }
}

main().catch((error) => {
  process.stderr.write(`${ error.stack ?? error }\n`);
  process.exitCode = 1;
});
