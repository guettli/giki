#!/usr/bin/env node
// Drives the browser in an exploratory session started by tool/explore.sh.
//
// Zero dependencies: Chrome's DevTools Protocol over the WebSocket that Node
// has built in. Each invocation connects to the browser the session already
// started, so state (the local database, the signed-in session, the page the
// agent is on) survives between commands -- which is what makes exploration
// possible one shell command at a time.
//
//   tool/explore.mjs open /                    navigate
//   tool/explore.mjs text                      the semantics tree, as text
//   tool/explore.mjs click "Sign in with a passkey"
//   tool/explore.mjs fill "Title" "Leitner"    type into a field by its label
//   tool/explore.mjs upload "Attach files" a.png   answer a file chooser
//   tool/explore.mjs key Enter                 a raw key
//   tool/explore.mjs tap 640 450               a raw click, when all else fails
//   tool/explore.mjs shot .explore/now.png     screenshot
//   tool/explore.mjs console                   console messages and page errors
//   tool/explore.mjs eval "location.href"      JavaScript in the page
//   tool/explore.mjs passkey                   attach a virtual authenticator
//   tool/explore.mjs api POST /api/v1/sync '{"device_id":"x","cursor":0}'
//   tool/explore.mjs sql "SELECT * FROM nodes" the SERVER's database
//
// Flutter renders into a canvas, so there is no DOM to click. `text`, `click`
// and `fill` work through Flutter's accessibility tree, which the engine
// exposes as real elements once semantics are enabled -- this turns it on
// automatically on first use. When a widget has no semantics, fall back to
// `shot` plus `tap`.

import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const statePath = join(root, '.explore', 'session.env')

function session() {
  let raw
  try {
    raw = readFileSync(statePath, 'utf8')
  } catch {
    fail('no session: run tool/explore.sh start')
  }
  const env = {}
  for (const line of raw.split('\n')) {
    const [key, ...rest] = line.split('=')
    if (key && rest.length) env[key.trim()] = rest.join('=').trim()
  }
  return env
}

function fail(message) {
  console.error(message)
  process.exit(1)
}

/** One CDP connection, closed when the command is done. */
class Browser {
  constructor(socket) {
    this.socket = socket
    this.nextId = 1
    this.pending = new Map()
    this.events = []
    socket.addEventListener('message', (event) => {
      const message = JSON.parse(event.data)
      if (message.id && this.pending.has(message.id)) {
        const { resolve, reject, timer } = this.pending.get(message.id)
        clearTimeout(timer)
        this.pending.delete(message.id)
        message.error ? reject(new Error(message.error.message)) : resolve(message.result)
      } else if (message.method) {
        this.events.push(message)
      }
    })
  }

  static async attach(cdpPort) {
    const targets = await (await fetch(`http://127.0.0.1:${cdpPort}/json/list`)).json()
    const page = targets.find((target) => target.type === 'page')
    if (!page) fail('chrome has no page open; restart the session')
    const socket = new WebSocket(page.webSocketDebuggerUrl)
    await new Promise((resolve, reject) => {
      socket.addEventListener('open', resolve, { once: true })
      socket.addEventListener('error', () => reject(new Error('cannot reach chrome')), { once: true })
    })
    return new Browser(socket)
  }

  send(method, params = {}) {
    const id = this.nextId++
    this.socket.send(JSON.stringify({ id, method, params }))
    return new Promise((resolve, reject) => {
      // The timer is kept so it can be cleared on the response. An uncleared
      // one keeps Node's event loop alive, which made every command sit for
      // the full timeout after it had already printed its answer.
      const timer = setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`${method} timed out`))
      }, 30000)
      this.pending.set(id, { resolve, reject, timer })
    })
  }

  /** Evaluates an expression in the page and returns its value. */
  async eval(expression) {
    const result = await this.send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
    })
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.exception?.description ?? 'evaluation failed')
    }
    return result.result.value
  }

  close() {
    this.socket.close()
  }
}

// --- the page side ----------------------------------------------------------
//
// Injected as source so it runs in the page, where Flutter's semantics live.

