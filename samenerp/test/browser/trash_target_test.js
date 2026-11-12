#!/usr/bin/env node
// Browser-level proof for the close-dashboard -> Docs trash focus handoff.
//
// It boots an isolated test database + the real Samenerp endpoint through
// `test/support/browser_server.exs`, drives the installed Chrome over the DevTools protocol, follows
// the archived evidence's "open trash" link, asserts the targeted trash row's Restore button is
// the active element, and checks that its focus state is visually distinct from the blurred state.
// No npm dependency or Playwright download is needed: Node 24's global fetch + WebSocket talk to
// Chrome directly.
//
//   node samenerp/test/browser/trash_target_test.js
//
// Override CHROME_PATH when Chrome is not in a standard location. The server uses port 4013 and
// the isolated `samenerp_browser_test` database; do not run it alongside another browser fixture.

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

const APP_DIR = path.resolve(__dirname, "../..");
const PORT = 4013;
const ORG_ID = "0b000000-0000-4000-8000-00000000c105";
const BASE_URL = `http://localhost:${PORT}`;
const CLOSE_URL = `${BASE_URL}/close?org=${ORG_ID}`;
const ARTIFACT_DIR =
  process.env.BROWSER_ARTIFACT_DIR || path.join(os.tmpdir(), "samen-browser-artifacts");
const CHROME_LOG_PATH = path.join(os.tmpdir(), `samen-trash-chrome-${process.pid}.log`);
const DIFF_THRESHOLD = (() => {
  const parsed = Number.parseInt(process.env.BROWSER_DIFF_THRESHOLD || "24", 10);
  return Number.isFinite(parsed) ? Math.max(1, Math.min(255, parsed)) : 24;
})();
const DIFF_THRESHOLD_SOURCE =
  process.env.BROWSER_DIFF_THRESHOLD_SOURCE ||
  (process.env.BROWSER_DIFF_THRESHOLD ? "environment" : "default");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function ensureArtifactDir() {
  fs.mkdirSync(ARTIFACT_DIR, { recursive: true });
}

function closeLog(log) {
  return new Promise((resolve) => {
    if (!log || log.closed) return resolve();
    log.end(() => resolve());
  });
}

function copyIfExists(source, destination) {
  if (source && fs.existsSync(source)) {
    fs.copyFileSync(source, path.join(ARTIFACT_DIR, destination));
  }
}

function formatCdpEvent(message) {
  const params = message.params || {};

  if (message.method === "Runtime.consoleAPICalled") {
    const args = (params.args || []).map(
      (arg) => arg.value ?? arg.description ?? arg.type
    );
    return `[console.${params.type || "log"}] ${args.join(" ")}`;
  }

  if (message.method === "Runtime.exceptionThrown") {
    return `[exception] ${
      params.exceptionDetails?.exception?.description ||
      params.exceptionDetails?.text ||
      "unknown exception"
    }`;
  }

  if (message.method === "Log.entryAdded") {
    const entry = params.entry || {};
    return `[${entry.level || "log"}] ${entry.text || ""}${entry.url ? ` (${entry.url})` : ""}`;
  }

  return JSON.stringify(message);
}

