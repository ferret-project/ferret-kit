# FerretKit

The Swift package Ferret's Apple apps share: talking to a [Ferret](https://github.com/ferret-project/ferret) server's
REST API, signing in ("Sign in to Ferret": OAuth 2.1 with PKCE, or an API key), keeping the sign-in in the Keychain,
and the models the API sends back.

Foundation, Security and CryptoKit only, so it builds for iOS and macOS and `swift test` runs on a Mac.

```swift
.package(url: "https://github.com/ferret-project/ferret-kit", from: "0.1.0")
```

## What's in it

- `OAuth`: finds the server's sign-in, registers the app (once per server, as a public native client with its own
  redirect address), builds the browser address with PKCE, swaps the code for tokens and refreshes them. Opening the
  browser (`ASWebAuthenticationSession`) is the app's part.
- `FerretClient`: an actor that makes `/api/v1` calls as one signed-in person, refreshing the token once when several
  calls find it expired. Refresh tokens rotate and Ferret accepts a used one again for only a minute, so a refresh the
  network cut short is tried again at once, and with `reload` the client reads the kept sign-in before refreshing (an
  app, its share extension and widgets never use the same refresh token twice). Uploads stream from a file.
  `Inventory.swift` names the calls (`items`, `attention`, `ask`, `places`…).
- `SessionStore`, `AccessTokenStore`: the sign-in and Cloudflare Access service tokens, in the Keychain: the data
  protection keychain when the app may use it (on a Mac, a build signed with a team), else the older file-based one.
  Saving throws when the Keychain refuses.
- `ServerAddress`: turns what someone typed into a server address (`192.168.1.20:8787` → `http://…`).
- `OfflineStore`: things kept on the device for browsing without a connection.

Apps using it: [Ferret for Mac](https://github.com/ferret-project/ferret-menu) (menu bar).

## Tests

```bash
swift test
```

MIT licensed.