const PAGE_HELPERS = `
(() => {
  // Reinstalled on every command, deliberately: the page outlives individual
  // invocations, so a cached older copy of these helpers would silently keep
  // being used after this file changes.
  const api = {};

  // Flutter only builds its accessibility tree when something asks for it.
  // The engine ships a hidden button for exactly that.
  api.enableSemantics = () => {
    const placeholder = document.querySelector('flt-semantics-placeholder');
    if (placeholder) { placeholder.click(); return 'enabled'; }
    return document.querySelector('flt-semantics') ? 'already enabled' : 'no placeholder';
  };

  // Editable elements, in document order. Flutter does not always give a text
  // field an accessible name -- giki's Title and Body are two such -- so a
  // label is not always enough to reach one, and #0, #1 ... always is.
  api.fields = () =>
    [...document.querySelectorAll('flt-semantics input, flt-semantics textarea')]
      .map((input, index) => {
        const box = input.getBoundingClientRect();
        return {
          index,
          tag: input.tagName.toLowerCase(),
          // Flutter puts a field's accessible name on the editable element
          // rather than on its semantics node, so this is where to read it.
          label: input.getAttribute('aria-label') || '',
          // Flutter only fills the editable element while it has focus; the
          // text of every other field lives on the canvas and nowhere in the
          // DOM. Reporting "" for those would claim the field is empty.
          focused: document.activeElement === input,
          value: input.value,
          x: Math.round(box.x + box.width / 2),
          y: Math.round(box.y + box.height / 2),
        };
      });

  // Leaf nodes only: a container's textContent is every descendant's text
  // concatenated, which is noise in a listing and a trap for a matcher.
  api.nodes = () => {
    const out = [];
    for (const node of document.querySelectorAll('flt-semantics')) {
      if (node.querySelector('flt-semantics')) continue;
      const label = (node.getAttribute('aria-label') || node.textContent || '').trim();
      if (!label) continue;
      const box = node.getBoundingClientRect();
      if (box.width === 0 && box.height === 0) continue;
      out.push({
        label,
        role: node.getAttribute('role') || '',
        value: node.getAttribute('aria-value') || node.querySelector('input,textarea')?.value || '',
        x: Math.round(box.x + box.width / 2),
        y: Math.round(box.y + box.height / 2),
      });
    }
    return out;
  };

  const find = (needle) => {
    const wanted = needle.toLowerCase();
    const nodes = api.nodes();
    return nodes.find((n) => n.label.toLowerCase() === wanted)
        ?? nodes.find((n) => n.label.toLowerCase().includes(wanted));
  };
  api.find = find;

  // Click the semantics element itself rather than synthesising a pointer
  // event at its coordinates: Flutter installs a click listener on these nodes
  // for assistive technology, and that listener is what activates the widget.
  // Synthetic pointer events land on the semantics host and go nowhere.
  // The most specific match, not the first one. A semantics container's
  // textContent includes every descendant's text, so "first node whose text
  // contains the needle" is usually the root -- and clicking the root does
  // nothing at all, silently.
  const element = (needle) => {
    const wanted = needle.toLowerCase();
    const labelOf = (node) =>
      (node.getAttribute('aria-label') || node.textContent || '').trim().toLowerCase();
    const area = (node) => {
      const box = node.getBoundingClientRect();
      return box.width * box.height;
    };

    const candidates = [...document.querySelectorAll('flt-semantics')]
      .map((node) => ({ node, label: labelOf(node) }))
      .filter((entry) => entry.label.includes(wanted))
      // An exact label beats a container that merely contains the words.
      .map((entry) => ({ ...entry, exact: entry.label === wanted }))
      .sort((a, b) => (b.exact - a.exact) || (area(a.node) - area(b.node)));

    return candidates[0]?.node;
  };

  // Returns where to click. The caller then dispatches real pointer events
  // there, which is what Flutter's gesture recogniser expects: it only honours
  // clicks on semantics elements while it believes assistive technology is
  // driving, and that mode flips back as soon as any pointer event arrives.
  api.locate = (needle) => {
    // "#2" addresses the third editable element, for fields with no label.
    // Escaped twice on purpose: this source lives in a template literal, so
    // a single backslash would reach the page as a literal 'd'.
    if (/^#\\d+$/.test(needle)) {
      const field = api.fields()[Number(needle.slice(1))];
      if (!field) return { ok: false, reason: 'no field ' + needle };
      return { ok: true, label: needle + ' (' + field.tag + ')', x: field.x, y: field.y };
    }
    // A named text field: its label lives on the <input>, which the semantics
    // search below cannot see.
    const wanted = needle.toLowerCase();
    const field = api.fields().find((f) => f.label.toLowerCase() === wanted)
      ?? api.fields().find((f) => f.label.toLowerCase().includes(wanted));
    if (field && field.label) {
      return { ok: true, label: field.label, x: field.x, y: field.y };
    }

    const node = element(needle);
    if (!node) return { ok: false, reason: 'nothing labelled ' + JSON.stringify(needle) };
    const box = node.getBoundingClientRect();
    if (box.width === 0 && box.height === 0) {
      return { ok: false, reason: JSON.stringify(needle) + ' is not visible' };
    }
    return {
      ok: true,
      label: (node.getAttribute('aria-label') || node.textContent || '').trim().slice(0, 60),
      x: Math.round(box.x + box.width / 2),
      y: Math.round(box.y + box.height / 2),
    };
  };

  // Flutter gives a focused text field a real <input> (that is how it talks to
  // the IME), so typing means focusing the field and then driving that input.
  // Flutter gives the focused text field a real <input> -- that is how it
  // talks to the IME -- so typing means focusing the field, then driving it.
  api.editingElement = () => {
    const input = document.activeElement;
    return input && 'value' in input ? 'ready' : 'none';
  };

  api.setFieldValue = (value) => {
    const input = document.activeElement;
    if (!input || !('value' in input)) {
      return { ok: false, reason: 'no text field has focus' };
    }
    input.value = value;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    return { ok: true, value: input.value };
  };

  window.__gikiExplore = api;
})();
`