async function composeSideBySideDiff(cdp, blurred, focused, threshold) {
  return evaluate(
    cdp,
    `(async () => {
      const load = (data) => new Promise((resolve, reject) => {
        const image = new Image();
        image.onload = () => resolve(image);
        image.onerror = () => reject(new Error("snapshot decode failed"));
        image.src = "data:image/png;base64," + data;
      });

      const [left, right] = await Promise.all([
        load(${JSON.stringify(blurred)}),
        load(${JSON.stringify(focused)})
      ]);
      const panelWidth = Math.max(left.width, right.width);
      const panelHeight = Math.max(left.height, right.height);
      const gap = 16;
      const labelHeight = 32;

      const leftCanvas = document.createElement("canvas");
      leftCanvas.width = panelWidth;
      leftCanvas.height = panelHeight;
      leftCanvas.getContext("2d").drawImage(left, 0, 0);

      const rightCanvas = document.createElement("canvas");
      rightCanvas.width = panelWidth;
      rightCanvas.height = panelHeight;
      rightCanvas.getContext("2d").drawImage(right, 0, 0);

      const leftPixels = leftCanvas.getContext("2d").getImageData(0, 0, panelWidth, panelHeight).data;
      const rightPixels = rightCanvas.getContext("2d").getImageData(0, 0, panelWidth, panelHeight).data;
      const diffCanvas = document.createElement("canvas");
      diffCanvas.width = panelWidth;
      diffCanvas.height = panelHeight;
      const diffContext = diffCanvas.getContext("2d");
      const diffPixels = diffContext.createImageData(panelWidth, panelHeight);
      const threshold = ${JSON.stringify(threshold)};
      let sensitivePixels = 0;
      let tolerantPixels = 0;
      let sensitiveMinX = panelWidth;
      let sensitiveMinY = panelHeight;
      let sensitiveMaxX = -1;
      let sensitiveMaxY = -1;
      let tolerantMinX = panelWidth;
      let tolerantMinY = panelHeight;
      let tolerantMaxX = -1;
      let tolerantMaxY = -1;

      for (let y = 0; y < panelHeight; y += 1) {
        for (let x = 0; x < panelWidth; x += 1) {
          const i = (y * panelWidth + x) * 4;
          const delta = Math.max(
            Math.abs(leftPixels[i] - rightPixels[i]),
            Math.abs(leftPixels[i + 1] - rightPixels[i + 1]),
            Math.abs(leftPixels[i + 2] - rightPixels[i + 2])
          );

          if (delta === 0) {
            diffPixels.data[i] = 15;
            diffPixels.data[i + 1] = 23;
            diffPixels.data[i + 2] = 42;
          } else if (delta < threshold) {
            diffPixels.data[i] = 51;
            diffPixels.data[i + 1] = 65;
            diffPixels.data[i + 2] = 85;
          } else {
            const intensity = Math.min(1, (delta - threshold) / Math.max(1, 255 - threshold));
            diffPixels.data[i] = 255;
            diffPixels.data[i + 1] = Math.round(230 - 170 * intensity);
            diffPixels.data[i + 2] = Math.round(138 - 110 * intensity);
          }

          if (delta > 0) {
            sensitivePixels += 1;
            sensitiveMinX = Math.min(sensitiveMinX, x);
            sensitiveMinY = Math.min(sensitiveMinY, y);
            sensitiveMaxX = Math.max(sensitiveMaxX, x);
            sensitiveMaxY = Math.max(sensitiveMaxY, y);
          }

          if (delta >= threshold) {
            tolerantPixels += 1;
            tolerantMinX = Math.min(tolerantMinX, x);
            tolerantMinY = Math.min(tolerantMinY, y);
            tolerantMaxX = Math.max(tolerantMaxX, x);
            tolerantMaxY = Math.max(tolerantMaxY, y);
          }

          diffPixels.data[i + 3] = 255;
        }
      }

      diffContext.putImageData(diffPixels, 0, 0);

      const canvas = document.createElement("canvas");
      canvas.width = panelWidth * 3 + gap * 2;
      canvas.height = panelHeight + labelHeight;

      const context = canvas.getContext("2d");
      context.fillStyle = "#FFFFFF";
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.fillStyle = "#191A20";
      context.font = "600 16px sans-serif";
      context.textBaseline = "middle";
      context.fillText("Blurred", 12, labelHeight / 2);
      context.fillText("Focused", panelWidth + gap + 12, labelHeight / 2);
      context.fillText("Difference", (panelWidth + gap) * 2 + 12, labelHeight / 2);
      context.drawImage(leftCanvas, 0, labelHeight);
      context.drawImage(rightCanvas, panelWidth + gap, labelHeight);
      context.drawImage(diffCanvas, (panelWidth + gap) * 2, labelHeight);
      context.fillStyle = "#EBEBEF";
      context.fillRect(panelWidth, 0, gap, canvas.height);
      context.fillRect(panelWidth * 2 + gap, 0, gap, canvas.height);

      return {
        data: canvas.toDataURL("image/png").split(",")[1],
        threshold,
        sensitive: {
          pixels: sensitivePixels,
          boundingBox:
            sensitiveMaxX >= 0
              ? {
                  x: sensitiveMinX,
                  y: sensitiveMinY,
                  width: sensitiveMaxX - sensitiveMinX + 1,
                  height: sensitiveMaxY - sensitiveMinY + 1
                }
              : null
        },
        tolerant: {
          pixels: tolerantPixels,
          boundingBox:
            tolerantMaxX >= 0
              ? {
                  x: tolerantMinX,
                  y: tolerantMinY,
                  width: tolerantMaxX - tolerantMinX + 1,
                  height: tolerantMaxY - tolerantMinY + 1
                }
              : null
        }
      };
    })()`
  );
}

