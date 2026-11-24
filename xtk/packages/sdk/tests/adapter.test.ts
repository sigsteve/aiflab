import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { registerAifExtension } from '../src/index.ts';
import type {
  RancherPlugin,
  RancherProductRegistration,
  RancherRoute,
  RancherVirtualType,
} from '../src/index.ts';

describe('Rancher adapter', () => {
  it('uses only the safe legacy DSL calls and display-label weights', () => {
    const virtualTypes: RancherVirtualType[] = [];
    const basicTypes: Array<{
      typeNames: readonly string[];
      group: string;
    }> = [];
    const weights: Array<{
      label: string;
      weight: number;
      forBasic: true;
    }> = [];
    const routes: RancherRoute[] = [];
    const store = Object.freeze({ name: 'store' });
    let productCalls = 0;
    let weightGroupCalls = 0;
    let productName: string | undefined;
    let productRegistration: RancherProductRegistration | undefined;

    const dslWithForbiddenCalls = {
      virtualType(definition: RancherVirtualType) {
        virtualTypes.push(definition);
      },
      basicType(typeNames: readonly string[], group: string) {
        basicTypes.push({ typeNames, group });
      },
      weightType(label: string, weight: number, forBasic: true) {
        weights.push({
          label, weight, forBasic
        });
      },
      product() {
        productCalls += 1;
      },
      weightGroup() {
        weightGroupCalls += 1;
      },
    };
    const plugin: RancherPlugin = {
      addProduct(registration) {
        productRegistration = registration;
      },
      addRoutes(value) {
        routes.push(...value);
      },
      DSL(receivedStore, receivedProductName) {
        assert.equal(receivedStore, store);
        productName = receivedProductName;

        return dslWithForbiddenCalls;
      },
    };

    registerAifExtension(plugin, {
      id:    'test-extension',
      pages: [
        {
          slug:      'open',
          label:     'Open page',
          component: { name: 'OpenPage' },
          weight:    100,
        },
        {
          slug:      'pods',
          label:     'Pod page',
          component: { name: 'PodPage' },
          weight:    80,
          access:    {
            kind:         'resource',
            resourceType: 'pod',
            verb:         'GET',
          },
        },
        {
          slug:      'feature',
          label:     'Feature page',
          component: { name: 'FeaturePage' },
          weight:    60,
          access:    { kind: 'feature', feature: 'experimental' },
        },
      ],
    });

    assert.ok(productRegistration);
    assert.equal(routes.length, 3);

    productRegistration.init(plugin, store);

    assert.equal(productName, 'suseai');
    assert.equal(productCalls, 0);
    assert.equal(weightGroupCalls, 0);
    assert.deepEqual(virtualTypes, [
      {
        name:  'suseai.ext.test-extension.open',
        label: 'Open page',
        route: { name: 'c-cluster-suseai-ext-test-extension-open' },
      },
      {
        name:       'suseai.ext.test-extension.pods',
        label:      'Pod page',
        route:      { name: 'c-cluster-suseai-ext-test-extension-pods' },
        ifHaveType: 'pod',
        ifHaveVerb: 'GET',
      },
      {
        name:      'suseai.ext.test-extension.feature',
        label:     'Feature page',
        route:     { name: 'c-cluster-suseai-ext-test-extension-feature' },
        ifFeature: 'experimental',
      },
    ]);
    assert.deepEqual(basicTypes, [{
      typeNames: [
        'suseai.ext.test-extension.open',
        'suseai.ext.test-extension.pods',
        'suseai.ext.test-extension.feature',
      ],
      group: 'Extensions',
    }]);
    assert.deepEqual(weights, [
      {
        label: 'Open page', weight: 100, forBasic: true
      },
      {
        label: 'Pod page', weight: 80, forBasic: true
      },
      {
        label: 'Feature page', weight: 60, forBasic: true
      },
    ]);
    assert.ok(
      weights.every(({ label }) => !label.startsWith('suseai.ext.')),
      'weightType must use display labels',
    );
  });

  it('throws before registering an invalid definition', () => {
    let addProductCalls = 0;
    let addRouteCalls = 0;
    const plugin: RancherPlugin = {
      addProduct() {
        addProductCalls += 1;
      },
      addRoutes() {
        addRouteCalls += 1;
      },
      DSL() {
        throw new Error('DSL must not run');
      },
    };

    assert.throws(
      () => registerAifExtension(plugin, {
        id:    'INVALID',
        pages: [{
          slug: 'page', label: 'Page', component: {}
        }],
      }),
      /Invalid extension definition: id/,
    );
    assert.equal(addProductCalls, 0);
    assert.equal(addRouteCalls, 0);
  });
});
