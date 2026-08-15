export default [
  {
    path: '/ShellBrowser',
    name: 'ShellBrowser',
    component: () => import('./ShellBrowser.vue')
  },
  {
    path: '/ShellEditor',
    name: 'ShellEditor',
    component: () => import('./ShellEditor.vue')
  }
]