async function captureFailureArtifacts(error, cdp, snapshots = {}) {
  try {
    ensureArtifactDir();
    const lines = ["Browser test failed", "", error.stack || error.message, ""];

    if (snapshots.blurred) {
      fs.writeFileSync(
        path.join(ARTIFACT_DIR, "trash-restore-blurred.png"),
        Buffer.from(snapshots.blurred, "base64")
      );
      lines.push(`blurred snapshot sha256: ${snapshotHash(snapshots.blurred)}`);
    }

    if (snapshots.focused) {
      fs.writeFileSync(
        path.join(ARTIFACT_DIR, "trash-restore-focused.png"),
        Buffer.from(snapshots.focused, "base64")
      );
      lines.push(`focused snapshot sha256: ${snapshotHash(snapshots.focused)}`);
    }

    if (snapshots.blurred && snapshots.focused && cdp) {
      try {
        const diff = await composeSideBySideDiff(
          cdp,
          snapshots.blurred,
          snapshots.focused,
          DIFF_THRESHOLD
        );
        fs.writeFileSync(
          path.join(ARTIFACT_DIR, "trash-restore-diff.png"),
          Buffer.from(diff.data, "base64")
        );
        lines.push("side-by-side diff: trash-restore-diff.png");
        lines.push(`diff threshold (max RGB delta): ${diff.threshold}`);
        lines.push(`sensitive changed pixels (>0): ${diff.sensitive.pixels}`);
        lines.push(
          `tolerant changed pixels (>=${diff.threshold}): ${diff.tolerant.pixels}`
        );
        lines.push(
          `sensitive bounding box (row crop): ${formatBoundingBox(diff.sensitive.boundingBox)}`
        );
        lines.push(
          `tolerant bounding box (row crop): ${formatBoundingBox(diff.tolerant.boundingBox)}`
        );
      } catch (diffError) {
        lines.push(`side-by-side diff unavailable: ${diffError.message}`);
      }
    }

    if (snapshots.blurred || snapshots.focused) lines.push("");

    if (cdp) {
      try {
        lines.push(`page state: ${JSON.stringify(await browserState(cdp))}`);
      } catch (stateError) {
        lines.push(`page state unavailable: ${stateError.message}`);
      }

      const events = cdp.events.length
        ? cdp.events.map(formatCdpEvent)
        : ["(no browser console or runtime events captured)"];
      fs.writeFileSync(
        path.join(ARTIFACT_DIR, "browser-console.log"),
        `${events.join("\n")}\n`
      );

      try {
        const screenshot = await cdp.send("Page.captureScreenshot", {
          format: "png",
          captureBeyondViewport: true
        });
        fs.writeFileSync(
          path.join(ARTIFACT_DIR, "failure.png"),
          Buffer.from(screenshot.data, "base64")
        );
      } catch (screenshotError) {
        lines.push(`screenshot failed: ${screenshotError.message}`);
      }

      try {
        const html = await evaluate(cdp, "document.documentElement.outerHTML");
        fs.writeFileSync(path.join(ARTIFACT_DIR, "page.html"), html || "");
      } catch (htmlError) {
        lines.push(`page HTML unavailable: ${htmlError.message}`);
      }
    } else {
      fs.writeFileSync(
        path.join(ARTIFACT_DIR, "browser-console.log"),
        "CDP was not connected; no browser console or screenshot was captured.\n"
      );
      lines.push("CDP was not connected; no screenshot was captured.");
    }

    fs.writeFileSync(path.join(ARTIFACT_DIR, "failure.txt"), `${lines.join("\n")}\n`);
  } catch (artifactError) {
    console.error(
      `warning: could not capture browser failure artifacts: ${
        artifactError.stack || artifactError.message
      }`
    );
  }
}

