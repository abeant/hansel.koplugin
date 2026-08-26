# Hansel

[![KOReader 2024.12+](https://img.shields.io/badge/KOReader-2024.12%2B-222)](https://koreader.rocks/)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)
[![Lua](https://img.shields.io/badge/Lua-5.1-blue)](https://www.lua.org/)
[![Grimmory](https://img.shields.io/badge/Grimmory-library-555)](https://grimmory.org)

KOReader starts in your Grimmory library.

You have a device with space. You would rather not live in the vendor reader. Install [KOReader](https://koreader.rocks/), sign Hansel into [Grimmory](https://grimmory.org), tap a cover. Downloads stay on the device. You do not keep a second file tree.

<!-- screenshots: drop portrait E-Ink PNGs in docs/screens/ then uncomment
| Cover grid | Library drawer | Book detail |
| :---: | :---: | :---: |
| <img src="docs/screens/home.png" width="240" alt="Cover grid"> | <img src="docs/screens/drawer.png" width="240" alt="Library drawer"> | <img src="docs/screens/detail.png" width="240" alt="Book detail"> |
-->

Requires KOReader 2024.12+. Works anywhere KOReader runs plugins (Android, Kindle, Kobo).

## Install

Unzip `hansel.koplugin.zip` into KOReader’s `plugins` folder (so you have `plugins/hansel.koplugin/_meta.lua`), restart, enable **Hansel** under Tools → Plugin management, then:

**File Manager → Settings → Start with → hansel**

Restart once more. From a book, assign **Show Hansel** in Gesture Manager.

Also listed in the [KOReader App Store](https://github.com/omer-faruq/appstore.koplugin) once the repo is public (`koreader-plugin` topic).

## Sign in

Server URL (`http://your-host:6060`), Grimmory username, password. After that you can turn on Auto sync so progress follows you.

## Settings

- **Start with** — KOReader boots into the cover grid instead of File Manager.
- **Auto sync** — after account login, progress follows you (percent + XPointer). Off until you turn it on. Stands down if the official Grimmory plugin is already syncing.
- **Test connection** — ping Grimmory from Settings without leaving the screen.
- **Hide unavailable books** — when this device can't reach Grimmory, only show books already on it.
- **On this device** — drawer row for downloaded ∪ pinned. Settings has a separate storage panel under the same name.
- **Pin** — keep a downloaded book when you would otherwise evict it.
- **Grid density** — Comfortable (3×3), Compact (4×4), Dense (5×4).
- **Prefetch next page covers** — fetch the next page of cover art while you read this one.

## Tools → Hansel

- **Show library** — open the cover grid.
- **Dashboard** — continue plus recently added.
- **All Books** — the full library.
- **Hansel settings** — server, account, sync, and library.
- **Close Hansel** — return to File Manager.

## Why this exists

KOReader can already add Grimmory over OPDS. That is a catalog you visit, then a file you find again in File Manager. Hansel signs in and the cover grid is the library.

Not the official Grimmory plugin. If [`grimmory.koplugin`](https://github.com/grimmory-tools/grimmory.koplugin) is already syncing, Hansel leaves that alone.

## License

[AGPL-3.0](LICENSE). Not affiliated with Grimmory. See [CHANGELOG](CHANGELOG.md) and [CONTRIBUTING](CONTRIBUTING.md).

Designed with AI assistance. The plugin is reviewed and tested as a normal KOReader project.
