/**
 * Minimal Chrome DevTools Protocol driver built on Node's global WebSocket, used to drive
 * the golden-path verification in a real browser without adding a Playwright dependency.
 *
 * Launch Chrome first:
 *   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
 *     --remote-debugging-port=9222 --user-data-dir=/tmp/chrome-verify --no-first-run \
 *     --disable-gpu --hide-scrollbars about:blank &
 *
 * Then: node scripts/cdp.mjs scripts/<scenario>.mjs
 */

const PORT = Number(process.env.CDP_PORT ?? 9222)

async function firstPage() {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      const list = await fetch(`http://127.0.0.1:${PORT}/json/list`).then((r) => r.json())
      const page = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl)
      if (page) return page
    } catch {
      // Chrome not listening yet.
    }
    await new Promise((r) => setTimeout(r, 250))
  }
  throw new Error(`no debuggable page on :${PORT}`)
}

export async function connect() {
  const page = await firstPage()
  const ws = new WebSocket(page.webSocketDebuggerUrl)
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true })
    ws.addEventListener('error', reject, { once: true })
  })

  let nextId = 1
  const pending = new Map()
  const events = []
  ws.addEventListener('message', (event) => {
    const message = JSON.parse(event.data)
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id)
      pending.delete(message.id)
      if (message.error) reject(new Error(JSON.stringify(message.error)))
      else resolve(message.result)
    } else if (message.method) {
      events.push(message)
    }
  })

  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = nextId++
      pending.set(id, { resolve, reject })
      ws.send(JSON.stringify({ id, method, params }))
    })

  await send('Runtime.enable')
  await send('Page.enable')
  await send('Log.enable')

  const evaluate = async (expression) => {
    const result = await send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
    })
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.exception?.description ?? 'evaluate failed')
    }
    return result.result.value
  }

  const wait = (ms) => new Promise((r) => setTimeout(r, ms))

  return {
    send,
    evaluate,
    wait,

    /** Emulate an iPhone-ish viewport. */
    viewport: (width = 390, height = 844) =>
      send('Emulation.setDeviceMetricsOverride', {
        width,
        height,
        deviceScaleFactor: 2,
        mobile: true,
      }),

    theme: (dark) =>
      send('Emulation.setEmulatedMedia', {
        features: [{ name: 'prefers-color-scheme', value: dark ? 'dark' : 'light' }],
      }),

    /**
     * Navigating to the URL already loaded does not reliably re-execute the document, and
     * this app keeps pushed screens mounted (NavigationStack semantics), so a stale hidden
     * screen would still answer querySelector. A unique param forces a real document load.
     */
    goto: async (url) => {
      const target = new URL(url)
      target.searchParams.set('_t', String(Date.now()))
      await send('Page.navigate', { url: target.toString() })
      await wait(2200)
    },

    /** Wipes mock-backend state so every run starts from the seed fixture. */
    resetState: async () => {
      await evaluate(`(() => { localStorage.clear(); location.reload(); return true })()`)
      await wait(2400)
    },

    text: (testId) =>
      evaluate(
        `document.querySelector('[data-testid="${testId}"]')?.textContent?.replace(/\\s+/g,' ').trim() ?? null`,
      ),

    exists: (testId) => evaluate(`!!document.querySelector('[data-testid="${testId}"]')`),

    /** Waits for an element to appear, rather than sleeping a guessed duration. */
    waitFor: async (testId, timeoutMs = 12000) => {
      const deadline = Date.now() + timeoutMs
      while (Date.now() < deadline) {
        if (await evaluate(`!!document.querySelector('[data-testid="${testId}"]')`)) return true
        await wait(200)
      }
      throw new Error(`timed out waiting for [data-testid="${testId}"]`)
    },

    click: async (testId) => {
      const ok = await evaluate(`(() => {
        const el = document.querySelector('[data-testid="${testId}"]')
        if (!el) return false
        el.click(); return true
      })()`)
      if (!ok) throw new Error(`cannot click missing [data-testid="${testId}"]`)
      await wait(650)
    },

    fill: async (testId, value) => {
      const ok = await evaluate(`(() => {
        const el = document.querySelector('[data-testid="${testId}"]')
        if (!el) return false
        const proto = el instanceof HTMLTextAreaElement
          ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, ${JSON.stringify(value)})
        el.dispatchEvent(new Event('input', { bubbles: true }))
        return true
      })()`)
      if (!ok) throw new Error(`cannot fill missing [data-testid="${testId}"]`)
      await wait(220)
    },

    select: async (testId, value) => {
      const ok = await evaluate(`(() => {
        const el = document.querySelector('[data-testid="${testId}"]')
        if (!el) return false
        Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value').set.call(el, ${JSON.stringify(value)})
        el.dispatchEvent(new Event('change', { bubbles: true }))
        return true
      })()`)
      if (!ok) throw new Error(`cannot select on missing [data-testid="${testId}"]`)
      await wait(220)
    },

    screenshot: async (path) => {
      const { data } = await send('Page.captureScreenshot', { format: 'png' })
      const { writeFileSync } = await import('node:fs')
      writeFileSync(path, Buffer.from(data, 'base64'))
    },

    consoleErrors: () =>
      events
        .filter(
          (e) =>
            (e.method === 'Runtime.consoleAPICalled' && e.params.type === 'error') ||
            e.method === 'Runtime.exceptionThrown' ||
            (e.method === 'Log.entryAdded' && e.params.entry.level === 'error'),
        )
        .map((e) =>
          e.method === 'Log.entryAdded'
            ? e.params.entry.text
            : e.method === 'Runtime.exceptionThrown'
              ? (e.params.exceptionDetails.exception?.description ?? e.params.exceptionDetails.text)
              : e.params.args.map((a) => a.description ?? JSON.stringify(a.value)).join(' '),
        ),

    close: () => ws.close(),
  }
}

if (process.argv[2]) {
  const scenario = await import(
    process.argv[2].startsWith('/') ? process.argv[2] : `${process.cwd()}/${process.argv[2]}`
  )
  const api = await connect()
  let failed = false
  try {
    await scenario.default(api)
  } catch (error) {
    failed = true
    console.error(`\nSCENARIO FAILED: ${error.message}`)
  } finally {
    api.close()
  }
  process.exit(failed ? 1 : 0)
}
