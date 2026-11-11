# image-peek

A Claude Code mod that shows a small preview of each pasted image.

When you paste an image, Claude Code puts an `[Image #N]` chip in the prompt.
The chip shows no picture. This mod draws a band above the prompt. The band
has a picture of each chip in the prompt, four rows high. Next to each picture
are the number, the size in pixels, and an **open** button. The button opens
the file in the default viewer.

The band goes away when the prompt has no chips. For example, it goes away
when you send the prompt.

## How it finds the image

Claude Code saves each pasted image in this folder:

```text
<temp>/<project>/<session ID>/images/<N>.png
```

`N` is the number of the chip. The mod looks for the folder of the session
in `CLAUDE_CODE_TMPDIR`, `/private/tmp`, and `/tmp`.

## Limits

- The mod cannot draw in the prompt box. A mod can only add styled text
  there, so the band is above the box.
- The terminal must draw kitty graphics. Claude Code draws images only in
  kitty and Ghostty. In Rex, set `CLAUDE_CODE_FORCE_TERMINAL_IMAGES=1`.
  `exports.zsh` sets it when `TERM_PROGRAM` is `rex`.
- The mod shows PNG files only. For other files, the band shows
  "no preview".
