/**
 * Generates the PWA icon set from the design tokens — a donburi bowl with chopsticks on
 * the AppAccent background. Run with `npm run icons`.
 *
 * pngjs is already present (transitively, via qrcode), so this needs no extra dependency.
 */

import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { PNG } from 'pngjs'

const here = dirname(fileURLToPath(import.meta.url))
const publicDir = resolve(here, '..', 'public')

const ACCENT = [0xf2, 0x6b, 0x4a] // --color-accent
const CREAM = [0xff, 0xfb, 0xf7]
const BOWL_SHADOW = [0xf3, 0xdc, 0xcf]

const SAMPLES = 3

function inCircle(x, y, cx, cy, r) {
  return (x - cx) ** 2 + (y - cy) ** 2 <= r * r
}

/** Rounded rect rotated by `angle` radians about its centre. */
function inRotatedBar(x, y, cx, cy, halfLength, halfThickness, angle) {
  const dx = x - cx
  const dy = y - cy
  const cos = Math.cos(-angle)
  const sin = Math.sin(-angle)
  const localX = dx * cos - dy * sin
  const localY = dx * sin + dy * cos
  if (Math.abs(localX) > halfLength || Math.abs(localY) > halfThickness) return false
  // Round the ends.
  const flat = halfLength - halfThickness
  if (Math.abs(localX) <= flat) return true
  const capX = Math.sign(localX) * flat
  return (localX - capX) ** 2 + localY ** 2 <= halfThickness * halfThickness
}

/**
 * @param {number} size
 * @param {number} markScale how much of the canvas the mark occupies (maskable needs slack)
 */
function drawIcon(size, markScale) {
  const png = new PNG({ width: size, height: size })
  const unit = size * markScale
  const cx = size / 2
  const cy = size / 2

  // Bowl geometry, in units of `unit`
  const bowlR = unit * 0.34
  const bowlCy = cy + unit * 0.06
  const rimHalfW = unit * 0.42
  const rimHalfH = unit * 0.055
  const rimCy = bowlCy - bowlR * 0.02

  const stickHalfLen = unit * 0.4
  const stickHalfThick = unit * 0.035
  const stickAngle = -0.62

  const colourAt = (x, y) => {
    // Chopsticks sit behind the bowl, angled from lower-left to upper-right.
    if (inRotatedBar(x, y, cx + unit * 0.06, cy - unit * 0.3, stickHalfLen, stickHalfThick, stickAngle)) {
      return CREAM
    }
    if (
      inRotatedBar(
        x,
        y,
        cx + unit * 0.06,
        cy - unit * 0.3 + unit * 0.115,
        stickHalfLen,
        stickHalfThick,
        stickAngle,
      )
    ) {
      return CREAM
    }
    // Bowl: lower half-disc plus a rim bar.
    if (inCircle(x, y, cx, bowlCy, bowlR) && y >= bowlCy) return CREAM
    if (Math.abs(x - cx) <= rimHalfW && Math.abs(y - rimCy) <= rimHalfH) {
      return inRotatedBar(x, y, cx, rimCy, rimHalfW, rimHalfH, 0) ? CREAM : null
    }
    // A soft shadow under the rim reads as the bowl's contents.
    if (inCircle(x, y, cx, bowlCy, bowlR * 0.62) && y >= bowlCy) return BOWL_SHADOW
    return null
  }

  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      let r = 0
      let g = 0
      let b = 0
      for (let sy = 0; sy < SAMPLES; sy += 1) {
        for (let sx = 0; sx < SAMPLES; sx += 1) {
          const px = x + (sx + 0.5) / SAMPLES
          const py = y + (sy + 0.5) / SAMPLES
          const colour = colourAt(px, py) ?? ACCENT
          r += colour[0]
          g += colour[1]
          b += colour[2]
        }
      }
      const total = SAMPLES * SAMPLES
      const index = (size * y + x) << 2
      png.data[index] = Math.round(r / total)
      png.data[index + 1] = Math.round(g / total)
      png.data[index + 2] = Math.round(b / total)
      png.data[index + 3] = 255
    }
  }

  return PNG.sync.write(png)
}

mkdirSync(publicDir, { recursive: true })

const targets = [
  ['icon-192.png', 192, 0.72],
  ['icon-512.png', 512, 0.72],
  // Maskable icons get cropped to a circle inscribed in the safe zone (80%).
  ['icon-maskable-512.png', 512, 0.52],
  ['apple-touch-icon.png', 180, 0.72],
]

for (const [name, size, markScale] of targets) {
  writeFileSync(resolve(publicDir, name), drawIcon(size, markScale))
  console.log(`wrote public/${name} (${size}x${size})`)
}

// Scalable favicon, same mark expressed as vector shapes.
const favicon = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="まとメシ">
  <rect width="64" height="64" rx="14" fill="#f26b4a"/>
  <g stroke="#fffbf7" stroke-linecap="round" stroke-width="3.2">
    <line x1="17" y1="26" x2="47" y2="12"/>
    <line x1="17" y1="33" x2="47" y2="19"/>
  </g>
  <path d="M14 34h36a18 18 0 0 1-36 0z" fill="#fffbf7"/>
  <rect x="12" y="30.5" width="40" height="4.6" rx="2.3" fill="#fffbf7"/>
</svg>
`
writeFileSync(resolve(publicDir, 'favicon.svg'), favicon)
console.log('wrote public/favicon.svg')