function copyFailureLogs(server, chrome) {
  try {
    ensureArtifactDir();
    if (server) copyIfExists(server.logPath, "server.log");
    copyIfExists(chrome?.logPath || CHROME_LOG_PATH, "chrome-stderr.log");
  } catch (artifactError) {
    console.error(
      `warning: could not copy failure logs: ${artifactError.stack || artifactError.message}`
    );
  }
}

async function waitFor(label, fn, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  let last;

  while (Date.now() < deadline) {
    try {
      last = await fn();
      if (last) return last;
    } catch (error) {
      last = error;
    }

    await sleep(200);
  }

  throw new Error(`${label} timed out${last ? `: ${String(last)}` : ""}`);
}

function chromePath() {
  const candidates = [
    process.env.CHROME_PATH,
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  ].filter(Boolean);

  const found = candidates.find((candidate) => fs.existsSync(candidate));
  if (!found) {
    throw new Error("Chrome was not found; set CHROME_PATH to a Chrome/Chromium executable.");
  }

  return found;
}

function killTree(child) {
  if (!child || child.exitCode !== null) return;

  if (process.platform === "win32") {
    spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
  } else {
    try {
      process.kill(-child.pid, "SIGTERM");
    } catch (_) {
      child.kill("SIGTERM");
    }
  }
}

function startServer() {
  const logPath = path.join(os.tmpdir(), `samen-trash-browser-${process.pid}.log`);
  const log = fs.createWriteStream(logPath);
  log.on("error", () => {});
  const command = process.platform === "win32" ? process.env.ComSpec || "cmd.exe" : "mix";
  const args =
    process.platform === "win32"
      ? ["/d", "/s", "/c", "mix", "run", "--no-halt", "test/support/browser_server.exs"]
      : ["run", "--no-halt", "test/support/browser_server.exs"];

  const child = spawn(command, args, {
    cwd: APP_DIR,
    env: {
      ...process.env,
      MIX_ENV: "test",
      SAMEN_TEST_DB: "samenerp_browser_test",
      PORT: String(PORT)
    },
    detached: process.platform !== "win32",
    stdio: ["ignore", "pipe", "pipe"]
  });

  child.stdout.pipe(log);
  child.stderr.pipe(log);

  return { child, log, logPath };
}

async function waitForServer(server) {
  try {
    await waitFor(
      "browser fixture",
      async () => {
        if (server.child.exitCode !== null) {
          throw new Error(`server exited with ${server.child.exitCode}`);
        }

        const response = await fetch(CLOSE_URL);
        return response.ok;
      },
      120_000
    );
  } catch (error) {
    const log = fs.existsSync(server.logPath) ? fs.readFileSync(server.logPath, "utf8") : "";
    throw new Error(`${error.message}\n--- browser server log ---\n${log.slice(-6000)}`);
  }
}

