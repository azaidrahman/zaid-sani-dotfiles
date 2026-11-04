// ==UserScript==
// @name        Scrobbler Refresh
// @namespace   chezmoi-userscripts
// @description Add a button to scrobbler.bocono-labs.com that sends your YouTube Music cookie.
// @version     1.0.1
// @match       https://scrobbler.bocono-labs.com/*
// @match       https://music.youtube.com/*
// @grant       GM_cookie
// @run-at      document-idle
// @noframes
// ==/UserScript==

// The scrobbler reads your YouTube Music history with a copy of your YouTube
// cookie. The copy stops working after some days. This script adds a button to
// the scrobbler site. The button reads the cookie that the browser sends to
// music.youtube.com. Then it posts the cookie to the endpoint that the
// "Setup YouTube Music" form uses.
//
// Setup (Violentmonkey 2.35.1 or later):
// 1. Open the dashboard of Violentmonkey, and go to the Settings tab. At the
//    top, turn on "Allow GM_cookie to access HTTP-only cookies".
// 2. Open this script in the editor. On the Settings tab of the editor, turn
//    on the same option. Then click Save. The editor does not keep the option
//    until you save.
//
// The Google sign-in cookies (HSID, SSID, __Secure-3PSID) are HttpOnly. If the
// two options are off, GM_cookie does not return them, and the scrobbler cannot
// use the cookie.
//
// Violentmonkey lets a script read the cookies of a site only if the script
// matches that site. Thus the script matches music.youtube.com, but it does
// nothing there.
//
// Do not log the cookie. It gives full access to your Google account.

(() => {
  if (location.hostname !== "scrobbler.bocono-labs.com") return;

  const YT_MUSIC = "https://music.youtube.com/";
  const LABEL = "Refresh YouTube cookie";

  const button = document.createElement("button");
  button.type = "button";
  button.textContent = LABEL;
  Object.assign(button.style, {
    position: "fixed",
    right: "16px",
    bottom: "16px",
    zIndex: "2147483647",
    padding: "10px 16px",
    border: "0",
    borderRadius: "8px",
    background: "#111827",
    color: "#f9fafb",
    font: "600 14px/1.2 system-ui, sans-serif",
    boxShadow: "0 4px 12px rgb(0 0 0 / 25%)",
    cursor: "pointer",
  });
  button.addEventListener("click", () => {
    refresh().catch((err) => {
      setState(LABEL, false);
      alert(`Scrobbler Refresh: ${err.message}`);
    });
  });
  document.body.append(button);

  async function refresh() {
    setState("Sending…", true);

    const cookies = await listCookies(YT_MUSIC);
    const names = new Set(cookies.map((c) => c.name));
    if (!names.has("__Secure-3PSID")) {
      throw new Error(
        names.has("SAPISID")
          ? 'Violentmonkey hid the HttpOnly cookies. Turn on "Allow GM_cookie to access HTTP-only cookies" in two places: (1) at the top of the Settings tab of the dashboard, and (2) on the Settings tab of the script editor, then click Save.'
          : "Sign in to YouTube Music in this browser, and then try again.",
      );
    }
    // GM_cookie.list returns the cookies in the order that the browser sends them.
    const cookie = cookies.map((c) => `${c.name}=${c.value}`).join("; ");

    const res = await fetch(`${location.origin}/api/youtube-headers`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ cookie }),
    });
    if (!res.ok) {
      throw new Error(`The scrobbler returned HTTP ${res.status}. Make sure that you are signed in to the scrobbler.`);
    }

    // The form of the site also reloads the page, to show the new connection state.
    setState("Sent ✓", true);
    setTimeout(() => location.reload(), 800);
  }

  function listCookies(url) {
    return new Promise((resolve, reject) => {
      GM_cookie.list({ url }, (cookies, err) => (err ? reject(new Error(err)) : resolve(cookies || [])));
    });
  }

  function setState(text, busy) {
    button.textContent = text;
    button.disabled = busy;
    button.style.opacity = busy ? "0.7" : "1";
  }
})();
