// Cockpit serves this entry in its package frame. Requests run on the selected host.
import "../base1/cockpit.js";
import { start } from "./app.js";

const stylesheet = document.createElement("link");
stylesheet.rel = "stylesheet";
stylesheet.href = new URL("./cockpit.css", import.meta.url).href;
document.head.append(stylesheet);

const http = window.cockpit.http(9098, {address: "127.0.0.1"});

function request(path, body, signal, owner) {
  if (signal?.aborted) return Promise.reject(new DOMException("Aborted", "AbortError"));
  const route = "/api/" + path;
  const headers = owner ? {"X-Binup-Run":owner} : {};
  const channel = body === undefined ? http.get(route, undefined, headers) :
    http.post(route, JSON.stringify(body), {...headers, "Content-Type": "application/json"});
  const abort = () => channel.close("cancelled");
  signal?.addEventListener("abort", abort, {once: true});
  return new Promise((resolve, reject) => {
    channel.then(text => {
      try { resolve(JSON.parse(text)); } catch (error) { reject(error); }
    }, (error, text) => {
      let message = error.message;
      if (text) {
        try { message = JSON.parse(text).error || message; } catch { /* Non-JSON HTTP error. */ }
      }
      if (error.problem && !signal?.aborted) {
        message = "Could not reach Binup on this host. Check binup-web.service. " + (message || error.problem);
      }
      reject(new Error(message || "Cockpit request failed."));
    });
  }).finally(() => signal?.removeEventListener("abort", abort));
}

start(request, () => {
  const theme = window.localStorage.getItem("shell:style");
  return theme === "dark" || theme === "light" ? theme : "auto";
});
