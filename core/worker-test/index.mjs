import { initSync, calc_strain, calc_resting_hr, time_domain_hrv } from "./pkg/openstrap_core.js";
import wasmBin from "./pkg/openstrap_core_bg.wasm";

let ready = false;
function ensure() {
  if (ready) return;
  console.log("wasmBin type:", typeof wasmBin, wasmBin instanceof WebAssembly.Module);
  initSync({ module: wasmBin });
  ready = true;
}

export default {
  async fetch(req) {
    const url = new URL(req.url);
    const body = req.method === "POST" ? await req.text() : "{}";
    try {
      ensure();
      let out;
      if (url.pathname === "/strain") out = calc_strain(body);
      else if (url.pathname === "/resting") out = calc_resting_hr(body);
      else if (url.pathname === "/hrv") out = time_domain_hrv(body);
      else return new Response("routes: /strain /resting /hrv", { status: 404 });
      return new Response(out, { headers: { "content-type": "application/json" } });
    } catch (e) {
      return new Response(JSON.stringify({ error: String(e), stack: e?.stack }), { status: 500 });
    }
  },
};
