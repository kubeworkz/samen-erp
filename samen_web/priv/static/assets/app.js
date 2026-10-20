// Samen client runtime — ADR-042 C2. Dependency-free LiveView transport shim + the
// global ⌘K focus listener. Loaded (deferred, in order) after phoenix.min.js (which
// defines the global `Phoenix`) and phoenix_live_view.min.js (global `LiveView`).
//
// Masking stays SERVER-RENDERED (ADR-042 §6 / C6): this file resolves NO value, holds
// NO token or key, and references NO vault field. It is a DOM patcher + a focus/nav
// affordance — nothing more. Every value the socket carries has already passed through
// Samen.Api.PiiResolution on the actor's plane server-side.
(function () {
  // (d) The seam future kit hooks register into — empty today.
  window.SamenHooks = window.SamenHooks || {};

  // (a) CSRF token from the meta the shared root layout emits.
  var meta = document.querySelector("meta[name='csrf-token']");
  var csrfToken = meta && meta.getAttribute("content");

  // (b) Construct the LiveSocket against the "/live" websocket every host endpoint
  //     declares, authenticating with the same CSRF token via connect params (C7).
  var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    hooks: window.SamenHooks,
    params: { _csrf_token: csrfToken }
  });

  // (c) Connect. Websocket transport only (matches the endpoints' declaration).
  liveSocket.connect();

  // (d) Expose for reconnect/debug from the console.
  window.liveSocket = liveSocket;

  // (e) The GLOBAL ⌘K (Ctrl+K) focus shortcut, relocated verbatim from the inline
  //     root-layout <script> (WS-E E6 / ADR-027). Focuses the ⌘K palette input when
  //     present, else the per-list search box, else submits its search form. Purely a
  //     focus/navigation affordance — it renders/reads no value, so it cannot touch
  //     masking.
  document.addEventListener("keydown", function (e) {
    if (!(e.metaKey || e.ctrlKey) || (e.key !== "k" && e.key !== "K")) return;
    var el = document.getElementById("cmdk-input") || document.querySelector("input[data-cmdk]");
    if (el) { e.preventDefault(); el.focus(); if (el.select) el.select(); return; }
    var form = document.querySelector("form.search[action]");
    if (form) { e.preventDefault(); form.submit(); }
  });
})();

  // (f) The `NoteBlock` hook (WS-Notes Phase 3; ADR-053 §4.1) — INTENT ONLY. It never reads a
  //     stored value, never touches `innerHTML`, and never resolves anything: the server has
  //     already plane-resolved every value it rendered. Structural changes are server events
  //     carrying a block id and (when the caret matters) its offset; the caret exists nowhere
  //     but in this element. The ONE DOM write is auto-grow, and only to its own `rows`.
  window.SamenHooks.NoteBlock = {
    mounted: function () {
      var hook = this;
      this.onKeyDown = function (e) { hook.keydown(e); };
      this.el.addEventListener("keydown", this.onKeyDown);
      this.grow();
    },
    updated: function () { this.grow(); },
    destroyed: function () {
      if (this.onKeyDown) this.el.removeEventListener("keydown", this.onKeyDown);
    },
    // The server's "focus this block after a split/merge/insert" request. Every block's hook
    // receives it; only the named one acts, and it only moves focus within its own element.
    handleEvent: function (event, payload) {
      if (event !== "focus_block" || !payload || String(payload.id) !== this.el.dataset.blockId) return;
      this.el.focus();
      var end = this.el.value.length;
      try { this.el.setSelectionRange(end, end); } catch (e) { /* not selectable: ignore */ }
    },
    keydown: function (e) {
      var el = this.el;
      var id = el.dataset.blockId;
      var type = el.dataset.type;
      var start = el.selectionStart;
      var end = el.selectionEnd;
      var isList = type === "bulleted_list_item" || type === "numbered_list_item" || type === "to_do";

      // Enter → split at the caret. Shift+Enter is a newline inside the block (the browser's).
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
        e.preventDefault();
        this.pushEvent("split_block", { id: id, offset: start });
        return;
      }
      // Backspace at offset 0 → merge into the previous sibling.
      if (e.key === "Backspace" && start === 0 && end === 0) {
        e.preventDefault();
        this.pushEvent("merge_block", { id: id });
        return;
      }
      // Tab / Shift+Tab → indent/outdent, LIST types only: everywhere else Tab must keep its
      // meaning (focus navigation), so the hook stays out of the way.
      if (e.key === "Tab") {
        if (!isList) return;
        e.preventDefault();
        this.pushEvent("indent_block", { id: id, direction: e.shiftKey ? "out" : "in" });
        return;
      }
      // Alt+↑ / Alt+↓ → move within the page.
      if (e.altKey && (e.key === "ArrowUp" || e.key === "ArrowDown")) {
        e.preventDefault();
        this.pushEvent("move_block", { id: id, direction: e.key === "ArrowUp" ? "up" : "down" });
        return;
      }
      // "/" in an empty block → the server-rendered type palette.
      if (e.key === "/" && start === 0 && end === 0 && el.value === "") {
        e.preventDefault();
        this.pushEvent("open_palette", { id: id });
      }
    },
    grow: function () {
      var el = this.el;
      el.rows = 1;
      var rows = Math.ceil(el.scrollHeight / 22);
      el.rows = Math.max(1, Math.min(rows, 24));
    }
  };
