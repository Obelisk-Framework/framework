import { createRouter, createWebHistory } from 'vue-router';
import coreRoutes from './coreRoutes';

const pluginRouteModules = import.meta.glob(
  ['../../../modules/*/web/routes.js', '../../../plugins/*/web/routes.js'],
  { eager: true }
);

let pluginRoutes = [];
for (const mod of Object.values(pluginRouteModules)) {
  if (Array.isArray(mod.default)) {
    pluginRoutes.push(...mod.default);
  }
}

const routes = [
  ...coreRoutes,
  ...pluginRoutes
];

const router = createRouter({
  history: createWebHistory(),
  routes,
});

export default router;