// Mock data for browser-only preview (Vite dev server, no FiveM NUI bridge).
export function debugCharacters() {
  return [
    {
      character: {
        id: 1, first_name: 'Kayla', last_name: 'West', gender: 'female',
        dob: '1994-03-12', bio: 'Detective · LSPD', last_played_at: '2 hours ago',
      },
      appearance: null,
    },
    {
      character: {
        id: 2, first_name: 'Marco', last_name: 'Vance', gender: 'male',
        dob: '1989-11-02', bio: 'Mechanic · Benny\'s', last_played_at: '1 day ago',
      },
      appearance: null,
    },
  ]
}
