export type Appearance = 'light' | 'dark'

declare module 'claude-code' {
  interface PluginState {
    'chat-cards': { appearance: Appearance }
  }
}
