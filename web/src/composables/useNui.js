import { useRouter } from 'vue-router'

/**
 * Composable for NUI interactions with FiveM
 */
export function useNui() {
  const router = useRouter()
  
  /**
   * Navigate to a route
   * @param {string} path - Route path
   */
  const navigate = (path) => {
    router.push(path)
  }
  
  /**
   * Send data to Lua client
   * @param {string} callback - Callback name
   * @param {object} data - Data to send
   */
  const sendCallback = async (callback, data = {}) => {
    if (!window.invokeNative) {
      console.log('[Dev] NUI Callback:', callback, data)
      return
    }
    
    try {
      const response = await fetch(`https://${getResourceName()}/${callback}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(data)
      })
      
      return await response.json()
    } catch (error) {
      console.error('NUI Callback error:', error)
    }
  }
  
  /**
   * Get the parent resource name
   * @returns {string}
   */
  const getResourceName = () => {
    const currentUrl = window.location.href
    const match = currentUrl.match(/https?:\/\/(.*?)\//)
    return match ? match[1] : 'obelisk'
  }
  
  /**
   * Toggle visibility of the NUI frame
   * @param {boolean} visible
   */
  const setVisible = (visible) => {
    sendCallback('core:client:setVisible', { visible })
  }
  
  /**
   * Listen for messages from Lua
   * @param {Function} handler - Message handler
   */
  const onMessage = (handler) => {
    const messageHandler = (event) => {
      handler(event.data)
    }
    
    window.addEventListener('message', messageHandler)
    
    // Return cleanup function
    return () => {
      window.removeEventListener('message', messageHandler)
    }
  }
  
  return {
    navigate,
    sendCallback,
    getResourceName,
    setVisible,
    onMessage
  }
}
