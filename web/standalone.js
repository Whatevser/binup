import { start } from "./app.js";

async function request(path, body, signal) {
  const options = {cache: "no-store", signal};
  if (body !== undefined) {
    options.method = "POST";
    options.headers = {"Content-Type": "application/json"};
    options.body = JSON.stringify(body);
  }
  const response = await fetch("/api/" + path, options);
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "Request failed (" + response.status + ")");
  return data;
}

start(request);
