/** The number N of an [Image #N] chip in the prompt box. */
export type ChipNumber = number

declare module 'claude-code' {
  interface PluginState {
    'image-peek': { chips: Shaped<ChipNumber[]> }
  }
}
