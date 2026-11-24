import { registerAifExtension } from '@aif-xtk/sdk';
import type { RancherPlugin } from '@aif-xtk/sdk';
import { importTypes } from '@rancher/auto-import';
import type { IPlugin } from '@shell/core/types';

import HelloPage from './pages/Hello.vue';

export default function register(plugin: IPlugin): void {
  importTypes(plugin);
  plugin.metadata = require('./package.json');
  registerAifExtension(plugin as unknown as RancherPlugin, {
    id:    'xtk-hello',
    pages: [{
      slug:      'hello',
      label:     'Hello from XTK',
      component: HelloPage,
      weight:    100,
    }],
  });
}
