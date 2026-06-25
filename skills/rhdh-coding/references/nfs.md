# NFS (New Frontend System) Coding Patterns

## Alpha File Structure (`src/alpha.tsx`)

```tsx
import {
  ApiBlueprint, createApiFactory, createFrontendModule, createFrontendPlugin,
  createRouteRef, createSubRouteRef, PageBlueprint,
} from '@backstage/frontend-plugin-api';
import { TranslationBlueprint } from '@backstage/plugin-app-react';
import { EntityCardBlueprint, EntityContentBlueprint } from '@backstage/plugin-catalog-react/alpha';
```

## Route Refs

```tsx
const rootRouteRef = createRouteRef(); // bulk-import alpha.tsx
const detailRouteRef = createSubRouteRef({ parent: rootRouteRef, path: '/detail/:id' });
```

Legacy `createRouteRef({ id: 'xxx' })` from `@backstage/core-plugin-api` also works (orchestrator) but prefer NFS-native.

## PageBlueprint

```tsx
// bulk-import alpha.tsx
PageBlueprint.make({
  params: {
    path: '/bulk-import', routeRef: rootRouteRef, noHeader: true,
    loader: () => import('./components').then(({ Router }) => <Router />),
  },
});
```

**noHeader**: RHDH plugins commonly use `noHeader: true` when the plugin renders its own header with breadcrumbs, tabs, or permission controls. Omit it if you want the framework-provided `PluginHeader`.

## ApiBlueprint

```tsx
// orchestrator alpha.tsx
ApiBlueprint.make({
  params: defineParams => defineParams(
    createApiFactory({
      api: orchestratorApiRef,
      deps: { discoveryApi: discoveryApiRef, identityApi: identityApiRef },
      factory: ({ discoveryApi, identityApi }) =>
        new OrchestratorClient({ discoveryApi, identityApi }),
    }),
  ),
});
```

Multiple APIs in one plugin require a `name`: `ApiBlueprint.make({ name: 'npmBackendApi', params: ... })`.

## EntityContentBlueprint and EntityCardBlueprint

```tsx
// orchestrator alpha.tsx — entity tab
EntityContentBlueprint.make({
  name: 'workflows',
  params: {
    path: '/workflows', title: 'Workflows',
    filter: (entity) => Boolean(entity.metadata?.annotations?.['orchestrator.io/workflows']),
    loader: () => import('./components/CatalogTab').then(m => <m.CatalogTab />),
  },
});
// npm alpha.tsx (community-plugins) — entity card
EntityCardBlueprint.make({
  name: 'EntityNpmInfoCard',
  params: {
    filter: isNpmAvailable,
    loader: () => import('./components/EntityNpmInfoCard').then(m => <m.EntityNpmInfoCard />),
  },
});
```

## Nav items

`NavItemBlueprint` was removed. Nav items are now auto-discovered from `PageBlueprint` extensions with `title`, `icon`, and `routeRef`. No separate blueprint needed.

## Plugin and Module Exports

Default export = plugin. TranslationBlueprint must go in a separate module with `pluginId: 'app'`:

```tsx
export default createFrontendPlugin({
  pluginId: 'bulk-import',
  extensions: [bulkImportApi, bulkImportPage],
  routes: { root: rootRouteRef, tasks: importHistoryRouteRef },
});
export const translationsModule = createFrontendModule({
  pluginId: 'app',
  extensions: [TranslationBlueprint.make({
    name: 'bulk-import-translations', params: { resource: bulkImportTranslations },
  })],
});
```

## Package Exports

### New NFS-only plugins

The NFS plugin is the root export (`.`). No `./alpha`, no `./legacy`, no
scalprum config, no `dist-scalprum/`. The app discovers and loads it via
`app.packages`.

```json
{ "main": "src/index.ts", "types": "src/index.ts",
  "exports": { ".": "./src/index.ts", "./package.json": "./package.json" },
  "backstage": { "role": "frontend-plugin", "pluginId": "my-plugin" } }
```

No scalprum section needed. No `export-dynamic-plugin` step. Package as a
standard npm package in an OCI image for deployment.

### Migrated plugins (alpha approach — default)

NFS at `./alpha`, legacy unchanged at root. No breaking changes for consumers:

```json
{ "exports": {
    ".": "./src/index.ts",
    "./alpha": "./src/alpha.tsx",
    "./package.json": "./package.json"
  },
  "typesVersions": { "*": { "alpha": ["src/alpha.tsx"] } } }
```

- `src/index.ts` — existing legacy exports (unchanged)
- `src/alpha.tsx` — NFS plugin (`createFrontendPlugin`, Blueprints)

The `scalprum.exposedModules` entries some plugins still have are transition
baggage — NFS apps don't load through scalprum. Remove when legacy is dropped.

## compatWrapper

`compatWrapper` from `@backstage/core-compat-api` bridges legacy components into NFS.

- **Needed**: plugin uses `@material-ui/*` (MUI v4) or legacy route refs (tech-radar uses `compatWrapper` + `convertLegacyRouteRef`).
- **Not needed**: plugin uses `@mui/*` (MUI v5) and NFS-native route refs (orchestrator, bulk-import skip it).
- **Not needed for new NFS-only plugins**: no legacy code to bridge.
