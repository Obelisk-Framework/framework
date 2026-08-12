import { ref, computed, onUnmounted } from 'vue'
import Obelisk from '../../../web/src/obelisk.js'
import { debugCharacters } from './devFixture.js'

const isDev = import.meta.env.DEV

export function useCharacterSelection() {
  const characters = ref(isDev ? debugCharacters() : [])
  const selectedIndex = ref(0)
  const mode = ref('select') // 'select' | 'create'
  const gender = ref('male')

  const selected = computed(() => characters.value[selectedIndex.value] || null)

  function list() {
    if (isDev) {
      characters.value = debugCharacters()
      return
    }
    Obelisk.emit('character-selection:list')
  }

  function create(attributes) {
    if (isDev) {
      characters.value.push({ character: { id: Date.now(), ...attributes }, appearance: attributes.appearance })
      mode.value = 'select'
      return
    }
    Obelisk.emit('character-selection:create', attributes)
  }

  function deleteCharacter(characterId) {
    if (isDev) {
      characters.value = characters.value.filter(c => c.character.id !== characterId)
      return
    }
    Obelisk.emit('character-selection:delete', { characterId })
  }

  function select(characterId) {
    const entry = characters.value.find(c => c.character.id === characterId)
    Obelisk.emit('character-selection:select', { characterId, appearance: entry?.appearance })
  }

  function updatePreview(payload) {
    Obelisk.emit('character-selection:preview-update', payload)
  }

  // Named callback functions to enable proper cleanup
  const onListResult = (list) => { characters.value = list }
  const onCreated = (attrs) => { list() }
  const onDeleted = () => { list() }

  Obelisk.on('character-selection:list-result', onListResult)
  Obelisk.on('character-selection:created', onCreated)
  Obelisk.on('character-selection:deleted', onDeleted)

  // Unregister listeners when component unmounts to prevent listener buildup
  onUnmounted(() => {
    Obelisk.off('character-selection:list-result', onListResult)
    Obelisk.off('character-selection:created', onCreated)
    Obelisk.off('character-selection:deleted', onDeleted)
  })

  return { characters, selectedIndex, mode, gender, selected, list, create, deleteCharacter, select, updatePreview }
}