async function launchChrome() {
  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), "samen-trash-chrome-"));
  const log = fs.createWriteStream(CHROME_LOG_PATH);
  log.on("error", () => {});
  const child = spawn(
    chromePath(),
    [
      "--headless=new",
      "--disable-gpu",
      "--disable-dev-shm-usage",
      "--no-first-run",
      "--no-default-browser-check",
      "--remote-debugging-port=0",
      `--user-data-dir=${userDataDir}`,
      "about:blank"
    ],
    { detached: process.platform !== "win32", stdio: ["ignore", "ignore", "pipe"] }
  );

  child.stderr.pipe(log);
  const activePortFile = path.join(userDataDir, "DevToolsActivePort");

  try {
    await waitFor("Chrome DevToolsActivePort", () => fs.existsSync(activePortFile), 20_000);

    const [devtoolsPort] = fs.readFileSync(activePortFile, "utf8").split("\n");
    const targets = await fetch(`http://127.0.0.1:${devtoolsPort}/json/list`).then((r) => r.json());
    const target = targets.find((entry) => entry.type === "page");
    if (!target) throw new Error("Chrome exposed no page target");

    return {
      child,
      userDataDir,
      wsUrl: target.webSocketDebuggerUrl,
      log,
      logPath: CHROME_LOG_PATH
    };
  } catch (error) {
    killTree(child);
    await sleep(300);
    await closeLog(log);
    try {
      fs.rmSync(userDataDir, { recursive: true, force: true });
    } catch (_) {
      // Chrome can still hold a profile handle on Windows; the temp directory is disposable.
    }
    throw error;
  }
}

function connectCdp(wsUrl) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(wsUrl);
    let nextId = 1;
    const pending = new Map();
    const events = [];

    const fail = (error) => {
      for (const request of pending.values()) request.rej(error);
      pending.clear();
      reject(error);
    };

    const openTimer = setTimeout(() => fail(new Error("CDP connection timed out")), 10_000);

    socket.addEventListener("open", () => {
      clearTimeout(openTimer);

      resolve({
        send(method, params = {}) {
          return new Promise((res, rej) => {
            const id = nextId++;
            const timer = setTimeout(() => {
              pending.delete(id);
              rej(new Error(`CDP ${method} timed out`));
            }, 15_000);

            pending.set(id, {
              res: (value) => {
                clearTimeout(timer);
                res(value);
              },
              rej: (error) => {
                clearTimeout(timer);
                rej(error);
              }
            });

            socket.send(JSON.stringify({ id, method, params }));
          });
        },
        close() {
          socket.close();
        },
        events
      });
    });

    socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (!message.id) {
        if (
          message.method === "Runtime.consoleAPICalled" ||
          message.method === "Runtime.exceptionThrown" ||
          message.method === "Log.entryAdded"
        ) {
          events.push(message);
        }
        return;
      }

      const request = pending.get(message.id);
      if (!request) return;

      pending.delete(message.id);
      if (message.error) request.rej(new Error(JSON.stringify(message.error)));
      else request.res(message.result);
    });

    socket.addEventListener("error", fail);
    socket.addEventListener("close", () => fail(new Error("CDP connection closed")));
  });
}

async function evaluate(cdp, expression) {
  const result = await cdp.send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true
  });

  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.text || "browser evaluation failed");
  }

  return result.result.value;
}

async function browserState(cdp) {
  return evaluate(
    cdp,
    `(() => ({
      href: location.href,
      readyState: document.readyState,
      connected: !!(window.liveSocket && window.liveSocket.isConnected()),
      activeId: document.activeElement && document.activeElement.id,
      activeTag: document.activeElement && document.activeElement.tagName,
      targetId: document.querySelector(":target") && document.querySelector(":target").id
    }))()`
  );
}

async function nextFrame(cdp) {
  await evaluate(
    cdp,
    "new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))"
  );
}

async function targetRowClip(cdp, docId) {
  const rowId = `note-trash-item-${docId}`;
  return evaluate(
    cdp,
    `(() => {
      const row = document.getElementById(${JSON.stringify(rowId)});
      const rect = row.getBoundingClientRect();
      const padding = 12;
      const left = Math.max(0, rect.left - padding);
      const top = Math.max(0, rect.top - padding);
      const right = Math.min(window.innerWidth, rect.right + padding);
      const bottom = Math.min(window.innerHeight, rect.bottom + padding);
      return { x: left, y: top, width: right - left, height: bottom - top };
    })()`
  );
}

