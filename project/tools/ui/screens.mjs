// The screen catalog · project-owned: edit freely.
//
// Every screen the app has, and how to put it on screen in a representative state, for
// `bash tools/ui_capture.sh` (.app-director/procedures/ui-design.md). Add or update an entry whenever
// you add or change a screen. Capture opens the app on this machine only: tools/ui_capture.cfg ›
// [web] base_url, or `baseUrl` here.
//
// An entry: { id, title, route, states, auth, source, animate }
//   id      names the files (letters, digits, _ and -); title is for people
//   route   the path capture opens, such as "/orders"
//   states  optional: { default: <state>, empty: <state> }; without it the screen has one state, default
//   auth    optional: a test account's saved sign-in, tools/ui/.auth/<auth>.json (gitignored)
//   source  optional: the file that renders the screen, so --missing and align know it's covered
//   animate optional: true for a screen whose animations can't be stopped for the shot
//
// A state is an async function (page, api, screen). It seeds data through the app's public API with
// `api` (api.post("/api/test/orders", {...}), api.get, put, patch, delete: requests to this machine,
// in the screen's browser session), never real user data. It may open the screen itself with
// `await screen.open()` and then prepare it (open a dialog, fill a field); if it doesn't, capture
// opens the route after it returns.
//
// Example:
//   { id: "orders", title: "Orders", route: "/orders", source: "src/pages/OrdersPage.tsx",
//     states: {
//       default: async (page, api) => { await api.post("/api/test/seed", { data: { orders: 3 } }); },
//       empty: async (page, api) => { await api.post("/api/test/seed", { data: { orders: 0 } }); },
//     } },

export default {
  screens: [
    // Until the app lists its screens: the root route, as it opens.
    { id: "home", title: "Home", route: "/" },
  ],
};
