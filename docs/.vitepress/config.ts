import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Obelisk Framework',
  description: 'A modern FiveM framework with Lua, Vue 3, and MariaDB/PostgreSQL',
  base: '/core/',
  ignoreDeadLinks: false,

  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/core/favicon.svg' }]
  ],

  themeConfig: {
    logo: { light: '/logo-light.svg', dark: '/logo-dark.svg' },

    nav: [
      { text: 'Guide', link: '/guide/introduction' },
      { text: 'Concepts', link: '/concepts/orm' },
      { text: 'Modules', link: '/modules/items' },
      { text: 'CLI', link: '/cli/index' },
      { text: 'Examples', link: '/examples/building-a-plugin' },
      { text: 'Reference', link: '/reference/existing-plugins' },
      { text: 'Plugin Hub', link: '/plugin-hub' }
    ],

    sidebar: {
      '/guide/': [
        {
          text: 'Guide',
          items: [
            { text: 'Introduction', link: '/guide/introduction' },
            { text: 'Installation', link: '/guide/installation' },
            { text: 'Quick Start', link: '/guide/quick-start' }
          ]
        }
      ],
      '/concepts/': [
        {
          text: 'Concepts',
          items: [
            { text: 'ORM', link: '/concepts/orm' },
            { text: 'Services', link: '/concepts/services' },
            { text: 'WebView & NUI', link: '/concepts/webview' },
            { text: 'Modules & Plugins', link: '/concepts/modules-and-plugins' }
          ]
        }
      ],
      '/modules/': [
        {
          text: 'Modules',
          items: [
            { text: 'Items', link: '/modules/items' },
            { text: 'Vehicles', link: '/modules/vehicles' }
          ]
        }
      ],
      '/cli/': [
        {
          text: 'CLI',
          items: [
            { text: 'Command Reference', link: '/cli/index' }
          ]
        }
      ],
      '/examples/': [
        {
          text: 'Examples',
          items: [
            { text: 'Building a Plugin', link: '/examples/building-a-plugin' }
          ]
        }
      ],
      '/reference/': [
        {
          text: 'Reference',
          items: [
            { text: 'ORM API Reference', link: '/reference/orm' },
            { text: 'Existing Plugins', link: '/reference/existing-plugins' }
          ]
        }
      ]
    },

    socialLinks: [
      { icon: 'github', link: 'https://github.com/Obelisk-Framework/core' }
    ]
  }
})