async function cropScreenshot(cdp, screenshot, clip) {
  return evaluate(
    cdp,
    `(async () => {
      const image = new Image();
      image.src = "data:image/png;base64," + ${JSON.stringify(screenshot)};
      await image.decode();

      const clip = ${JSON.stringify(clip)};
      const scaleX = image.width / window.innerWidth;
      const scaleY = image.height / window.innerHeight;
      const sourceX = Math.max(0, Math.round(clip.x * scaleX));
      const sourceY = Math.max(0, Math.round(clip.y * scaleY));
      const width = Math.max(1, Math.min(image.width - sourceX, Math.round(clip.width * scaleX)));
      const height = Math.max(1, Math.min(image.height - sourceY, Math.round(clip.height * scaleY)));

      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = height;
      canvas.getContext("2d").drawImage(image, sourceX, sourceY, width, height, 0, 0, width, height);
      return canvas.toDataURL("image/png").split(",")[1];
    })()`
  );
}

async function captureSnapshot(cdp, clip) {
  const screenshot = await cdp.send("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: false
  });
  return clip ? cropScreenshot(cdp, screenshot.data, clip) : screenshot.data;
}

async function scrollTargetIntoView(cdp, docId) {
  const rowId = `note-trash-item-${docId}`;
  await evaluate(
    cdp,
    `document.getElementById(${JSON.stringify(
      rowId
    )}).scrollIntoView({ block: "center", inline: "nearest" }); true`
  );
  await nextFrame(cdp);
}

async function scrollPosition(cdp) {
  return evaluate(
    cdp,
    `(() => {
      const main = document.querySelector(".main");
      return {
        windowX: window.scrollX,
        windowY: window.scrollY,
        mainTop: main ? main.scrollTop : null
      };
    })()`
  );
}

function snapshotHash(base64) {
  return crypto.createHash("sha256").update(base64).digest("hex");
}

function formatBoundingBox(box) {
  return box
    ? `x=${box.x}, y=${box.y}, width=${box.width}, height=${box.height}`
    : "none";
}

async function assertRestoreFocusIsVisuallyDistinct(cdp, docId, snapshots = {}) {
  const restoreId = `note-trash-restore-${docId}`;

  await evaluate(cdp, "document.fonts ? document.fonts.ready.then(() => true) : true");

  // The page must be static enough for a snapshot comparison. Two blurred captures
  // prove that before the focus change is measured.
  await evaluate(cdp, "document.activeElement && document.activeElement.blur(); true");
  await scrollTargetIntoView(cdp, docId);
  const blurredScroll = await scrollPosition(cdp);
  const blurredClip = await targetRowClip(cdp, docId);
  const blurred = await captureSnapshot(cdp, blurredClip);
  snapshots.blurred = blurred;
  await nextFrame(cdp);
  const blurredAgain = await captureSnapshot(cdp, blurredClip);

  assert.ok(
    blurred === blurredAgain,
    "the trash page changed between snapshots while Restore was blurred"
  );

  // Make Chrome treat the next programmatic focus as keyboard-driven, so :focus-visible
  // and the browser's default focus ring are part of the visual snapshot.
  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyDown",
    key: "Tab",
    code: "Tab",
    windowsVirtualKeyCode: 9,
    nativeVirtualKeyCode: 9
  });
  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyUp",
    key: "Tab",
    code: "Tab",
    windowsVirtualKeyCode: 9,
    nativeVirtualKeyCode: 9
  });
  await evaluate(
    cdp,
    `document.getElementById(${JSON.stringify(restoreId)}).focus({ preventScroll: true }); true`
  );
  await scrollTargetIntoView(cdp, docId);
  const focusedScroll = await scrollPosition(cdp);
  const focusedClip = await targetRowClip(cdp, docId);
  assert.deepEqual(
    focusedClip,
    blurredClip,
    "the targeted trash row moved while Restore was focused"
  );
  const focused = await captureSnapshot(cdp, focusedClip);
  snapshots.focused = focused;
  await nextFrame(cdp);
  const focusedAgain = await captureSnapshot(cdp, focusedClip);

  assert.ok(
    focused === focusedAgain,
    "the trash page changed between snapshots while Restore was focused"
  );
  assert.deepEqual(
    focusedScroll,
    blurredScroll,
    "focusing the targeted Restore control moved the page between snapshots"
  );
  assert.ok(
    focused !== blurred,
    "focusing the targeted Restore control did not change its rendered focus state"
  );

  const state = await browserState(cdp);
  assert.equal(state.activeId, restoreId);
  assert.equal(state.activeTag, "BUTTON");

  return { blurredHash: snapshotHash(blurred), focusedHash: snapshotHash(focused) };
}

