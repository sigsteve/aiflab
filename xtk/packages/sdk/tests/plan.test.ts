import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import {
  buildRoutes,
  parseExtensionDefinition,
  planExtensionRegistration,
} from '../src/index.ts';

const component = Object.freeze({ name: 'TestPage' });

describe('extension registration planning', () => {
  it('derives exact namespaced types and Rancher routes', () => {
    const planned = planExtensionRegistration({
      id:    'my-extension',
      pages: [
        {
          slug:   'overview',
          label:  ' Overview ',
          component,
          weight: 80,
        },
        {
          slug:   'pods',
          label:  'Pods',
          component,
          access: {
            kind:         'resource',
            resourceType: ' pod ',
            verb:         'GET',
          },
        },
        {
          slug:   'feature-page',
          label:  'Feature page',
          component,
          access: { kind: 'feature', feature: ' experimental ' },
        },
      ],
    });

    assert.deepEqual(planned, [
      {
        virtualTypeName: 'suseai.ext.my-extension.overview',
        routeName:       'c-cluster-suseai-ext-my-extension-overview',
        routePath:       '/c/:cluster/suseai/extensions/my-extension/overview',
        label:           'Overview',
        group:           'Extensions',
        weight:          80,
        access:          { kind: 'always' },
        component,
      },
      {
        virtualTypeName: 'suseai.ext.my-extension.pods',
        routeName:       'c-cluster-suseai-ext-my-extension-pods',
        routePath:       '/c/:cluster/suseai/extensions/my-extension/pods',
        label:           'Pods',
        group:           'Extensions',
        access:          {
          kind:         'resource',
          resourceType: 'pod',
          verb:         'GET',
        },
        component,
      },
      {
        virtualTypeName: 'suseai.ext.my-extension.feature-page',
        routeName:       'c-cluster-suseai-ext-my-extension-feature-page',
        routePath:
          '/c/:cluster/suseai/extensions/my-extension/feature-page',
        label:  'Feature page',
        group:  'Extensions',
        access: { kind: 'feature', feature: 'experimental' },
        component,
      },
    ]);

    assert.deepEqual(buildRoutes(planned), [
      {
        name: 'c-cluster-suseai-ext-my-extension-overview',
        path: '/c/:cluster/suseai/extensions/my-extension/overview',
        component,
        meta: { product: 'suseai' },
      },
      {
        name: 'c-cluster-suseai-ext-my-extension-pods',
        path: '/c/:cluster/suseai/extensions/my-extension/pods',
        component,
        meta: { product: 'suseai' },
      },
      {
        name: 'c-cluster-suseai-ext-my-extension-feature-page',
        path: '/c/:cluster/suseai/extensions/my-extension/feature-page',
        component,
        meta: { product: 'suseai' },
      },
    ]);
  });

  it('rejects invalid ids', () => {
    assert.throws(
      () => parseExtensionDefinition({
        id:    'Bad_Id',
        pages: [{
          slug: 'page', label: 'Page', component
        }],
      }),
      /id must be a kebab-case extension id/,
    );
  });

  it('rejects invalid slugs', () => {
    assert.throws(
      () => parseExtensionDefinition({
        id:    'valid-id',
        pages: [{
          slug: 'Bad_Slug', label: 'Page', component
        }],
      }),
      /pages\[0\]\.slug must be a kebab-case page slug/,
    );
  });

  it('rejects blank labels', () => {
    assert.throws(
      () => parseExtensionDefinition({
        id:    'valid-id',
        pages: [{
          slug: 'page', label: '   ', component
        }],
      }),
      /pages\[0\]\.label must be a non-empty string/,
    );
  });

  it('rejects empty page arrays', () => {
    assert.throws(
      () => parseExtensionDefinition({ id: 'valid-id', pages: [] }),
      /pages must be a non-empty array/,
    );
  });

  it('rejects duplicate slugs', () => {
    assert.throws(
      () => parseExtensionDefinition({
        id:    'valid-id',
        pages: [
          {
            slug: 'page', label: 'First', component
          },
          {
            slug: 'page', label: 'Second', component
          },
        ],
      }),
      /pages contains duplicate slug "page"/,
    );
  });

  it('rejects invalid access rules', () => {
    assert.throws(
      () => parseExtensionDefinition({
        id:    'valid-id',
        pages: [{
          slug:   'page',
          label:  'Page',
          component,
          access: { kind: 'resource', resourceType: ' ' },
        }],
      }),
      /access\.resourceType must be a non-empty string/,
    );
    assert.throws(
      () => parseExtensionDefinition({
        id:    'valid-id',
        pages: [{
          slug:   'page',
          label:  'Page',
          component,
          access: { kind: 'feature', feature: '' },
        }],
      }),
      /access\.feature must be a non-empty string/,
    );
    assert.throws(
      () => parseExtensionDefinition({
        id:    'valid-id',
        pages: [{
          slug:   'page',
          label:  'Page',
          component,
          access: { kind: 'unknown' },
        }],
      }),
      /access\.kind must be "always", "resource", or "feature"/,
    );
  });

  it('rejects non-finite weights', () => {
    assert.throws(
      () => parseExtensionDefinition({
        id:    'valid-id',
        pages: [{
          slug:   'page',
          label:  'Page',
          component,
          weight: Number.NaN,
        }],
      }),
      /weight must be a finite number/,
    );
  });
});