async function withPage(env, run) {
  const browser = await Browser.attach(env.GIKI_EXPLORE_CDP_PORT)
  try {
    await browser.send('Runtime.enable')
    await browser.send('Page.enable')
    await browser.send('Log.enable')
    return await run(browser)
  } finally {
    browser.close()
  }
}

async function ensureHelpers(browser) {
  await browser.eval(PAGE_HELPERS)
  const state = await browser.eval('window.__gikiExplore.enableSemantics()')
  if (state === 'enabled') {
    // The tree is built on the next frame.
    await new Promise((resolve) => setTimeout(resolve, 400))
  }
}

// Flutter listens for pointer events and checks `buttons`, so a bare
// mousePressed/mouseReleased pair is ignored. Hover first, then press with
// buttons set, then release with it cleared -- the sequence a real click makes.
async function clickAt(browser, x, y) {
  await browser.send('Input.dispatchMouseEvent', {
    type: 'mouseMoved', x, y, button: 'none', buttons: 0,
  })
  await browser.send('Input.dispatchMouseEvent', {
    type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1,
  })
  await browser.send('Input.dispatchMouseEvent', {
    type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1,
  })
}

async function typeText(browser, text) {
  for (const char of text) {
    await browser.send('Input.dispatchKeyEvent', { type: 'char', text: char })
  }
}

// --- commands ---------------------------------------------------------------

