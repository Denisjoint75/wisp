function render(s) {
  const dot = document.getElementById("dot");
  const state = document.getElementById("state");
  const detail = document.getElementById("detail");
  const help = document.getElementById("help");
  dot.className = "dot" + (s.state === "connected" ? " on" : s.state === "connecting" ? " mid" : "");
  if (s.state === "connected") {
    state.textContent = `Connected to wispd ${s.daemon || ""}`.trim();
    detail.textContent = `${s.attached || 0} tab${s.attached === 1 ? "" : "s"} attached · extension ${s.version}`;
    help.hidden = true;
  } else if (s.state === "connecting") {
    state.textContent = "Connecting to wispd…";
    detail.textContent = "";
    help.hidden = true;
  } else {
    state.textContent = "Not connected";
    detail.textContent = s.error || "";
    help.hidden = !(s.error && /not found|not installed|forbidden/i.test(s.error));
  }
}

function refresh() {
  chrome.runtime.sendMessage({ type: "status" }, (s) => {
    if (chrome.runtime.lastError || !s) {
      render({ state: "disconnected", error: (chrome.runtime.lastError && chrome.runtime.lastError.message) || "no status" });
      return;
    }
    render(s);
  });
}

document.getElementById("reconnect").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "reconnect" }, () => setTimeout(refresh, 600));
});
refresh();
setInterval(refresh, 1500);
