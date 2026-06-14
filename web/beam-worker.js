// The wasm BEAM is single-threaded and built WITHOUT -pthread
// therefore the BEAM's scheduler loop runs on THIS worker's thread and blocks it, 
// so once the BEAM is running the worker can no longer process incoming postMessages.
//
// We therefore use ONE worker per typecheck. The source is written into MEMFS in
// preRun (before the BEAM starts, while the worker's event loop is still free),
// the BEAM boots and runs a single check, and its report is streamed back via
// print()->postMessage (sending out while the thread is blocked is fine). The
// main thread terminates this worker once the report is complete; the next check
// spawns a fresh worker.
"use strict";

let booted = false;

onmessage = function (e) {
  const msg = e.data;
  if (!msg || msg.type !== "check" || booted) return;
  booted = true; // a worker boots the BEAM exactly once, then is discarded

  const args = msg.args, env = msg.env, files = msg.files;

  self.Module = {
    arguments: args,
    preRun: [function () {
      const M = self.Module;
      Object.assign(M.ENV, env);
      try { M.FS.mkdir("/work"); } catch (_e) {}
      for (const name in files) M.FS.writeFile("/work/" + name, files[name]);
    }],
    // BEAM stdout/stderr -> main thread (frame parser lives there).
    print: function (line) { postMessage({ type: "line", line: line }); },
    printErr: function (line) { postMessage({ type: "line", line: line }); },
    onExit: function (code) { postMessage({ type: "exit", code: code }); },
    onAbort: function (what) { postMessage({ type: "abort", what: String(what) }); },
    // Resolve beam.wasm / beam.data. Served (multi-file) mode: they sit next to us,
    // so return the name as-is. Single-file mode: the page hands us same-origin Blob
    // URLs of the inlined binaries in msg.urls.
    locateFile: function (p) { return (msg.urls && msg.urls[p]) || p; }
  };

  // Boot the BEAM. beam.js auto-runs (callMain), entering the single scheduler
  // loop on this worker thread and blocking it; output streams out meanwhile.
  // Served mode: sibling 'beam.js'. Single-file mode: a same-origin Blob URL of
  // the inlined loader, passed by the page.
  importScripts(msg.beamJsUrl || "beam.js");
};
