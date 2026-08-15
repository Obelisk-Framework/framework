export default [
    {
        path: '/nativeMenu',
        name: 'NativeMenu',
        component: () => import('../pages/nativeMenu/NativeMenu.vue')
    },
    // Dev-only: import.meta.env.DEV is statically replaced at build time, so
    // these routes (and their components) are stripped entirely from prod builds.
    ...(import.meta.env.DEV ? [{
        path: '/',
        name: 'DevHudHelper',
        component: () => import('../pages/DevHudHelper.vue')
    }, {
        path: '/routes',
        name: 'RouteList',
        component: () => import('../pages/RouteList.vue')
    }] : [])
]