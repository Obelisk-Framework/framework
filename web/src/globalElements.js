import Notifications from './components/global/Notifications.vue'
import ProgressBars from './components/global/ProgressBars.vue'

export default [
  { name: 'notifications', component: Notifications, defaultVisible: true },
  { name: 'progressBars', component: ProgressBars, defaultVisible: true }
]
