// WS-Notes P0 spike — the CANDIDATE `NoteBlock` hook body (throwaway: it lives under test/support
// so it never enters the shipped asset bundle; ADR-042 C2's `window.SamenHooks` is where the real
// one will register in Phase 3).
//
// What it does, and deliberately does NOT do:
//   * pushes ONE intent per key: `Enter` → {block_id, caret offset}, `Backspace` at 0 → {block_id};
//   * focuses the block the SERVER nominates (the only server→client message);
//   * auto-grows its own element's height (the only DOM write);
//   * never reads a stored value, never writes text, never touches a sibling node.
(function () {
  window.SamenHooks = window.SamenHooks || {};

  window.SamenHooks.NoteBlock = {
    mounted() {
      const el = this.el;

      const grow = () => {
        el.style.height = "auto";
        el.style.height = el.scrollHeight + "px";
      };
      this.grow = grow;
      grow();

      this.onKey = (e) => {
        const id = el.dataset.blockId;

        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault();
          // NOTE: `selectionStart` is a UTF-16 code-unit offset, while the server's
          // `String.split_at/2` counts GRAPHEMES. Identical for ASCII; a mismatch for astral
          // characters / combining marks. This spike records it as an open contract question.
          this.pushEvent("split", { id: id, offset: el.selectionStart });
        } else if (e.key === "Backspace" && el.selectionStart === 0 && el.selectionEnd === 0) {
          e.preventDefault();
          this.pushEvent("merge", { id: id });
        }
      };

      el.addEventListener("keydown", this.onKey);
      el.addEventListener("input", grow);

      // The ONLY server → client message in the contract.
      this.handleEvent("focus_block", ({ id }) => {
        const target = document.getElementById("text-" + id);
        if (target) {
          target.focus();
          target.setSelectionRange(0, 0);
        }
      });
    },

    updated() {
      this.grow();
    },

    destroyed() {
      if (this.el && this.onKey) this.el.removeEventListener("keydown", this.onKey);
    }
  };

  const csrf = document.querySelector("meta[name='csrf-token']");
  const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    hooks: window.SamenHooks,
    params: csrf ? { _csrf_token: csrf.getAttribute("content") } : {}
  });

  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