const commands = {
  async open(env, [path = '/']) {
    const url = path.startsWith('http') ? path : env.GIKI_EXPLORE_URL + path
    await withPage(env, async (browser) => {
      await browser.send('Page.navigate', { url })
      // Flutter boots, loads sqlite3.wasm and opens its database; waiting for
      // the load event alone shows a blank canvas.
      await new Promise((resolve) => setTimeout(resolve, 2500))
      await ensureHelpers(browser)
    })
    console.log(`opened ${url}`)
  },

  async text(env) {
    const { nodes, fields } = await withPage(env, async (browser) => {
      await ensureHelpers(browser)
      return {
        nodes: await browser.eval('window.__gikiExplore.nodes()'),
        fields: await browser.eval('window.__gikiExplore.fields()'),
      }
    })
    if (!nodes.length && !fields.length) {
      console.log('(no semantics; use `shot` and `tap`)')
      return
    }
    for (const node of nodes) {
      const role = node.role ? ` [${node.role}]` : ''
      const value = node.value ? ` = ${JSON.stringify(node.value)}` : ''
      console.log(`(${node.x},${node.y})${role} ${node.label}${value}`)
    }
    for (const field of fields) {
      const name = field.label ? ` ${field.label}` : ''
      const value = field.focused || field.value
        ? JSON.stringify(field.value)
        : '(not exposed until focused -- use `shot`)'
      console.log(`(${field.x},${field.y}) [field #${field.index} ${field.tag}]${name} = ${value}`)
    }
  },

  async click(env, [label]) {
    if (!label) fail('usage: explore.mjs click "<label>"')
    const result = await withPage(env, async (browser) => {
      await ensureHelpers(browser)
      const target = await browser.eval(
        `window.__gikiExplore.locate(${JSON.stringify(label)})`)
      if (!target.ok) return target
      await clickAt(browser, target.x, target.y)
      await new Promise((resolve) => setTimeout(resolve, 700))
      return target
    })
    if (!result.ok) fail(result.reason)
    console.log(`clicked ${result.label} at (${result.x},${result.y})`)
  },

  // Clicks a button that opens the browser's file chooser and answers the
  // chooser with local files, through CDP's file-chooser interception -- the
  // dialog itself is native and cannot be driven any other way.
  async upload(env, [label, ...files]) {
    if (!label || !files.length) fail('usage: explore.mjs upload "<label>" <file>...')
    const paths = files.map((file) => resolve(file))
    const result = await withPage(env, async (browser) => {
      await ensureHelpers(browser)
      const target = await browser.eval(
        `window.__gikiExplore.locate(${JSON.stringify(label)})`)
      if (!target.ok) return target
      await browser.send('Page.setInterceptFileChooserDialog', { enabled: true })
      try {
        await clickAt(browser, target.x, target.y)
        let opened
        for (let i = 0; i < 50 && !opened; i++) {
          await new Promise((done) => setTimeout(done, 100))
          opened = browser.events.find((event) => event.method === 'Page.fileChooserOpened')
        }
        if (!opened) return { ok: false, reason: `clicking ${label} opened no file chooser` }
        await browser.send('DOM.setFileInputFiles', {
          files: paths,
          backendNodeId: opened.params.backendNodeId,
        })
      } finally {
        await browser.send('Page.setInterceptFileChooserDialog', { enabled: false })
      }
      await new Promise((done) => setTimeout(done, 1000))
      return target
    })
    if (!result.ok) fail(result.reason)
    console.log(`uploaded ${paths.length} file(s) via ${result.label}`)
  },

  async fill(env, [label, ...rest]) {
    const value = rest.join(' ')
    if (!label) fail('usage: explore.mjs fill "<label>" "<text>"')
    const result = await withPage(env, async (browser) => {
      await ensureHelpers(browser)
      const target = await browser.eval(
        `window.__gikiExplore.locate(${JSON.stringify(label)})`)
      if (!target.ok) return target
      await clickAt(browser, target.x, target.y)
      await new Promise((resolve) => setTimeout(resolve, 500))

      const ready = await browser.eval('window.__gikiExplore.editingElement()')
      if (ready === 'ready') {
        await browser.eval(`window.__gikiExplore.setFieldValue(${JSON.stringify(value)})`)
      } else {
        // No editing element in focus: type for real, which is what a widget
        // without an IME hook needs anyway.
        await typeText(browser, value)
      }
      await new Promise((resolve) => setTimeout(resolve, 300))
      return target
    })
    if (!result.ok) fail(result.reason)
    console.log(`typed into ${result.label}`)
  },

  async key(env, [name]) {
    if (!name) fail('usage: explore.mjs key <Enter|Tab|Backspace|...>')
    const keys = {
      Enter: { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r' },
      Tab: { key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 },
      Backspace: { key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 },
      Escape: { key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 },
    }
    const descriptor = keys[name]
    if (!descriptor) fail(`unknown key ${name}; known: ${Object.keys(keys).join(', ')}`)
    await withPage(env, async (browser) => {
      await browser.send('Input.dispatchKeyEvent', { type: 'keyDown', ...descriptor })
      await browser.send('Input.dispatchKeyEvent', { type: 'keyUp', ...descriptor })
      await new Promise((resolve) => setTimeout(resolve, 400))
    })
    console.log(`pressed ${name}`)
  },

  async tap(env, [x, y]) {
    if (!x || !y) fail('usage: explore.mjs tap <x> <y>')
    await withPage(env, async (browser) => {
      await clickAt(browser, Number(x), Number(y))
      await new Promise((resolve) => setTimeout(resolve, 600))
    })
    console.log(`tapped (${x},${y})`)
  },

  async shot(env, [path = join(root, '.explore', 'screenshot.png')]) {
    const data = await withPage(env, (browser) =>
      browser.send('Page.captureScreenshot', { format: 'png' }))
    writeFileSync(path, Buffer.from(data.data, 'base64'))
    console.log(path)
  },

  async console(env) {
    // Collected from now on: a fresh connection cannot see what was logged
    // before it attached, so this watches for a moment and reports.
    const messages = await withPage(env, async (browser) => {
      await browser.send('Runtime.enable')
      await new Promise((resolve) => setTimeout(resolve, 1500))
      return browser.events
        .filter((event) =>
          event.method === 'Runtime.consoleAPICalled' ||
          event.method === 'Runtime.exceptionThrown' ||
          event.method === 'Log.entryAdded')
        .map((event) => {
          if (event.method === 'Runtime.exceptionThrown') {
            return `EXCEPTION ${event.params.exceptionDetails.exception?.description ?? ''}`
          }
          if (event.method === 'Log.entryAdded') {
            return `${event.params.entry.level.toUpperCase()} ${event.params.entry.text}`
          }
          const args = event.params.args.map((arg) => arg.value ?? arg.description ?? '').join(' ')
          return `${event.params.type.toUpperCase()} ${args}`
        })
    })
    console.log(messages.length ? messages.join('\n') : '(nothing in the last 1.5s)')
  },

  async eval(env, [expression]) {
    if (!expression) fail('usage: explore.mjs eval "<javascript>"')
    const value = await withPage(env, (browser) => browser.eval(expression))
    console.log(typeof value === 'string' ? value : JSON.stringify(value, null, 2))
  },

  // Runs a passkey ceremony: attaches a virtual authenticator, clicks the
  // button that starts the ceremony, and waits for it to finish -- all on one
  // connection, because Chrome removes virtual authenticators as soon as the
  // DevTools client disconnects. Attaching one in its own command would leave
  // the app waiting for a prompt nothing can answer.
  //
  // Credentials are saved to .explore/passkeys.json and restored on the next
  // run, so a passkey registered in one command can sign in with the next.
  async passkey(env, [label]) {
    if (!label) fail('usage: explore.mjs passkey "<button label>"')
    const store = join(root, '.explore', 'passkeys.json')
    let saved = []
    try {
      saved = JSON.parse(readFileSync(store, 'utf8'))
    } catch {
      // first ceremony of this session
    }

    const result = await withPage(env, async (browser) => {
      await browser.send('WebAuthn.enable', { enableUI: false })
      const { authenticatorId } = await browser.send('WebAuthn.addVirtualAuthenticator', {
        options: {
          protocol: 'ctap2',
          transport: 'internal',
          hasResidentKey: true,
          hasUserVerification: true,
          isUserVerified: true,
          automaticPresenceSimulation: true,
        },
      })
      for (const credential of saved) {
        await browser.send('WebAuthn.addCredential', { authenticatorId, credential })
      }

      await ensureHelpers(browser)
      const target = await browser.eval(
        `window.__gikiExplore.locate(${JSON.stringify(label)})`)
      if (!target.ok) return target
      await clickAt(browser, target.x, target.y)

      // The ceremony resolves in well under a second with an authenticator
      // that needs no human; the rest is the app talking to the server.
      await new Promise((resolve) => setTimeout(resolve, 4000))

      const { credentials } = await browser.send('WebAuthn.getCredentials', { authenticatorId })
      writeFileSync(store, JSON.stringify(credentials, null, 2))
      return { ...target, credentials: credentials.length }
    })
    if (!result.ok) fail(result.reason)
    console.log(`ran the ceremony behind ${result.label}; the authenticator now holds ${result.credentials} credential(s)`)
  },

  async api(env, [method = 'GET', path = '/healthz', body]) {
    const args = ['-sS', '-X', method, '-w', '\\n(HTTP %{http_code})\\n',
      '-H', `Authorization: Bearer ${env.GIKI_EXPLORE_TOKEN}`]
    if (body) args.push('-H', 'Content-Type: application/json', '-d', body)
    args.push(env.GIKI_EXPLORE_URL + path)
    console.log(execFileSync('curl', args, { encoding: 'utf8' }))
  },

  async sql(env, [query]) {
    if (!query) fail('usage: explore.mjs sql "<query>"')
    console.log(execFileSync('sqlite3', ['-header', '-box', env.GIKI_EXPLORE_DB, query],
      { encoding: 'utf8' }))
  },
}

const [command, ...args] = process.argv.slice(2)
if (!command || !commands[command]) {
  console.error(`usage: explore.mjs <${Object.keys(commands).join('|')}> [args]`)
  process.exit(2)
}
await commands[command](session(), args)