async function run() {
  console.error(`browser diff threshold: ${DIFF_THRESHOLD} (source: ${DIFF_THRESHOLD_SOURCE})`);

  const server = startServer();
  const visualSnapshots = {};
  let chrome;
  let cdp;
  let failure;

  try {
    console.error("browser fixture: starting");
    await waitForServer(server);
    console.error("browser fixture: ready");
    chrome = await launchChrome();
    console.error("chrome: launched");
    cdp = await connectCdp(chrome.wsUrl);
    console.error("chrome: cdp connected");
    await cdp.send("Page.enable");
    await cdp.send("Runtime.enable");
    await cdp.send("Log.enable");

    await cdp.send("Page.navigate", { url: CLOSE_URL });
    await waitFor(
      "close dashboard",
      async () => (await evaluate(cdp, "document.readyState")) === "complete",
      30_000
    );
    console.error("close dashboard: loaded");

    const linkHref = await waitFor(
      "archived evidence trash link",
      () =>
        evaluate(
          cdp,
          `(() => {
            const link = [...document.querySelectorAll("a")].find((a) =>
              a.textContent.includes("open trash")
            );
            return link && link.href;
          })()`
        ),
      30_000
    );

    assert.match(linkHref, /\/pages\/trash\?org=[^#]+#note-trash-item-[^#]+$/);

    const docId = new URL(linkHref).hash.replace("#note-trash-item-", "");
    assert.ok(docId, "the evidence link must name the trash row");

    await evaluate(
      cdp,
      `(() => {
        const link = [...document.querySelectorAll("a")].find((a) =>
          a.textContent.includes("open trash")
        );
        if (!link) throw new Error("archived evidence trash link disappeared");
        link.click();
        return link.href;
      })()`
    );

    await waitFor(
      "trash page",
      async () => (await evaluate(cdp, "location.pathname")) === "/pages/trash",
      30_000
    );
    console.error("trash page: loaded");

    const state = await waitFor(
      "Restore focus",
      async () => {
        const current = await browserState(cdp);
        return current.connected &&
          current.activeId === `note-trash-restore-${docId}` &&
          current.activeTag === "BUTTON"
          ? current
          : false;
      },
      30_000
    );

    assert.equal(state.targetId, `note-trash-item-${docId}`);
    assert.equal(state.activeId, `note-trash-restore-${docId}`);
    assert.equal(state.activeTag, "BUTTON");

    const snapshots = await assertRestoreFocusIsVisuallyDistinct(cdp, docId, visualSnapshots);
    console.error(
      `visual snapshot: focused Restore differs from blurred state ` +
        `(${snapshots.blurredHash.slice(0, 12)} -> ${snapshots.focusedHash.slice(0, 12)})`
    );

    console.log(`ok - ${state.activeId} focused with a visible focus state`);
  } catch (error) {
    failure = error;
    throw error;
  } finally {
    if (failure) await captureFailureArtifacts(failure, cdp, visualSnapshots);

    if (cdp) cdp.close();

    if (chrome) {
      killTree(chrome.child);
      await sleep(300);
      try {
        fs.rmSync(chrome.userDataDir, { recursive: true, force: true });
      } catch (_) {
        // Chrome can still hold a profile handle on Windows; the temp directory is disposable.
      }
      await closeLog(chrome.log);
    }

    killTree(server.child);
    await sleep(300);
    await closeLog(server.log);

    if (failure) copyFailureLogs(server, chrome);
  }
}

run().catch((error) => {
  console.error(error.stack || error.message);
  if (fs.existsSync(ARTIFACT_DIR)) console.error(`failure artifacts: ${ARTIFACT_DIR}`);
  process.exitCode = 1;
});
