import { initSync, decode_r24, decode_record } from "./pkg/openstrap_core.js";
import wasmBin from "./pkg/openstrap_core_bg.wasm";
let ready = false;
function ensure() { if (!ready) { initSync({ module: wasmBin }); ready = true; } }
export default {
  async fetch(req) {
    const url = new URL(req.url);
    const hex = url.searchParams.get("hex") || (req.method === "POST" ? await req.text() : "");
    try {
      ensure();
      if (url.pathname === "/r24") return new Response(decode_r24(hex), { headers: { "content-type": "application/json" } });
      if (url.pathname === "/record") return new Response(decode_record(hex), { headers: { "content-type": "application/json" } });
      return new Response("routes: /r24 /record ?hex=", { status: 404 });
    } catch (e) { return new Response(JSON.stringify({ error: String(e) }), { status: 500 }); }
  },
};
