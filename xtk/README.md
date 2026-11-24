# SUSE AI Factory extension toolkit

XTK adds independent pages to the stock SUSE AI Factory menu. It uses Rancher UI extensions and never patches Rancher or `aif-ui`.

## Prerequisites

- Rancher 2.13 through 2.16 with UI Extensions 3.x and SUSE AI Factory UI 2.4.0.
- A kubeconfig whose current context can manage the Rancher management cluster. Set `KUBECTL_CONTEXT` to use another context.
- Node.js 24, npm, and Make.
- Chromium for the verifier only.
- Docker or Podman for the ModelProbe controller example only. A local image load also requires RKE2 and passwordless sudo.

## Quick start

Run these commands:

1. `git clone https://github.com/sigsteve/aiflab.git`
2. `cd aiflab/xtk`
3. `npm install`
4. `cd examples/hello-extension`
5. `make deploy`

Open Rancher, select AI Factory, and expand Extensions. Select "Hello from XTK".

## Make your own

Run `cd ../..` to return to the XTK root. Run `npm run new -- my-first-ext`. The command copies [hello-extension](examples/hello-extension/), renames its package and extension ids, and keeps the same deploy commands.

Run `cd examples/my-first-ext`, then run `make deploy`. Edit [index.ts](examples/hello-extension/index.ts) and [Hello.vue](examples/hello-extension/pages/Hello.vue) to change the new page.

The registration call defines the menu page:

```ts
registerAifExtension(plugin as unknown as RancherPlugin, {
  id: 'my-first-ext',
  pages: [{
    slug: 'home',
    label: 'My First Ext',
    component: MyPage,
  }],
});
```

## Examples

- [Hello](examples/hello-extension/): one static page and the smallest starting point.
- [Kubernetes RBAC](examples/rbac-k8s-extension/): live namespaces and pods with a pod read gate.
- [ModelProbe](examples/modelprobe-extension/): a custom resource, controller, samples, and live create form.

Each example uses `make deploy` and `make undeploy` from its own folder.

## SDK rules

- [The SDK](packages/sdk/src/adapter.ts) registers child routes under the existing `suseai` product. It never creates or patches that product.
- Pages use the Extensions group by default.
- [Definition validation](packages/sdk/src/plan.ts) rejects invalid ids, invalid slugs, duplicate slugs, unknown fields, invalid weights, and invalid access rules.
- Deployments create separate `UIPlugin`, Deployment, Service, and ConfigMap resources. They do not modify stock AI Factory resources.

## Verify

Run `npm run check` from the XTK root.

For a live cluster, run `npx playwright install chromium`. Set `RANCHER_URL` to the Rancher origin and `RANCHER_USER` to a login name. Set the secret without putting it in shell history with `read -rsp 'Rancher password: ' RANCHER_PASSWORD; export RANCHER_PASSWORD`. Set `RANCHER_CLUSTER` when the target is not `local`. Then run `node verify/verify-aif-extension.mjs`.

The [verifier](verify/verify-aif-extension.mjs) checks stock routes and metadata, extension routes, sidebar order, hard refreshes, both bundle load orders, RBAC gating, behavior without AI Factory, live Kubernetes data, and ModelProbe creation. Set `XTK_ARTIFACTS_DIR` to choose its report directory.

## Uninstall

Run `make undeploy` in an example folder. Reload Rancher after an extension install or uninstall.

## Compatibility

XTK targets Rancher 2.13 through 2.16, UI Extensions 3.x, SUSE AI Factory UI 2.4.0, and the legacy Rancher extension DSL. The SDK keeps the public `registerAifExtension()` API stable.
