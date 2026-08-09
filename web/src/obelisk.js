/**
 * The one NUI <-> client-Lua bridge. `on`/`off` register callbacks for
 * messages Lua sends via SendNUIMessage ({eventname, args}); `emit` posts to
 * the matching RegisterNUICallback name on the client Lua side.
 */
class Obelisk {
  events = new Map()

  constructor() {
    window.addEventListener('message', (event) => {
      const { eventname, args = [] } = event.data
      const cbs = this.events.get(eventname)
      if (cbs) Promise.allSettled(cbs.map(cb => cb(...args)))
    })
  }

  on(eventName, cb) {
    if (!this.events.has(eventName)) this.events.set(eventName, [])
    const cbs = this.events.get(eventName)
    if (!cbs.includes(cb)) cbs.push(cb)
  }

  off(eventName, cb) {
    if (!this.events.has(eventName)) return
    const cbs = this.events.get(eventName).filter(callback => callback !== cb)
    if (cbs.length > 0) this.events.set(eventName, cbs)
    else this.events.delete(eventName)
  }

  async emit(eventName, args) {
    if (!window.invokeNative) {
      console.log('[Dev] NUI emit:', eventName, args)
      return
    }

    const res = await fetch(`https://${getResourceName()}/${eventName}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(args)
    })
    if (!res.ok) throw new Error(`HTTP error! Status: ${res.status}`)
    return await res.json()
  }
}

function getResourceName() {
  const match = window.location.href.match(/https?:\/\/(.*?)\//)
  return match ? match[1] : 'obelisk'
}

export default new Obelisk()
