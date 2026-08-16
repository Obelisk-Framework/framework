// core/plugins/oblsk_reflexcheck/web/routes.js
export default [
  {
    path: '/ReflexCheck',
    name: 'ReflexCheck',
    component: () => import('./ReflexCheck.vue'),
  },
]
